#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
: "${MAN_SECTION:=1}"
: "${MAN_BASENAME:=apktool}"
# ---------- env ----------

deps() { cat <<EOF
curl
jq
jre-openjdk
EOF
}

_install_manpage_from_pandoc() {
  require_cmd pandoc
  local tmp_md="${SRC}/apktool_man.md"
  local out_man="${SRC}/${MAN_BASENAME}.${MAN_SECTION}"

  cat >"$tmp_md" <<'MD'
% APKTOOL(1) Apktool | User Commands
# NAME
apktool — Android APK decompilation and rebuilding utility

# SYNOPSIS
**apktool** [global-options] <command> [command-options] <file|dir>

# DESCRIPTION
Apktool is a tool for reverse engineering Android apk files. It can decode resources to nearly original form and rebuild them after making some modifications. It also makes working with an app easier because of project-like files and automation of repetitive tasks.

# UTILITY COMMAND OPTIONS
**-advance**, **--advanced**  
:   Dumps out advanced usage output.

**-version**, **--version**  
:   Outputs the current software version (e.g., 1.5.2).

# DECODING OPTIONS
Used with `apktool d file.apk {options}`

**-api**, **--api-level** <API>  
:   Sets API-level in generated smali files (default: targetSdkVersion).

**-b**, **--no-debug-info**  
:   Prevents writing debug info (.local, .param, .line, etc.).

**-f**, **--force**  
:   Forces deletion of the destination directory.

**--force-manifest**  
:   Forces decoding of AndroidManifest.xml regardless of options.

**--keep-broken-res**  
:   Keeps resources even if invalid config flags detected.

**-l**, **--lib** <package>:<location>  
:   Specify dynamic library location; can be repeated.

**-m**, **--match-original**  
:   Match generated files as close as possible to original (may prevent rebuild).

**--no-assets**  
:   Skip copying unknown asset files.

**--only-main-classes**  
:   Disassemble only root-level dex classes.

**-p**, **--frame-path** <DIR>  
:   Set framework files path.

**-r**, **--no-res**  
:   Skip decompiling resources; keep resources.arsc intact.

**-resm**, **--resource-mode** <mode>  
:   Mode for unresolved resources: remove (default), dummy, keep.

**-s**, **--no-src**  
:   Skip disassembling dex files.

**-t**, **--frame-tag** <TAG>  
:   Use framework files tagged with TAG.

# BUILDING OPTIONS
Used with `apktool b folder {options}`

**-a**, **--aapt** <FILE>  
:   Use specified aapt/aapt2 binary.

**-api**, **--api-level** <API>  
:   API-level to build against (default: minSdkVersion).

**-c**, **--copy-original**  
:   Copy original AndroidManifest.xml and META-INF.

**-d**, **--debug**  
:   Add `debuggable="true"` to AndroidManifest.xml.

**-f**, **--force-all**  
:   Overwrite existing files during build.

**-n**, **--net-sec-conf**  
:   Add generic network security config.

**-na**, **--no-apk**  
:   Don’t repack built files into APK.

**-nc**, **--no-crunch**  
:   Disable resource crunching.

**-o**, **--output** <FILE>  
:   Output apk filename (default: dist/{apkname}.apk).

**-p**, **--frame-path** <DIR>  
:   Set framework files path.

**--use-aapt1**  
:   Force aapt instead of aapt2.

**--use-aapt2**  
:   Force aapt2 instead of aapt.

# EMPTY FRAMEWORK DIR OPTIONS
Used with `apktool empty-framework-dir {options}`

**-f**, **--force**  
:   Force deletion of destination directory.

**-p**, **--frame-path** <DIR>  
:   Set framework files path.

# LIST FRAMEWORK DIR OPTIONS
Used with `apktool list-frameworks {options}`

**-p**, **--frame-path** <DIR>  
:   Set framework files path.

# COMMON OPTIONS
**-j**, **--jobs** <NUM>  
:   Threads to use (default: CPUs, max 8).

**-v**, **--verbose**  
:   Verbose output (include FINE logs).

**-q**, **--quiet**  
:   Quiet output.

# SEE ALSO
Project page: <https://ibotpeaches.github.io/Apktool/>

MD

  log "[apktool] generating manpage via pandoc"
  quiet_run pandoc -s -t man "$tmp_md" -o "$out_man"

  quiet_run gzip -f -9 "$out_man"
  quiet_run with_sudo install -Dm644 "${out_man}.gz" \
    "$PREFIX/share/man/man${MAN_SECTION}/${MAN_BASENAME}.${MAN_SECTION}.gz"

  if command -v mandb >/dev/null 2>&1; then
    quiet_run with_sudo mandb || true
  fi
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
  log "[apktool] adding manpage"
  _install_manpage_from_pandoc
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
