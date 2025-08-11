#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- Env knobs (override via runner env) ----------
: "${ARK_IFACE:=wlp4s0}"               # leave empty -> auto-detect first UP non-lo
: "${ARK_ES_URL:=https://localhost:9200}"  # OpenSearch often defaults to HTTPS with security plugin
: "${ARK_ES_USER:=admin}"              # default OpenSearch creds on fresh install
: "${ARK_ES_PASS:=admin}"
: "${ARK_ILS:=ism}"                    # ism | ilm | none
: "${ARK_UI_ADMIN:=admin}"             # Arkime UI username
: "${ARK_UI_NAME:=Admin User}"         # Arkime UI full name
: "${ARK_UI_PASS:=changeme}"           # Arkime UI password
: "${ARK_VIEW_PORT:=8005}"             # Arkime viewer port
: "${ARK_AUTH_MODE:=digest}"           # digest | basic | anonymous
: "${ARK_DOWNLOAD_GEOIP:=no}"          # yes | no
: "${ARK_FORCE_REWRITE_CFG:=1}"        # 1 = overwrite existing config.ini
: "${OPENSEARCH_HEAP_GB:=4}"           # adjust JVM heap for OpenSearch

# ---------- Deps (runner installs) ----------
deps() { cat <<EOF
curl
jq
iproute2
ethtool
libcap
jre21-openjdk-headless
opensearch
EOF
}

# ---------- Fetch Arkime package ----------
fetch() {
  require_cmd curl
  require_cmd jq
  LOG "[arkime] discovering latest stable release (GitHub)"
  mkdir -p "$SRC"
  local api="https://api.github.com/repos/arkime/arkime/releases/latest"
  local url
  url="$(curl -fsSL "$api" \
       | jq -r '.assets[]?.browser_download_url | select(test("_arch-x86_64\\.pkg\\.tar\\.zst$"))' \
       | head -n1)" || true
  [[ -n "$url" ]] || DIE "[arkime] could not find Arch package in latest release"

  LOG "[arkime] downloading $(basename "$url")"
  quiet_run curl -fsSL "$url" -o "$SRC/arkime.pkg.tar.zst"
}

build() { :; }

# ---------- Helper: ensure & configure OpenSearch ----------
_setup_opensearch() {
  LOG "[arkime] ensuring OpenSearch + JRE installed"
  quiet_run with_sudo pacman -S --needed --noconfirm jre21-openjdk-headless opensearch >/dev/null 2>&1 || true

  local jvm="/etc/opensearch/jvm.options"
  if [[ -f "$jvm" ]]; then
    LOG "[arkime] setting OpenSearch heap to ${OPENSEARCH_HEAP_GB}g"
    with_sudo sed -i -E "s/^-Xms[0-9]+[mg]/-Xms${OPENSEARCH_HEAP_GB}g/; s/^-Xmx[0-9]+[mg]/-Xmx${OPENSEARCH_HEAP_GB}g/" "$jvm"
  fi

  LOG "[arkime] enabling & starting OpenSearch"
  quiet_run with_sudo systemctl enable --now opensearch

  # Wait for HTTP to come up
  local tries=60
  local curl_extra=()
  [[ "$ARK_ES_URL" == https:* ]] && curl_extra+=(-k)
  LOG "[arkime] waiting for OpenSearch at ${ARK_ES_URL}"
  while (( tries-- )); do
    if [[ -n "$ARK_ES_USER$ARK_ES_PASS" ]]; then
      if curl -s "${curl_extra[@]}" -u "${ARK_ES_USER}:${ARK_ES_PASS}" "${ARK_ES_URL}/_cat/health" >/dev/null; then
        LOG "[arkime] OpenSearch is up"
        return 0
      fi
    else
      if curl -s "${curl_extra[@]}" "${ARK_ES_URL}/_cat/health" >/dev/null; then
        LOG "[arkime] OpenSearch is up (no auth)"
        return 0
      fi
    fi
    sleep 1
  done
  DIE "[arkime] OpenSearch did not become ready at ${ARK_ES_URL}"
}

install() {
  local pkg="$SRC/arkime.pkg.tar.zst"
  [[ -f "$pkg" ]] || DIE "[arkime] package not found"

  # --- 1) OpenSearch setup first ---
  _setup_opensearch

  # --- 2) Arkime package install ---
  LOG "[arkime] installing Arkime package"
  quiet_run with_sudo pacman -U --noconfirm "$pkg"

  # Ensure service account exists (pkg should create it, but idempotent)
  with_sudo sh -c 'getent passwd arkime >/dev/null || useradd -r -d /opt/arkime -s /usr/bin/nologin arkime'

  # Interface selection
  local iface="${ARK_IFACE:-}"
  if [[ -z "$iface" ]]; then
    iface="$(ip -br link 2>/dev/null | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}')"
    [[ -z "$iface" ]] && iface="$(ip -br link 2>/dev/null | awk '$1!="lo"{print $1; exit}')"
  else
    if ! ip -br link 2>/dev/null | awk -v want="$iface" '$1==want {found=1} END{exit found?0:1}'; then
      WARN "[arkime] interface '$iface' not found; auto-selecting an UP interface"
      iface="$(ip -br link 2>/dev/null | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}')"
      [[ -z "$iface" ]] && iface="$(ip -br link 2>/dev/null | awk '$1!="lo"{print $1; exit}')"
    fi
  fi

  local es_url="${ARK_ES_URL}"
  local es_user="${ARK_ES_USER}"
  local es_pass="${ARK_ES_PASS}"
  local ils="${ARK_ILS:-none}"
  local ui_user="${ARK_UI_ADMIN:-admin}"
  local ui_name="${ARK_UI_NAME:-Admin User}"
  local ui_pass="${ARK_UI_PASS:-changeme}"
  local view_port="${ARK_VIEW_PORT:-8005}"
  local auth_mode="${ARK_AUTH_MODE:-digest}"
  local want_geo="${ARK_DOWNLOAD_GEOIP:-no}"
  local force_cfg="${ARK_FORCE_REWRITE_CFG:-0}"

  # Write config.ini
  local cfg="/opt/arkime/etc/config.ini"
  if [[ ! -f "$cfg" || "$force_cfg" == "1" ]]; then
    LOG "[arkime] writing $cfg (iface=$iface, es=$es_url, viewer=$view_port, authMode=$auth_mode)"
    with_sudo install -d /opt/arkime/etc
    with_sudo tee "$cfg" >/dev/null <<EOF
[default]
# Core
interface = ${iface}
opensearch = ${es_url}

# UI / auth
viewPort = ${view_port}
authMode = ${auth_mode}

# PCAP & misc sane defaults
pcapDir = /opt/arkime/raw
pcapWriteMethod = simple
maxFileSizeG = 12
maxESConns = 20
dnsMemoryCache = true
smtpIpHeader = Received, X-Forwarded-For

# GeoIP (off by default unless you provision geoipupdate)
# geoLite2Country = /usr/share/GeoIP/GeoLite2-Country.mmdb
# geoLite2ASN     = /usr/share/GeoIP/GeoLite2-ASN.mmdb
EOF
  else
    LOG "[arkime] using existing $cfg"
    with_sudo sed -i -E \
      "s#^(opensearch|elasticsearch)\s*=.*#opensearch = ${es_url}#; \
       s#^interface\s*=.*#interface = ${iface}#; \
       s#^viewPort\s*=.*#viewPort = ${view_port}#; \
       s#^authMode\s*=.*#authMode = ${auth_mode}#" "$cfg"
  fi

  # Dirs + perms + caps
  with_sudo install -d /opt/arkime/raw /opt/arkime/logs
  with_sudo chown -R arkime:arkime /opt/arkime/raw /opt/arkime/logs
  quiet_run with_sudo setcap cap_net_raw,cap_net_admin+eip /opt/arkime/bin/capture || true

  # Initialize indices
  if [[ "$ils" != "none" ]]; then
    LOG "[arkime] initializing indices on ${es_url} with ${ils}"
  else
    LOG "[arkime] initializing indices on ${es_url}"
  fi
  if [[ -n "$es_user" || -n "$es_pass" ]]; then
    case "$ils" in
      ilm)  with_sudo /opt/arkime/db/db.pl --esuser "$es_user:$es_pass" "$es_url" init --ilm ;;
      ism)  with_sudo /opt/arkime/db/db.pl --esuser "$es_user:$es_pass" "$es_url" init --ism ;;
      *)    with_sudo /opt/arkime/db/db.pl --esuser "$es_user:$es_pass" "$es_url" init ;;
    esac
  else
    case "$ils" in
      ilm)  with_sudo /opt/arkime/db/db.pl "$es_url" init --ilm ;;
      ism)  with_sudo /opt/arkime/db/db.pl "$es_url" init --ism ;;
      *)    with_sudo /opt/arkime/db/db.pl "$es_url" init ;;
    esac
  fi

  # Optional GeoIP
  if [[ "$want_geo" == "yes" ]]; then
    WARN "[arkime] GeoIP download requires MaxMind setup; skipping automation."
  fi

  # Ensure an admin UI user exists
  if [[ -n "$ui_user" && -n "$ui_pass" ]]; then
    LOG "[arkime] ensuring UI admin user '$ui_user' exists"
    with_sudo /opt/arkime/bin/arkime_add_user.sh "$ui_user" "$ui_name" "$ui_pass" --admin >/dev/null 2>&1 || true
  fi

  # Enable & start services
  LOG "[arkime] enabling Arkime services"
  quiet_run with_sudo systemctl enable --now arkimecapture
  quiet_run with_sudo systemctl enable --now arkimeviewer

  # Wait for viewer health
  local vurl="http://localhost:${view_port}"
  local tries=30
  while (( tries-- )); do
    if [[ "$auth_mode" == "anonymous" ]]; then
      curl -s "$vurl/eshealth.json" | grep -q '{' && { LOG "[arkime] viewer healthy at ${vurl}"; break; }
    else
      curl -s --digest -u "${ui_user}:${ui_pass}" "$vurl/eshealth.json" | grep -q '{' && { LOG "[arkime] viewer healthy at ${vurl}"; break; }
