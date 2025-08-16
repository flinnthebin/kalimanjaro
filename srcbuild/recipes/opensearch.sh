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
: "${NAME:=opensearch}"
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
  log "[${NAME}] preflight: package availability"
  pacman -Si opensearch >/dev/null 2>&1 || warn "[opensearch] pacman cannot see 'opensearch'"
  if pacman -Qi jdk21-openjdk >/dev/null 2>&1; then
    log "[${NAME}] using existing jdk21-openjdk (will not install headless JRE)"
  fi
}
fetch()  { :; }
build()  { :; }

install() {
  log "[${NAME}] installing + enabling"
  quiet_run with_sudo pacman -S --needed --noconfirm opensearch >/dev/null 2>&1 || true

  local jvm="/etc/opensearch/jvm.options"
  if [[ -f "$jvm" ]]; then
    quiet_run with_sudo sed -i -E \
      "s/^-Xms[0-9]+[mg]/-Xms${OPENSEARCH_HEAP_GB}g/; s/^-Xmx[0-9]+[mg]/-Xmx${OPENSEARCH_HEAP_GB}g/" "$jvm"
  fi

  quiet_run with_sudo systemctl enable --now opensearch

  # try to auto-detect URL/creds first if not set
  _probe_es || true

  # wait up to 90s for at least YELLOW health
  for _ in $(seq 1 90); do
    if [[ "$ES_URL" == https://* ]]; then
      curl_flags="-ks"
    else
      curl_flags="-s"
    fi
    if [[ -n "${ES_USER:-}" ]]; then
      curl $curl_flags -u "${ES_USER}:${ES_PASS}" \
        "${ES_URL}/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null && { log "[${NAME}] healthy at ${ES_URL}"; break; }
    else
      curl $curl_flags \
        "${ES_URL}/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null && { log "[${NAME}] healthy at ${ES_URL}"; break; }
    fi
    sleep 1
  done || true
}

post() {
  log "[${NAME}] post: smoke"
  systemctl is-active --quiet opensearch || warn "[${NAME}] service not active"

  _probe_es || warn "[${NAME}] probe couldn't contact OpenSearch"

  if [[ "$ES_URL" == https://* ]]; then curl_flags="-ks"; else curl_flags="-s"; fi
  if [[ -n "${ES_USER:-}" ]]; then
    curl $curl_flags -u "${ES_USER}:${ES_PASS}" "${ES_URL}" | grep -q '{' || warn "[${NAME}] HTTP probe failed"
  else
    curl $curl_flags "${ES_URL}" | grep -q '{' || warn "[${NAME}] HTTP probe failed"
  fi
}

uninstall() {
  log "[${NAME}] stopping & disabling service"
  with_sudo systemctl disable --now opensearch 2>/dev/null || true

  # Prefer clean package removal on Arch/Manjaro
  if command -v pacman >/dev/null 2>&1 && pacman -Qq opensearch &>/dev/null; then
    log "[${NAME}] removing pacman package"
    with_sudo pacman -Rns --noconfirm opensearch >/dev/null 2>&1 || \
      warn "pacman removal failed; continuing with manual cleanup"
  fi

  log "[${NAME}] removing installed files"
  # JVM options & config dirs
  with_sudo rm -rf /etc/opensearch 2>/dev/null || true
  with_sudo rm -rf /usr/share/opensearch 2>/dev/null || true
  with_sudo rm -rf /var/lib/opensearch 2>/dev/null || true
  with_sudo rm -rf /var/log/opensearch 2>/dev/null || true

  # Remove systemd units if they still exist
  rm_if_exists \
    "/usr/lib/systemd/system/opensearch.service" \
    "/etc/systemd/system/opensearch.service"

  with_sudo rm -f /etc/systemd/system/multi-user.target.wants/opensearch.service 2>/dev/null || true

  # Reload systemd so unit removals take effect
  with_sudo systemctl daemon-reload 2>/dev/null || true

  log "[${NAME}] cleanup complete"
}


case "${1:-}" in
  deps|pre|fetch|build|install|post|uninstall) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post|uninstall}" ;;
esac
