#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

deps() { cat <<EOF
gcc
make
libcap
git
EOF
}

fetch() {
  require_cmd git
  log "[0trace] fetching sources"
  quiet_run git clone --depth=1 https://gitlab.com/kalilinux/packages/0trace.git "$SRC"
}

build() {
  log "[0trace] compiling sendprobe"
  ( cd "$SRC"
    quiet_run gcc -O2 -Wall -o sendprobe sendprobe.c
    sed -E 's#\./sendprobe#${PROBE:-/usr/local/libexec/0trace/sendprobe}#g' 0trace.sh > 0trace.patched
  )
}

install() {
  log "[0trace] installing"
  quiet_run with_sudo install -Dm755 "$SRC/sendprobe" /usr/local/libexec/0trace/sendprobe
  quiet_run with_sudo install -Dm755 "$SRC/0trace.patched" /usr/local/bin/0trace
  quiet_run with_sudo setcap cap_net_raw+ep /usr/local/libexec/0trace/sendprobe || warn "setcap failed; run 0trace with sudo"
  log "[0trace] installed to /usr/local/bin/0trace"
}

case "${1:-}" in
  deps|fetch|build|install) "$1" ;;
  *) die "usage: $0 {deps|fetch|build|install}" ;;
esac
