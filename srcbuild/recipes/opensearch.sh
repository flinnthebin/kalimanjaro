#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${SRC:?set by srcbuild}"
: "${OPENSEARCH_HEAP_GB:=4}"      # override: OPENSEARCH_HEAP_GB=12 ./srcbuild opensearch
: "${ES_URL:=https://localhost:9200}"
: "${ES_USER:=admin}"
: "${ES_PASS:=admin}"
# ---------- env ----------

deps() {
  # Always need opensearch + curl
  local pkgs=(opensearch curl)
  # If a Java 21 provider is already installed (full JDK or headless JRE), don't add another.
  if pacman -Qi jdk21-openjdk >/dev/null 2>&1 || pacman -Qi jre21-openjdk-headless >/dev/null 2>&1; then
    :
  else
    pkgs+=(jre21-openjdk-headless)
  fi

  printf '%s\n' "${pkgs[@]}"
}

pre() {
  log "[opensearch] preflight: package availability"
  pacman -Si opensearch >/dev/null 2>&1 || warn "[opensearch] pacman cannot see 'opensearch'"
  if pacman -Qi jdk21-openjdk >/dev/null 2>&1; then
    log "[opensearch] using existing jdk21-openjdk (will not install headless JRE)"
  fi
}
fetch()  { :; }
build()  { :; }

install() {
  log "[opensearch] installing + enabling"
  quiet_run with_sudo pacman -S --needed --noconfirm opensearch >/dev/null 2>&1 || true

  local jvm="/etc/opensearch/jvm.options"
  if [[ -f "$jvm" ]]; then
    quiet_run with_sudo sed -i -E \
      "s/^-Xms[0-9]+[mg]/-Xms${OPENSEARCH_HEAP_GB}g/; s/^-Xmx[0-9]+[mg]/-Xmx${OPENSEARCH_HEAP_GB}g/" "$jvm"
  fi

  quiet_run with_sudo systemctl enable --now opensearch

  # wait (best-effort)
  local tries=30
  while (( tries-- )); do
    if curl -ks -u "${ES_USER}:${ES_PASS}" "${ES_URL}/_cat/health" >/dev/null; then
      log "[opensearch] healthy at ${ES_URL}"
      break
    fi
    sleep 1
  done
  (( tries >= 0 )) || warn "[opensearch] health check timed out"
}

post() {
  log "[opensearch] post: smoke"
  systemctl is-active --quiet opensearch || warn "[opensearch] service not active"
  curl -ks -u "${ES_USER}:${ES_PASS}" "${ES_URL}" | grep -q '{' || warn "[opensearch] HTTP probe failed"
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
