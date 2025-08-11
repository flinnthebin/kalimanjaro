#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

deps() { cat <<EOF
base-devel
openssl
pcre
curl
EOF
}

fetch() {
  require_cmd curl
  log "[amap] discovering latest version"
  local baseurl="https://github.com/hackerschoice/THC-Archive/raw/master/Tools"
  local ver
  ver="$(curl -fsSL "https://github.com/hackerschoice/THC-Archive/tree/master/Tools" \
        | grep -oE 'amap-[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/amap-([0-9]+\.[0-9]+)\.tar\.gz/\1/' \
        | sort -V | tail -1)" || true
  [[ -n "$ver" ]] || die "[amap] could not detect latest version"

  log "[amap] downloading v$ver"
  curl -fsSL "${baseurl}/amap-${ver}.tar.gz" -o "$SRC/amap.tar.gz"
  tar -C "$SRC" -xf "$SRC/amap.tar.gz"
  mv "$SRC/amap-${ver}" "$SRC/amap"
}

build() {
  local dir="$SRC/amap"
  log "[amap] attempting ancient configure (expected to fail)…"
  set +e
  quiet_run clean_env_configure "$dir" ac_cv_prog_cc_works=yes ac_cv_prog_cc_cross=no -- --prefix=/usr/local --with-ssl=/usr
  local st=$?; set -e
  if (( st == 0 )); then
    log "[amap] building via make"
    ( cd "$dir" && quiet_run make -j"$(nproc)" || true )
    if [[ ! -x "$dir/amapcrap" && -f "$dir/amapcrap.c" ]]; then
      log "[amap] make didn't produce amapcrap; building manually"
      ( cd "$dir"
        quiet_run gcc -O2 -Wall -I. -o amapcrap amapcrap.c amap-lib.c -lpcre -lpcreposix -lssl -lcrypto
      )
    fi
  else
    log "[amap] configure failed; patching to use system PCRE and building directly"
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
  local dir="$SRC/amap"
  log "[amap] installing"
  if [[ -f "$dir/.direct-build" ]]; then
    quiet_run with_sudo install -Dm755 "$dir/amap" /usr/local/bin/amap
    [[ -x "$dir/amapcrap" ]] && quiet_run with_sudo install -Dm755 "$dir/amapcrap" /usr/local/bin/amapcrap
    for f in appdefs.resp appdefs.trig appdefs.rpc; do
      quiet_run with_sudo install -Dm644 "$dir/$f" "/usr/local/share/amap/$f"
    done
    quiet_run with_sudo install -Dm644 "$dir/amap.1" /usr/local/share/man/man1/amap.1 || true
    [[ -f "$dir/amapcrap.1" ]] && quiet_run with_sudo install -Dm644 "$dir/amapcrap.1" /usr/local/share/man/man1/amapcrap.1 || true
    command -v mandb >/dev/null && quiet_run with_sudo mandb || true
  else
    ( cd "$dir" && quiet_run with_sudo make install || true )
    [[ -x "$dir/amapcrap" ]] && quiet_run with_sudo install -Dm755 "$dir/amapcrap" /usr/local/bin/amapcrap
    [[ -f "$dir/amapcrap.1" ]] && quiet_run with_sudo install -Dm644 "$dir/amapcrap.1" /usr/local/share/man/man1/amapcrap.1 || true
    command -v mandb >/dev/null && quiet_run with_sudo mandb || true
  fi
  log "[amap] installed to /usr/local/bin/amap"
  [[ -x /usr/local/bin/amapcrap ]] && log "[amap] installed amapcrap to /usr/local/bin/amapcrap"
}

case "${1:-}" in
  deps|fetch|build|install) "$1" ;;
  *) die "usage: $0 {deps|fetch|build|install}" ;;
esac
