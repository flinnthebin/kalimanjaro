#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
: "${REPO:=https://example.com/your/repo.git}"
: "${PANDOC_MAN:=1}"           # 1=generate manpage from README.md (if present)
: "${SECTION:=1}"
: "${TITLE:=Manual}"
: "${NAME:=$(basename "${0:-template.sh}" .sh)}"
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
  log "[${NAME}] build"
  # Examples:
  # ( cd "$SRC" && ./configure --prefix="$PREFIX" && make -j"$(nproc)" )
  # ( cd "$SRC" && cmake -B build -DCMAKE_INSTALL_PREFIX="$PREFIX" && cmake --build build -j"$(nproc)" )
  :
}

_install_man_from_readme() {
  # Uses pandoc if README.md exists; silently skips otherwise.
  local readme candidates=( "README.md" "readme.md" "README" )
  for f in "${candidates[@]}"; do
    [[ -f "$SRC/$f" ]] && readme="$SRC/$f" && break
  done
  [[ "${PANDOC_MAN}" == "1" && -n "${readme:-}" ]] || return 0

  if ! command -v pandoc >/dev/null 2>&1; then
    warn "[${NAME}] README found but pandoc not installed; skipping manpage"
    return 0
  fi

  local manfile="${SRC}/${NAME}.${SECTION}"
  log "[${NAME}] generating manpage from $(basename "$readme") -> $(basename "$manfile").gz"
  # -s: standalone; -t man: groff man; header via -V variables
  quiet_run pandoc -s -t man \
    -V title="${NAME}" \
    -V section="${SECTION}" \
    -V header="${TITLE}" \
    "$readme" -o "$manfile"

  # Compress and install
  quiet_run gzip -f -9 "$manfile"
  quiet_run with_sudo install -Dm644 "${manfile}.gz" \
    "$PREFIX/share/man/man${SECTION}/${NAME}.${SECTION}.gz"

    # Refresh man-db (best-effort)
  if command -v mandb >/dev/null 2>&1; then
    quiet_run with_sudo mandb || true
  fi
}

install() {
  log "[${NAME}] install"
  # quiet_run with_sudo install -Dm755 "${SRC}/${NAME}" "$PREFIX/bin/${NAME}"
  # quiet_run with_sudo install -d "/etc/${BASENAME}"

  _install_man_from_readme
}

post() {
  log "[${NAME}] post: smoke"
  # Example:
  # command -v "${PREFIX}/bin/${NAME}" >/dev/null || die "[${NAME}] binary missing"
}

cleanup() {
  log "[${NAME}] cleanup"
  # Example stops:
  # with_sudo systemctl disable --now "${NAME}.service" 2>/dev/null || true
  # Remove binaries/configs:
  # with_sudo rm -f "${PREFIX}/bin/${NAME}" "${PREFIX}/bin/${NAME}" 2>/dev/null || true
  # Manpages:
  with_sudo rm -f \
    "$PREFIX/share/man/man${SECTION}/${NAME}.${SECTION}.gz" \
    "$PREFIX/share/man/man${SECTION}/${NAME}.${SECTION}.gz" 2>/dev/null || true
  if command -v mandb >/dev/null 2>&1; then
    quiet_run with_sudo mandb || true
  fi
  log "[${NAME}] cleanup complete"
}

case "${1:-}" in
  deps|pre|fetch|build|install|post|cleanup) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post|cleanup}" ;;
esac

