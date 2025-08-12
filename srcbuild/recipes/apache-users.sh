#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
# ---------- env ----------

deps() {
  cat <<EOF
perl
curl
perl-parallel-forkmanager
perl-libwww
perl-lwp-protocol-https
perl-io-socket-ip
perl-io-socket-ssl
perl-net-ssleay
EOF
  # optional: perl-io-all (repo) and perl-io-all-lwp (AUR)
}

pre() {
  log "[apache-users] preflight: upstream script reachable"
  curl -fsI "https://raw.githubusercontent.com/CiscoCXSecurity/apache-users/master/apache2.pl" >/dev/null \
    || warn "[apache-users] upstream not reachable"
}

fetch() {
  require_cmd curl
  log "[apache-users] fetching apache2.pl"
  mkdir -p "$SRC"
  curl -fsSL "https://raw.githubusercontent.com/CiscoCXSecurity/apache-users/master/apache2.pl" \
    -o "$SRC/apache2.pl"
}

build() {
  log "[apache-users] no build step (perl script)"
  quiet_run sed -i '1s@^#!.*perl.*@#!/usr/bin/env perl@' "$SRC/apache2.pl"
  quiet_run chmod +x "$SRC/apache2.pl"
}

install() {
  log "[apache-users] installing to $PREFIX/bin/apache-users"
  quiet_run with_sudo install -Dm755 "$SRC/apache2.pl" "$PREFIX"/bin/apache-users
  log "[apache-users] installed: $PREFIX/bin/apache-users"
}

post() {
  log "[apache-users] post: smoke"
  command -v "$PREFIX/bin/apache-users" >/dev/null || die "binary missing"
  "$PREFIX/bin/apache-users" -h >/dev/null || true
  perl -c "$PREFIX/bin/apache-users" >/dev/null || warn "perl syntax warn"
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
