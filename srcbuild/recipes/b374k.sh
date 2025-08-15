#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${BIN:=bin}"
: "${MAN:=share/man/man1}"
: "${SRC:?set by srcbuild}"
: "${REPO:=https://github.com/b374k/b374k.git}"
: "${FILE:=index.php}"
: "${PANDOC_MAN:=1}"
: "${SECTION:=1}"
: "${TITLE:=Manual}"
: "${NAME:=b374k}"
# ---------- env ----------

deps() {
  local want=(
    git
    make
    gcc
  )

  if [[ "${PANDOC_MAN}" == "1" ]]; then
    want+=(pandoc gzip man-db)
  fi

  printf '%s\n' "${want[@]}"
}

_install_man_from_readme() {
  local readme candidates=( "README.md" "readme.md" "README" )
  for f in "${candidates[@]}"; do
    [[ -f "${SRC}/${f}" ]] && readme="${SRC}/${f}" && break
  done
  [[ "${PANDOC_MAN}" == "1" && -n "${readme:-}" ]] || return 0

  local manfile="${SRC}/${NAME}.${SECTION}"
  log "[${NAME}] generating manpage from $(basename "${readme}") -> $(basename "${manfile}").gz"
  quiet_run pandoc -s -t man \
    -V title="${NAME}" \
    -V section="${SECTION}" \
    -V header="${TITLE}" \
    "${readme}" -o "${manfile}"

  # Compress and install
  quiet_run gzip -f -9 "${manfile}"
  quiet_run with_sudo install -Dm644 "${manfile}.gz" \
    "${PREFIX}/${MAN}/${NAME}.${SECTION}.gz"

  # Refresh man-db
  if command -v mandb >/dev/null 2>&1; then
    quiet_run with_sudo mandb || true
  fi
}

pre() {
  log "[${NAME}] preflight"
  [[ "${REPO}" =~ ^https?:// ]] && curl -fsI "${REPO}" >/dev/null || true
}

fetch() {
  if [[ -n "${REPO}" ]]; then
    require_cmd git
    log "[${NAME}] fetching sources"
    quiet_run git clone --depth=1 "${REPO}" "${SRC}"
  else
    log "[${NAME}] fetch skipped (no REPO)"
  fi
}

build() {
  log "[${NAME}] no build step (php script)"
  quiet_run chmod +x "${SRC}/${FILE}"
}


install() {
  log "[${NAME}] install"
  quiet_run with_sudo install -Dm755 "${SRC}/${FILE}" "${PREFIX}/${BIN}/${NAME}"
  log "[${NAME}] adding manpage"
  _install_man_from_readme
}

post() {
  log "[${NAME}] post: smoke"
  command -v "${PREFIX}/${BIN}/${NAME}" >/dev/null || die "[${NAME}] binary missing"
}

uninstall() {
  log "[${NAME}] removing installed files"
  rm_if_exists \
    "${PREFIX}/${BIN}/${NAME}" \
    "${PREFIX}/${MAN}/${NAME}.${SECTION}.gz"
}


case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac

