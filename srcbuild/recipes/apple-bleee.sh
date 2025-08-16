#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${NAME:="apple-bleee"}"
: "${DEP_NAME:=owl}"
: "${PREFIX:=/usr/local}"
: "${BIN:=${PREFIX}/bin}"
: "${MAN:=${PREFIX}/share/man/man1}"
: "${SHARE:=${PREFIX}/share}"
: "${SRC:?set by srcbuild}"
: "${REPO:=https://github.com/hexway/apple_bleee}"
: "${DEP_REPO:=https://github.com/seemoo-lab/owl}"
: "${PBS_REPO:=https://api.github.com/repos/astral-sh/python-build-standalone/releases}"
: "${PBS_LATEST:=${PBS_REPO}/latest}"
# ---------- env ----------

deps() {
  cat <<EOF
git
python
python-pip
base-devel
cmake
libpcap
libnl
libev
bluez
bluez-libs
python-pybluez
uv
curl
jq
tar
clang
openssl-1.1
EOF
}

pre() {
  log "[${NAME}] preflight: repos & PBS asset"
  curl -fsI "${REPO}" >/dev/null || warn "${NAME} repo unreachable"
  curl -fsI "${DEP_REPO}" >/dev/null || warn "${DEP_NAME} repo unreachable"

  local trip
  case "$(uname -m)" in
    x86_64) trip="x86_64-unknown-linux-gnu" ;;
    aarch64) trip="aarch64-unknown-linux-gnu" ;;
    *) trip="" ;;
  esac

  [[ -n "${trip}" ]] && curl -fsSL "${PBS_LATEST}" \
    | jq -er --arg t "${trip}" '
        (.assets // [])[]?.browser_download_url
        | select(test($t))
      ' >/dev/null \
    || warn "PBS probe failed"
}

_patch_pyfixes() {
  local root="$1"
  require_cmd find
  require_cmd sed
  require_cmd perl

  # Fix "is"/"is not" misuse with literals/ints
  find "${root}" -type f -name '*.py' -print0 \
  | xargs -0 sed -i -E \
      -e 's/\bis[[:space:]]+not[[:space:]]+(-?[0-9]+)/!= \1/g' \
      -e 's/\bis[[:space:]]+(-?[0-9]+)/== \1/g' \
      -e "s/\\bis[[:space:]]+not[[:space:]]+(''|\"\")/!= \\1/g" \
      -e "s/\\bis[[:space:]]+(''|\"\")/== \\1/g"

  # Make regex strings raw where needed
  find "${root}" -type f -name '*.py' -print0 \
  | xargs -0 perl -0777 -pi -e 's/re\.compile\("((?:[^"\\]|\\.)*\\(?:[^"\\]|\\.)*)"\)/re.compile(r"$1")/g'
}

_pbs_triplet() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64-unknown-linux-gnu" ;;
    aarch64) echo "aarch64-unknown-linux-gnu" ;;
    *) die "[${NAME}] unsupported arch: $(uname -m)";;
  esac
}

_resolve_pbs_url() {
  local trip="$(_pbs_triplet)"
  local urls
  urls="$(
    curl -fsSL "${PBS_LATEST}" \
    | jq -r --arg trip "${trip}" '
        (.assets // [])[]?.browser_download_url
        | select(test("^https://.*/cpython-3\\.10\\.[0-9]+\\+[0-9]+-" + $trip + "-install_only\\.tar\\.(gz|zst|xz)$"))
      ' 2>/dev/null | sort -V | tail -n1
  )" || true

  if [[ -z "${urls}" ]]; then
    urls="$(
      curl -fsSL "${PBS_REPO}?per_page=20" \
      | jq -r --arg trip "${trip}" '
          .[]?.assets[]?.browser_download_url
          | select(test("^https://.*/cpython-3\\.10\\.[0-9]+\\+[0-9]+-" + $trip + "-install_only\\.tar\\.(gz|zst|xz)$"))
        ' 2>/dev/null | sort -V | tail -n1
    )" || true
  fi
  [[ -n "${urls}" ]] && { echo "${urls}"; return 0; }
  return 1
}

fetch() {
  require_cmd git
  log "[${NAME}] fetching sources"
  mkdir -p "${SRC}"
  quiet_run git clone --depth=1 "${REPO}.git" "${SRC}/${NAME}"
  quiet_run git clone --depth=1 "${DEP_REPO}.git" "${SRC}/${DEP_NAME}"
  ( cd "${SRC}/${DEP_NAME}" && quiet_run git submodule update --init )
}

build() {
  local share_dir="${SHARE}/${NAME}"
  local venv="${share_dir}/.venv"
  local uv_venv="${share_dir}/.uv-venv"
  local req_fixed="${SRC}/${NAME}/requirements.fixed.txt"

  log "[${NAME}] building ${DEP_NAME} (AWDL)"
  (
    cd "${SRC}/${DEP_NAME}"
    sed -i -E 's/^[[:space:]]*add_subdirectory\((googletest)\)/# \0/' CMakeLists.txt || true
    sed -i -E 's/^[[:space:]]*add_subdirectory\((tests)\)/# \0/' CMakeLists.txt || true
    mkdir -p build && cd build
    quiet_run cmake -DCMAKE_INSTALL_PREFIX="${PREFIX}" ..
    quiet_run make -j"$(nproc)" owl
    quiet_run with_sudo make install
  )

  log "[${NAME}] preparing Python env"
  local pbs_root="/opt/pbs-py310"
  local pbs_py="${pbs_root}/bin/python3.10"

  # sanitize upstream requirements (pycrypto -> pycryptodome; drop pybluez since system)
  sed -E '
    s/^[[:space:]]*pycrypto[[:space:]]*$/pycryptodome/i;
    s/%[[:space:]]*$//;
    s/^[[:space:]]*pybluez([[:space:]]*(==[^[:space:]]+)?)?[[:space:]]*$/# pybluez (provided by system)/i
  ' "${SRC}/${NAME}/requirements.txt" > "${req_fixed}"

  # fresh install path + sources
  quiet_run with_sudo rm -rf "${share_dir}"
  quiet_run with_sudo mkdir -p "${share_dir}"
  quiet_run with_sudo cp -a "${SRC}/${NAME}/." "${share_dir}/"

  log "[${NAME}] patching legacy Python syntax"
  _patch_pyfixes "${share_dir}"

  # standard venv (system site packages OK)
  quiet_run with_sudo python -m venv --system-site-packages "${venv}"
  quiet_run with_sudo "${venv}/bin/pip" install --upgrade pip wheel
  quiet_run with_sudo "${venv}/bin/pip" install -r "${req_fixed}" || {
    warn "[${NAME}] pip -r failed; retrying best-effort per package"
    while IFS= read -r pkg; do
      [[ -z "${pkg}" || "${pkg}" =~ ^# ]] && continue
      with_sudo "${venv}/bin/pip" install "${pkg}" || warn "pip failed for: ${pkg} (skipping)"
    done < <(sed -E 's/[[:space:]]+#.*$//' "${req_fixed}")
  }

  require_cmd curl; require_cmd jq; require_cmd tar; require_cmd uv
  if [[ ! -x "${pbs_py}" ]]; then
    log "[${NAME}] discovering PBS Python 3.10"
    local pbs_url; pbs_url="$(_resolve_pbs_url)" || die "[${NAME}] couldn't find CPython 3.10 install_only asset."
    log "[${NAME}] fetching PBS Python -> ${pbs_root}"
    quiet_run with_sudo mkdir -p "${pbs_root}"
    local tmp_tgz; tmp_tgz="$(mktemp)"
    if ! quiet_run curl -fSLo "${tmp_tgz}" "${pbs_url}"; then
      local mirror="${pbs_url/https:\/\/github.com\/astral-sh\/python-build-standalone\/releases\/download\//https:\/\/python-standalone.org\/mirror\/astral-sh\/python-build-standalone\/releases\/download\/}"
      warn "[${NAME}] GitHub download failed; trying mirror"
      curl -fSLo "${tmp_tgz}" "${mirror}" || die "[${NAME}] failed to download PBS Python from mirror"
    fi
    quiet_run with_sudo tar -axf "${tmp_tgz}" -C "${pbs_root}" --strip-components=1
    rm -f "${tmp_tgz}"
    quiet_run with_sudo "${pbs_py}" -V >/dev/null || die "[${NAME}] PBS Python unpacked but not runnable"
  fi

  log "[${NAME}] creating uv venv (${uv_venv}) with PBS Python"
  quiet_run with_sudo uv venv "${uv_venv}" --python "${pbs_py}"

  # Clean uv cache
  rm -rf "${XDG_CACHE_HOME:-${HOME}/.cache}/uv/builds-v0" 2>/dev/null || true

  # build netifaces with HAVE_GETIFADDRS
  CFLAGS="${CFLAGS:-} -DHAVE_GETIFADDRS=1" \
  quiet_run with_sudo uv pip install --python "${uv_venv}/bin/python" --no-binary netifaces netifaces \
  || die "[${NAME}] uv pip install (netifaces) failed"

  # deps for airdrop-leak (Pillow + ctypescrypto + older cryptography)
  quiet_run with_sudo uv pip install --python "${uv_venv}/bin/python" \
  beautifulsoup4 fleep libarchive-c Pillow prettytable pycryptodome requests "ctypescrypto==0.5" "cryptography<40" \
  || die "[${NAME}] uv pip install failed"

  # wrapper helper
  _mk_wrapper() {
    local name="$1" script="$2" py="$3" env_lines="${4:-}"
    with_sudo install -Dm755 /dev/stdin "${BIN}/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${env_lines}
exec "${py}" "${share_dir}/${script}" "\$@"
EOF
  }

  local py_std="${venv}/bin/python"
  local py_airdrop="${uv_venv}/bin/python"

  quiet_run _mk_wrapper ble-read-state  "ble_read_state.py" "${py_std}"
  quiet_run _mk_wrapper adv-wifi        "adv_wifi.py"       "${py_std}"
  quiet_run _mk_wrapper adv-airpods     "adv_airpods.py"    "${py_std}"

  # OpenSSL 1.1 only for airdrop-leak (process-scoped)
  quiet_run _mk_wrapper airdrop-leak "airdrop_leak.py" "${py_airdrop}" \
'LIBCRYPTO11="/usr/lib/libcrypto.so.1.1"
LIBSSL11="/usr/lib/libssl.so.1.1"
if [[ ! -e "${LIBCRYPTO11}" || ! -e "${LIBSSL11}" ]]; then
  echo "[airdrop-leak] OpenSSL 1.1 not found. Install openssl-1.1." >&2
  exit 1
fi
export LD_PRELOAD="${LIBCRYPTO11}:${LIBSSL11}:${LD_PRELOAD:-}"
export CTYPESCRYPTO_LIBCRYPTO="${LIBCRYPTO11}"'

log "[${NAME}] installed wrappers to ${BIN} (ble-read-state, adv-wifi, adv-airpods, airdrop-leak)"
}

install() {
  log "[${NAME}] install handled during build; nothing to do"
}

post() {
  log "[${NAME}] post: smoke"
  for t in ble-read-state adv-wifi adv-airpods airdrop-leak; do
    command -v "${BIN}/${t}" >/dev/null || warn "wrapper missing: ${t}"
    "${BIN}/${t}" -h >/dev/null || true
  done
  # Confirm OpenSSL 1.1 check trips properly without the libs
  if ! [[ -e /usr/lib/libssl.so.1.1 ]]; then
    "${BIN}/airdrop-leak" &>/tmp/airdrop-leak.out || true
    grep -q "OpenSSL 1.1 not found" /tmp/airdrop-leak.out || warn "airdrop-leak OpenSSL guard not hit"
  fi
}

uninstall() {
  log "[${NAME}] removing installed files"
  rm_if_exists \
    "${BIN}/ble-read-state" \
    "${BIN}/airdrop-leak" \
    "${BIN}/adv-wifi" \
    "${BIN}/adv-airpods" \
    "${BIN}/${DEP_NAME}"
  # in case upstream ever installs libs/headers
  rm_if_exists "$PREFIX/lib/libawdl.a" "$PREFIX/lib/libradiotap.a"
  with_sudo rm -rf "${SHARE}/${NAME}" 2>/dev/null || true
  log "[${NAME}] cleanup complete"
}


case "${1:-}" in
  deps|pre|fetch|build|install|post|uninstall) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post|uninstall}" ;;
esac
