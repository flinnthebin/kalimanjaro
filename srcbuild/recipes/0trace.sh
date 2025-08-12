#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
# ---------- env ----------

deps() { cat <<EOF
gcc
make
libcap
git
EOF
}

pre() {
  log "[0trace] preflight: verify repo reachable and sed patch target exists"
  curl -fsI https://gitlab.com/kalilinux/packages/0trace.git >/dev/null || warn "[0trace] GitLab HEAD failed"
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
    # Patch 0trace.sh:
    #  - Inserts default PROBE definition
    #  - Replace './sendprobe' with "$PROBE"
    quiet_run sed -E \
      -e "1a PROBE=\${PROBE:-\"$PREFIX\"/libexec/0trace/sendprobe}" \
      -e 's#\./sendprobe#"$PROBE"#g' \
      0trace.sh > 0trace.patched  )
}

install() {
  log "[0trace] installing"
  quiet_run with_sudo install -Dm755 "$SRC/sendprobe" "$PREFIX"/libexec/0trace/sendprobe
  quiet_run with_sudo install -Dm755 "$SRC/0trace.patched" "$PREFIX"/bin/0trace
  quiet_run with_sudo setcap cap_net_raw+ep "$PREFIX"/libexec/0trace/sendprobe || warn "setcap failed; run 0trace with sudo"
  log "[0trace] installed to $PREFIX/bin/0trace"
}

post() {
  log "[0trace] post: smoke"
  command -v "$PREFIX/bin/0trace" >/dev/null || die "[0trace] binary missing"
  "$PREFIX/bin/0trace" -h >/dev/null || true
  # Check helper has cap_net_raw (so sudo isn't required)
  if command -v getcap >/dev/null; then
    getcap "$PREFIX/libexec/0trace/sendprobe" | grep -q cap_net_raw || warn "[0trace] sendprobe missing cap_net_raw"
  fi
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
