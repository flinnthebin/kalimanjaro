#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

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

fetch() {
  require_cmd curl
  log "[apache-users] fetching apache2.pl"
  mkdir -p "$SRC"
  curl -fsSL "https://raw.githubusercontent.com/CiscoCXSecurity/apache-users/master/apache2.pl" \
    -o "$SRC/apache2.pl"
}

build() {
  log "[apache-users] no build step (perl script)"
  sed -i '1s@^#!.*perl.*@#!/usr/bin/env perl@' "$SRC/apache2.pl"
  quiet_run chmod +x "$SRC/apache2.pl"
}

install() {
  log "[apache-users] installing to /usr/local/bin/apache-users"
  quiet_run with_sudo install -Dm755 "$SRC/apache2.pl" /usr/local/bin/apache-users
  log "[apache-users] installed: /usr/local/bin/apache-users"
}

case "${1:-}" in
  deps|fetch|build|install) "$1" ;;
  *) DIE "usage: $0 {deps|fetch|build|install}" ;;
esac
