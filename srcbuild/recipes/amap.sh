#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
: "${LIST=https://github.com/hackerschoice/THC-Archive/tree/master/Tools}"
: "${RAW=https://raw.githubusercontent.com/hackerschoice/THC-Archive/master/Tools}"
: "${NAME:=amap}"
: "${DEPNAME:=amapcrap}"
# ---------- env ----------

deps() { cat <<EOF
base-devel
openssl
pcre
curl
EOF
}

pre() {
  log "[${NAME}] preflight: verify Tools listing and tarball URL"

  # Check list page reachable
  curl -fsI "${LIST}" >/dev/null \
    || warn "[${NAME}] GitHub Tools listing unreachable"

  # Try to parse latest version number
  local ver
  ver="$(curl -fsSL "${LIST}" \
        | grep -oE 'amap-[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/^amap-([0-9]+\.[0-9]+)\.tar\.gz$/\1/' \
        | sort -V | tail -1)" || true

  if [[ -z "${ver}" ]]; then
    warn "[${NAME}] version parse failed"
  else
    log "[${NAME}] latest version detected: ${ver}"
    # Check raw tarball URL
    curl -fsI "${RAW}/${NAME}-${ver}.tar.gz" >/dev/null \
      || warn "[${NAME}] tarball URL for v${ver} unreachable"
  fi
}

fetch() {
  require_cmd curl
  log "[${NAME}] discovering latest version"
  local ver
  ver="$(curl -fsSL "${LIST}" \
        | grep -oE 'amap-[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/amap-([0-9]+\.[0-9]+)\.tar\.gz/\1/' \
        | sort -V | tail -1)" || true
  [[ -n "${ver}" ]] || die "[${NAME}] could not detect latest version"

  log "[${NAME}] downloading v${ver}"
  curl -fsSL "${RAW}/${NAME}-$ver.tar.gz" -o "${SRC}/${NAME}.tar.gz"
  tar -C "${SRC}" -xf "${SRC}/${NAME}.tar.gz"
  mv "${SRC}/${NAME}-${ver}" "${SRC}/${NAME}"
}

build() {
  local dir="${SRC}/${NAME}"
  log "[${NAME}] attempting ancient configure (expected to fail)…"
  set +e
  quiet_run clean_env_configure "${dir}" ac_cv_prog_cc_works=yes ac_cv_prog_cc_cross=no -- --prefix="${PREFIX}" --with-ssl=/usr
  local st=$?; set -e
  if (( st == 0 )); then
    log "[amap] building via make"
    ( cd "${dir}" && quiet_run make -j"$(nproc)" || true )
    if [[ ! -x "${dir}/${DEPNAME}" && -f "$dir/${DEPNAME}.c" ]]; then
      log "[${NAME}] make didn't produce ${DEPNAME}; building manually"
      ( cd "$dir"
        quiet_run gcc -O2 -Wall -I. -o amapcrap amapcrap.c amap-lib.c -lpcre -lpcreposix -lssl -lcrypto
      )
    fi
  else
    log "[${NAME}] configure failed; patching to use system PCRE and building directly"
    ( cd "$dir"
      sed -i -E 's#"pcre-3\.9/pcre\.h"#<pcre.h>#' amap-inc.h || true
      sed -i -E 's#"pcre-3\.9/pcreposix\.h"#<pcreposix.h>#' amap-inc.h || true
      quiet_run gcc -O2 -Wall -I. -o amap amap.c amap-lib.c -lpcre -lpcreposix -lssl -lcrypto
      [[ -f amapcrap.c ]] && quiet_run gcc -O2 -Wall -I. -o amapcrap amapcrap.c amap-lib.c -lpcre -lpcreposix -lssl -lcrypto
      touch .direct-build
    )
  fi
}

install() {
  local dir="${SRC}/${NAME}"
  log "[${NAME}] installing"
  if [[ -f "${dir}/.direct-build" ]]; then
    quiet_run with_sudo install -Dm755 "${dir}/${NAME}" "${PREFIX}/bin/${NAME}"
    [[ -x "${dir}/${DEPNAME}" ]] && quiet_run with_sudo install -Dm755 "$dir/${DEPNAME}" "${PREFIX}/bin/${DEPNAME}"
    for f in appdefs.resp appdefs.trig appdefs.rpc; do
      quiet_run with_sudo install -Dm644 "${dir}/$f" "${PREFIX}/share/${NAME}/$f"
    done
    quiet_run with_sudo install -Dm644 "${dir}/${NAME}.1" "${PREFIX}/share/man/man1/${NAME}.1" || true
    [[ -f "${dir}/${DEPNAME}.1" ]] && quiet_run with_sudo install -Dm644 "${dir}/${DEPNAME}.1" "${PREFIX}/share/man/man1/${DEPNAME}.1" || true
    command -v mandb >/dev/null && quiet_run with_sudo mandb || true
  else
    ( cd "${dir}" && quiet_run with_sudo make install || true )
    [[ -x "${dir}/${DEPNAME}" ]] && quiet_run with_sudo install -Dm755 "$dir/${DEPNAME}" "${PREFIX}"/bin/${DEPNAME}
    [[ -f "${dir}/${DEPNAME}.1" ]] && quiet_run with_sudo install -Dm644 "$dir/${DEPNAME}.1" "${PREFIX}"/share/man/man1/${DEPNAME}.1 || true
    command -v mandb >/dev/null && quiet_run with_sudo mandb || true
  fi
  log "[${NAME}] installed to ${PREFIX}/bin/${NAME}"
  [[ -x "{$PREFIX}/bin/${DEPNAME}" ]] && log "[${NAME}] installed amapcrap to "${PREFIX}"/bin/${DEPNAME}"
}

post() {
  log "[${NAME}] post: smoke"
  command -v "${PREFIX}/bin/${NAME}" >/dev/null || die "[${NAME}] binary missing"

  # exits 1; treat presence of version banner as success
  local out
  out="$("${PREFIX}/bin/${NAME}" -h 2>&1 || true)"
  echo "$out" | grep -qE '^amap v[0-9]+\.[0-9]+' \
    || warn "[${NAME}] help/version banner not detected"

  if command -v "${PREFIX}/bin/${DEPNAME}" >/dev/null; then
    local out2
    out2="$("${PREFIX}/bin/${DEPNAME}" -h 2>&1 || true)"
    echo "$out2" | grep -qE '^amapcrap v[0-9]+\.[0-9]+' \
      || warn "[${NAME}] ${DEPNAME} help/version banner not detected"
  fi

  # data files present and non-empty
  for f in appdefs.resp appdefs.trig appdefs.rpc; do
    [[ -s "${PREFIX}/share/amap/$f" ]] || warn "[amap] missing or empty data file: $f"
  done

  # check required shared libs resolve
  if command -v ldd >/dev/null; then
    ldd "${PREFIX}/bin/${NAME}" 2>/dev/null | grep -q "not found" && \
      warn "[${NAME}] missing shared libraries (ldd reported 'not found')"
  fi
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
