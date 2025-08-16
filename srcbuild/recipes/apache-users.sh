#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${NAME:="apache-users"}"
: "${PREFIX:=/usr/local}"
: "${BIN:=${PREFIX}/bin}"
: "${SRC:?set by srcbuild}"
: "${REPO:=https://raw.githubusercontent.com/CiscoCXSecurity/apache-users/master/apache2.pl}"
: "${FILE:=apache2.pl}"
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
  log "[${NAME}] preflight: upstream script reachable"
  curl -fsI "${REPO}" >/dev/null \
    || warn "[${NAME}] upstream not reachable"
}

fetch() {
  require_cmd curl
  log "[${NAME}] fetching ${FILE}"
  mkdir -p "${SRC}"
  curl -fsSL "${REPO}" \
    -o "${SRC}/${FILE}"
}

build() {
  log "[${NAME}] no build step (perl script)"
  quiet_run sed -i '1s@^#!.*perl.*@#!/usr/bin/env perl@' "$SRC/${FILE}"
  quiet_run chmod +x "$SRC/${FILE}"
}

install() {
  log "[apache-users] installing to ${BIN}/${NAME}"
  quiet_run with_sudo install -Dm755 "$SRC/${FILE}" "${BIN}/${NAME}"
  log "[apache-users] installed: ${BIN}/${NAME}"
}

post() {
  log "[apache-users] post: smoke"
  command -v "${BIN}/${NAME}" >/dev/null || die "binary missing"
  "${BIN}/${NAME}" -h >/dev/null || true
  perl -c "${BIN}/${NAME}" >/dev/null || warn "perl syntax warn"
}

uninstall() {
  log "[${NAME}] removing installed files"
  rm_if_exists "${BIN}/${NAME}"
}

case "${1:-}" in
  deps|pre|fetch|build|install|post|uninstall) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post|uninstall}" ;;
esac

