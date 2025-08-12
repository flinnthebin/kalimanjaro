#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
: "${REPO=https://github.com/hackerschoice/THC-Archive/tree/master/Tools}"
: "${RAW=https://raw.githubusercontent.com/hackerschoice/THC-Archive/master/Tools}"
# ---------- env ----------

deps() { cat <<EOF
base-devel
openssl
pcre
curl
EOF
}

pre() {
  log "[amap] preflight: verify Tools listing and tarball URL"
  local list_url="https://github.com/hackerschoice/THC-Archive/tree/master/Tools"
  local raw_base="https://raw.githubusercontent.com/hackerschoice/THC-Archive/master/Tools"

  # Check list page reachable
  curl -fsI "$REPO" >/dev/null \
    || warn "[amap] GitHub Tools listing unreachable"

  # Try to parse latest version number
  local ver
  ver="$(curl -fsSL "$REPO" \
        | grep -oE 'amap-[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/^amap-([0-9]+\.[0-9]+)\.tar\.gz$/\1/' \
        | sort -V | tail -1)" || true

  if [[ -z "$ver" ]]; then
    warn "[amap] version parse failed"
  else
    log "[amap] latest version detected: $ver"
    # Check raw tarball URL
    curl -fsI "$RAW/amap-$ver.tar.gz" >/dev/null \
      || warn "[amap] tarball URL for v$ver unreachable"
  fi
}

fetch() {
  require_cmd curl
  log "[amap] discovering latest version"
  local ver
  ver="$(curl -fsSL "$REPO" \
        | grep -oE 'amap-[0-9]+\.[0-9]+\.tar\.gz' \
        | sed -E 's/amap-([0-9]+\.[0-9]+)\.tar\.gz/\1/' \
        | sort -V | tail -1)" || true
  [[ -n "$ver" ]] || die "[amap] could not detect latest version"

  log "[amap] downloading v$ver"
  curl -fsSL "$RAW/amap-$ver.tar.gz" -o "$SRC/amap.tar.gz"
  tar -C "$SRC" -xf "$SRC/amap.tar.gz"
  mv "$SRC/amap-$ver" "$SRC/amap"
}

build() {
  local dir="$SRC/amap"
  log "[amap] attempting ancient configure (expected to fail)…"
  set +e
  quiet_run clean_env_configure "$dir" ac_cv_prog_cc_works=yes ac_cv_prog_cc_cross=no -- --prefix="$PREFIX" --with-ssl=/usr
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
    quiet_run with_sudo install -Dm755 "$dir/amap" "$PREFIX"/bin/amap
    [[ -x "$dir/amapcrap" ]] && quiet_run with_sudo install -Dm755 "$dir/amapcrap" "$PREFIX"/bin/amapcrap
    for f in appdefs.resp appdefs.trig appdefs.rpc; do
      quiet_run with_sudo install -Dm644 "$dir/$f" "$PREFIX/share/amap/$f"
    done
    quiet_run with_sudo install -Dm644 "$dir/amap.1" "$PREFIX"/share/man/man1/amap.1 || true
    [[ -f "$dir/amapcrap.1" ]] && quiet_run with_sudo install -Dm644 "$dir/amapcrap.1" "$PREFIX"/share/man/man1/amapcrap.1 || true
    command -v mandb >/dev/null && quiet_run with_sudo mandb || true
  else
    ( cd "$dir" && quiet_run with_sudo make install || true )
    [[ -x "$dir/amapcrap" ]] && quiet_run with_sudo install -Dm755 "$dir/amapcrap" "$PREFIX"/bin/amapcrap
    [[ -f "$dir/amapcrap.1" ]] && quiet_run with_sudo install -Dm644 "$dir/amapcrap.1" "$PREFIX"/share/man/man1/amapcrap.1 || true
    command -v mandb >/dev/null && quiet_run with_sudo mandb || true
  fi
  log "[amap] installed to $PREFIX/bin/amap"
  [[ -x "$PREFIX"/bin/amapcrap ]] && log "[amap] installed amapcrap to "$PREFIX"/bin/amapcrap"
}

post() {
  log "[amap] post: smoke"
  command -v "$PREFIX/bin/amap" >/dev/null || die "[amap] binary missing"

  # exits 1; treat presence of version banner as success
  local out
  out="$("$PREFIX/bin/amap" -h 2>&1 || true)"
  echo "$out" | grep -qE '^amap v[0-9]+\.[0-9]+' \
    || warn "[amap] help/version banner not detected"

  if command -v "$PREFIX/bin/amapcrap" >/dev/null; then
    local out2
    out2="$("$PREFIX/bin/amapcrap" -h 2>&1 || true)"
    echo "$out2" | grep -qE '^amapcrap v[0-9]+\.[0-9]+' \
      || warn "[amap] amapcrap help/version banner not detected"
  fi

  # data files present and non-empty
  for f in appdefs.resp appdefs.trig appdefs.rpc; do
    [[ -s "$PREFIX/share/amap/$f" ]] || warn "[amap] missing or empty data file: $f"
  done

  # optional: check required shared libs resolve
  if command -v ldd >/dev/null; then
    ldd "$PREFIX/bin/amap" 2>/dev/null | grep -q "not found" && \
      warn "[amap] missing shared libraries (ldd reported 'not found')"
  fi
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
