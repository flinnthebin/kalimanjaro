#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

deps() { cat <<EOF
curl
jq
jre-openjdk
EOF
}

fetch() {
  require_cmd curl
  require_cmd jq
  log "[apktool] fetching wrapper script"
  mkdir -p "$SRC"
  curl -fsSL "https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool" \
    -o "$SRC/apktool"

  log "[apktool] discovering latest jar from Bitbucket"
  local api="https://api.bitbucket.org/2.0/repositories/iBotPeaches/apktool/downloads?pagelen=50"
  local jar
  jar="$(curl -fsSL "$api" \
        | jq -r '.values[].name' \
        | grep -E '^apktool_[0-9.]+\.jar$' \
        | sort -V \
        | tail -1)" || true
  [[ -n "$jar" ]] || die "[apktool] could not detect latest jar"

  log "[apktool] fetching $jar"
  curl -fsSL "https://bitbucket.org/iBotPeaches/apktool/downloads/${jar}" -o "$SRC/apktool.jar"
}

build() {
  log "[apktool] no build step (script + jar)"
  quiet_run chmod +x "$SRC/apktool"
}

install() {
  log "[apktool] installing"
  quiet_run with_sudo install -Dm755 "$SRC/apktool" /usr/local/bin/apktool
  quiet_run with_sudo install -Dm755 "$SRC/apktool.jar" /usr/local/bin/apktool.jar
  log "[apktool] installed: /usr/local/bin/apktool + apktool.jar"
}

case "${1:-}" in
  deps|fetch|build|install) "$1" ;;
  *) die "usage: $0 {deps|fetch|build|install}" ;;
esac
