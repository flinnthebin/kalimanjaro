#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${BIN:=bin}"
: "${MAN:=share/man/man1}"
: "${SRC:?set by srcbuild}"
: "${APPLE_BLEEE_PBS_URL:=}" # explicit PBS asset URL (optional)
: "${APPLE_BLEEE_SHARE_DIR:=$PREFIX/share/apple-bleee}"
: "${NAME:="apple-bleee"}"
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
  curl -fsI https://github.com/hexway/apple_bleee >/dev/null || warn "apple_bleee repo unreachable"
  curl -fsI https://github.com/seemoo-lab/owl >/dev/null || warn "owl repo unreachable"
  # PBS probe (no fail if GH rate-limited)
  local trip
  case "$(uname -m)" in
    x86_64) trip="x86_64-unknown-linux-gnu";;
    aarch64) trip="aarch64-unknown-linux-gnu";;
    *) trip="";;
  esac
  [[ -n "$trip" ]] && curl -fsSL "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest" \
    | jq -er --arg t "$trip" '.assets[]?.browser_download_url | select(test($t))' >/dev/null || warn "PBS probe failed"
}

_patch_pyfixes() {
  local root="$1"
  require_cmd find
  require_cmd sed
  require_cmd perl

  # Fix "is"/"is not" misuse with literals/ints
  find "$root" -type f -name '*.py' -print0 \
  | xargs -0 sed -i -E \
      -e 's/\bis[[:space:]]+not[[:space:]]+(-?[0-9]+)/!= \1/g' \
      -e 's/\bis[[:space:]]+(-?[0-9]+)/== \1/g' \
      -e "s/\\bis[[:space:]]+not[[:space:]]+(''|\"\")/!= \\1/g" \
      -e "s/\\bis[[:space:]]+(''|\"\")/== \\1/g"

  # Make regex strings raw where needed
  find "$root" -type f -name '*.py' -print0 \
  | xargs -0 perl -0777 -pi -e 's/re\.compile\("((?:[^"\\]|\\.)*\\(?:[^"\\]|\\.)*)"\)/re.compile(r"$1")/g'
}

_pbs_triplet() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64-unknown-linux-gnu" ;;
    aarch64) echo "aarch64-unknown-linux-gnu" ;;
    *) die "[apple-bleee] unsupported arch: $(uname -m)";;
  esac
}

_resolve_pbs_url() {
  local override="${APPLE_BLEEE_PBS_URL:-}"
  [[ -n "$override" ]] && { echo "$override"; return 0; }
  local trip="$(_pbs_triplet)"
  local api_base="https://api.github.com/repos/astral-sh/python-build-standalone/releases"
  local urls

  urls="$(curl -fsSL "${api_base}/latest" \
    | jq -r --arg trip "$trip" '
        ( .assets // [] )[]?.browser_download_url
        | select(test("^https://.*/cpython-3\\.10\\.[0-9]+\\+[0-9]+-" + $trip + "-install_only\\.tar\\.(gz|zst|xz)$"))
      ' 2>/dev/null | sort -V | tail -n1)" || true

  if [[ -z "$urls" ]]; then
    urls="$(curl -fsSL "${api_base}?per_page=20" \
      | jq -r --arg trip "$trip" '
          .[]?.assets[]?.browser_download_url
          | select(test("^https://.*/cpython-3\\.10\\.[0-9]+\\+[0-9]+-" + $trip + "-install_only\\.tar\\.(gz|zst|xz)$"))
        ' 2>/dev/null | sort -V | tail -n1)" || true
  fi
  [[ -n "$urls" ]] && { echo "$urls"; return 0; }
  return 1
}

fetch() {
  require_cmd git
  log "[apple-bleee] fetching sources"
  mkdir -p "$SRC"
  quiet_run git clone --depth=1 https://github.com/hexway/apple_bleee.git "$SRC/apple_bleee"
  quiet_run git clone --depth=1 https://github.com/seemoo-lab/owl.git "$SRC/owl"
  ( cd "$SRC/owl" && quiet_run git submodule update --init )
}

build() {
  local share_dir="${APPLE_BLEEE_SHARE_DIR}"
  local venv="$share_dir/.venv"
  local uv_venv="$share_dir/.uv-venv"
  local req_fixed="$SRC/apple_bleee/requirements.fixed.txt"

  log "[apple-bleee] building owl (AWDL)"
  (
    cd "$SRC/owl"
    sed -i -E 's/^[[:space:]]*add_subdirectory\((googletest)\)/# \0/' CMakeLists.txt || true
    sed -i -E 's/^[[:space:]]*add_subdirectory\((tests)\)/# \0/' CMakeLists.txt || true
    mkdir -p build && cd build
    quiet_run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" ..
    quiet_run make -j"$(nproc)" owl
    quiet_run with_sudo make install
  )

  log "[apple-bleee] preparing Python env"
  local pbs_root="/opt/pbs-py310"
  local pbs_py="$pbs_root/bin/python3.10"

  # sanitize upstream requirements (pycrypto -> pycryptodome; drop pybluez since system)
  sed -E '
    s/^[[:space:]]*pycrypto[[:space:]]*$/pycryptodome/i;
    s/%[[:space:]]*$//;
    s/^[[:space:]]*pybluez([[:space:]]*(==[^[:space:]]+)?)?[[:space:]]*$/# pybluez (provided by system)/i
  ' "$SRC/apple_bleee/requirements.txt" > "$req_fixed"

  # fresh install path + sources
  quiet_run with_sudo rm -rf "$share_dir"
  quiet_run with_sudo mkdir -p "$share_dir"
  quiet_run with_sudo cp -a "$SRC/apple_bleee/." "$share_dir/"

  log "[apple-bleee] patching legacy Python syntax"
  _patch_pyfixes "$share_dir"

  # standard venv (system site packages OK)
  quiet_run with_sudo python -m venv --system-site-packages "$venv"
  quiet_run with_sudo "$venv/bin/pip" install --upgrade pip wheel
  quiet_run with_sudo "$venv/bin/pip" install -r "$req_fixed" || {
    warn "[apple-bleee] pip -r failed; retrying best-effort per package"
    while IFS= read -r pkg; do
      [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
      with_sudo "$venv/bin/pip" install "$pkg" || warn "pip failed for: $pkg (skipping)"
    done < <(sed -E 's/[[:space:]]+#.*$//' "$req_fixed")
  }

  require_cmd curl; require_cmd jq; require_cmd tar; require_cmd uv
  if [[ ! -x "$pbs_py" ]]; then
    log "[apple-bleee] discovering PBS Python 3.10"
    local pbs_url; pbs_url="$(_resolve_pbs_url)" || die "[apple-bleee] couldn't find CPython 3.10 install_only asset. Set APPLE_BLEEE_PBS_URL."
    log "[apple-bleee] fetching PBS Python -> $pbs_root"
    quiet_run with_sudo mkdir -p "$pbs_root"
    local tmp_tgz; tmp_tgz="$(mktemp)"
    if ! quiet_run curl -fSLo "$tmp_tgz" "$pbs_url"; then
      local mirror="${pbs_url/https:\/\/github.com\/astral-sh\/python-build-standalone\/releases\/download\//https:\/\/python-standalone.org\/mirror\/astral-sh\/python-build-standalone\/releases\/download\/}"
      warn "[apple-bleee] GitHub download failed; trying mirror"
      curl -fSLo "$tmp_tgz" "$mirror" || die "[apple-bleee] failed to download PBS Python from mirror"
    fi
    quiet_run with_sudo tar -axf "$tmp_tgz" -C "$pbs_root" --strip-components=1
    rm -f "$tmp_tgz"
    quiet_run with_sudo "$pbs_py" -V >/dev/null || die "[apple-bleee] PBS Python unpacked but not runnable"
  fi

  log "[apple-bleee] creating uv venv ($uv_venv) with PBS Python"
  quiet_run with_sudo uv venv "$uv_venv" --python "$pbs_py"

  # Clean uv cache
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/uv/builds-v0" 2>/dev/null || true

  # build netifaces with HAVE_GETIFADDRS
  CFLAGS="${CFLAGS:-} -DHAVE_GETIFADDRS=1" \
  quiet_run with_sudo uv pip install --python "$uv_venv/bin/python" --no-binary netifaces netifaces \
  || die "[apple-bleee] uv pip install (netifaces) failed"

  # deps for airdrop-leak (Pillow + ctypescrypto + older cryptography)
  quiet_run with_sudo uv pip install --python "$uv_venv/bin/python" \
  beautifulsoup4 fleep libarchive-c Pillow prettytable pycryptodome requests "ctypescrypto==0.5" "cryptography<40" \
  || die "[apple-bleee] uv pip install failed"

  # wrapper helper
  _mk_wrapper() {
    local name="$1" script="$2" py="$3" env_lines="${4:-}"
    with_sudo install -Dm755 /dev/stdin "$PREFIX/bin/$name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${env_lines}
exec "$py" "$share_dir/$script" "\$@"
EOF
  }

  local py_std="$venv/bin/python"
  local py_airdrop="$uv_venv/bin/python"

  quiet_run _mk_wrapper ble-read-state  "ble_read_state.py" "$py_std"
  quiet_run _mk_wrapper adv-wifi        "adv_wifi.py"       "$py_std"
  quiet_run _mk_wrapper adv-airpods     "adv_airpods.py"    "$py_std"

  # OpenSSL 1.1 only for airdrop-leak (process-scoped)
  quiet_run _mk_wrapper airdrop-leak "airdrop_leak.py" "$py_airdrop" \
'LIBCRYPTO11="/usr/lib/libcrypto.so.1.1"
LIBSSL11="/usr/lib/libssl.so.1.1"
if [[ ! -e "$LIBCRYPTO11" || ! -e "$LIBSSL11" ]]; then
  echo "[airdrop-leak] OpenSSL 1.1 not found. Install openssl-1.1." >&2
  exit 1
fi
export LD_PRELOAD="${LIBCRYPTO11}:${LIBSSL11}:${LD_PRELOAD:-}"
export CTYPESCRYPTO_LIBCRYPTO="${LIBCRYPTO11}"'

log "[apple-bleee] installed wrappers to $PREFIX/bin (ble-read-state, adv-wifi, adv-airpods, airdrop-leak)"
}

install() {
  log "[apple-bleee] install handled during build; nothing to do"
}

post() {
  log "[apple-bleee] post: smoke"
  for t in ble-read-state adv-wifi adv-airpods airdrop-leak; do
    command -v "$PREFIX/bin/$t" >/dev/null || warn "wrapper missing: $t"
    "$PREFIX/bin/$t" -h >/dev/null || true
  done
  # Confirm OpenSSL 1.1 check trips properly without the libs
  if ! [[ -e /usr/lib/libssl.so.1.1 ]]; then
    "$PREFIX/bin/airdrop-leak" &>/tmp/airdrop-leak.out || true
    grep -q "OpenSSL 1.1 not found" /tmp/airdrop-leak.out || warn "airdrop-leak OpenSSL guard not hit"
  fi
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
