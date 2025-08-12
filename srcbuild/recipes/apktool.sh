#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
# ---------- env ----------

deps() { cat <<EOF
curl
jq
jre-openjdk
EOF
}

pre() {
  log "[apktool] preflight: Bitbucket API and wrapper URL"
  curl -fsI "https://api.bitbucket.org/2.0/repositories/iBotPeaches/apktool/downloads?pagelen=1" >/dev/null \
    || warn "[apktool] Bitbucket API not reachable"
  curl -fsI "https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool" >/dev/null \
    || warn "[apktool] wrapper URL not reachable"
  # quick version parse dry run
  local jar ver
  jar="$(curl -fsSL "https://api.bitbucket.org/2.0/repositories/iBotPeaches/apktool/downloads?pagelen=50" \
        | jq -r '.values[].name' | grep -E '^apktool_[0-9.]+\.jar$' | sort -V | tail -1)" || true
  ver="${jar#apktool_}"; ver="${ver%.jar}"
  [[ -n "$ver" ]] || warn "[apktool] version parse failed"
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
  quiet_run sed -i "s|^jarpath=.*|jarpath=\"$PREFIX/bin/apktool.jar\"|" "$SRC/apktool"
  quiet_run chmod +x "$SRC/apktool"
}

install() {
  log "[apktool] installing"
  quiet_run with_sudo install -Dm755 "$SRC/apktool" "$PREFIX/bin/apktool"
  quiet_run with_sudo install -Dm644 "$SRC/apktool.jar" "$PREFIX/bin/apktool.jar"
  log "[apktool] installed: $PREFIX/bin/apktool + apktool.jar"
}

post() {
  log "[apktool] post: smoke"
  command -v "$PREFIX/bin/apktool" >/dev/null || die "wrapper missing"
  if ! "$PREFIX/bin/apktool" v 2>&1 | grep -qE '^[0-9]+\.[0-9]+'; then
    warn "apktool v did not return a valid version"
  fi
  if ! java -jar "$PREFIX/bin/apktool.jar" v 2>&1 | grep -qE '^[0-9]+\.[0-9]+'; then
    warn "apktool.jar not runnable"
  fi
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
