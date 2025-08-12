#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${SRC:?set by srcbuild}"
# Arkime runtime knobs (override via env)
: "${ARK_IFACE:=wlp4s0}"                 # if empty -> auto pick first UP non-lo
: "${ARK_ES_URL:=http://localhost:9200}"
: "${ARK_ES_USER:=}"               # optional
: "${ARK_ES_PASS:=}"               # optional
: "${ARK_ILS:=ism}"                # ism | ilm | none
: "${ARK_UI_ADMIN:=admin}"
: "${ARK_UI_NAME:=Admin User}"
: "${ARK_UI_PASS:=changeme}"
: "${ARK_VIEW_PORT:=8005}"
: "${ARK_AUTH_MODE:=digest}"       # digest | basic | anonymous
: "${ARK_DOWNLOAD_GEOIP:=no}"      # yes | no
: "${ARK_FORCE_REWRITE_CFG:=1}"    # 1 overwrite config.ini if present
# ---------- env ----------

deps() { cat <<'EOF'
curl
jq
iproute2
ethtool
libcap
EOF
}

_es_up() {
  local url="${1:?}" user="${2:-}" pass="${3:-}" tries="${4:-5}"
  local auth=()
  [[ -n "$user" || -n "$pass" ]] && auth=(-u "${user}:${pass}")
  while (( tries-- )); do
    # accept self-signed certs (-k), be quiet (-s), fast timeout
    if curl -ks "${auth[@]}" --max-time 2 "${url}/_cluster/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

_prefer_iface() {
  local want="${1:-}"
  if [[ -n "$want" ]] && ip -br link 2>/dev/null | awk -v w="$want" '$1==w {found=1} END{exit found?0:1}'; then
    echo "$want"; return 0
  fi
  ip -br link 2>/dev/null | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}' && return 0
  ip -br link 2>/dev/null | awk '$1!="lo"{print $1; exit}' && return 0
  return 1
}

pre() {
  log "[arkime] preflight: check release API & OpenSearch availability"

  # 1) Arkime release API reachable (non-fatal)
  curl -fsI "https://api.github.com/repos/arkime/arkime/releases/latest" >/dev/null \
    || warn "[arkime] GitHub API not reachable (will try to proceed)"

  # 2) Require OpenSearch to be reachable (fatal if not)
  if _es_up "$ARK_ES_URL" "$ARK_ES_USER" "$ARK_ES_PASS" 5; then
    log "[arkime] OpenSearch OK at ${ARK_ES_URL}"
  else
    # Nice hint if using local service
    if [[ "$ARK_ES_URL" =~ ^https?://(localhost|127\.0\.0\.1)(:|/|$) ]]; then
      if ! systemctl is-active --quiet opensearch 2>/dev/null; then
        die "[arkime] OpenSearch not reachable at ${ARK_ES_URL} and service not active. Start it: ./srcbuild opensearch"
      fi
    fi
    die "[arkime] OpenSearch not reachable at ${ARK_ES_URL}. Set ARK_ES_URL/ARK_ES_USER/ARK_ES_PASS or start your cluster."
  fi
}

fetch() {
  require_cmd curl; require_cmd jq
  log "[arkime] discovering latest Arch package asset"
  mkdir -p "$SRC/arkime"
  local api="https://api.github.com/repos/arkime/arkime/releases/latest"
  local url
  url="$(curl -fsSL "$api" \
       | jq -r '.assets[]?.browser_download_url | select(test("_arch-x86_64\\.pkg\\.tar\\.zst$"))' \
       | head -n1)" || true
  [[ -n "$url" ]] || die "[arkime] could not find Arch package in latest release"
  log "[arkime] downloading $(basename "$url")"
  quiet_run curl -fsSL "$url" -o "$SRC/arkime/arkime.pkg.tar.zst"
}

build() { :; }

install() {
  local pkg="$SRC/arkime/arkime.pkg.tar.zst"
  [[ -f "$pkg" ]] || die "[arkime] package not found (run fetch first)"

  log "[arkime] installing package"
  quiet_run with_sudo pacman -U --noconfirm "$pkg"

  # ensure service account (pkg *should* create; keep idempotent)
  quiet_run with_sudo sh -c 'getent passwd arkime >/dev/null || useradd -r -d /opt/arkime -s /usr/bin/nologin arkime'

  # pick interface
  local iface; iface="$(_prefer_iface "$ARK_IFACE")" || die "[arkime] no suitable interface found"

  # write config
  local cfg="/opt/arkime/etc/config.ini"
  if [[ ! -f "$cfg" || "$ARK_FORCE_REWRITE_CFG" == "1" ]]; then
    log "[arkime] writing $cfg (iface=$iface, es=$ARK_ES_URL, viewer=$ARK_VIEW_PORT, auth=$ARK_AUTH_MODE)"
    quiet_run with_sudo install -d /opt/arkime/etc /opt/arkime/raw /opt/arkime/logs
    with_sudo tee "$cfg" >/dev/null <<EOF
[default]
interface = ${iface}
opensearch = ${ARK_ES_URL}
viewPort = ${ARK_VIEW_PORT}
authMode = ${ARK_AUTH_MODE}
pcapDir = /opt/arkime/raw
pcapWriteMethod = simple
maxFileSizeG = 12
maxESConns = 20
dnsMemoryCache = true
smtpIpHeader = Received, X-Forwarded-For
EOF
  else
    log "[arkime] keeping existing $cfg"
    quiet_run with_sudo sed -i -E \
      "s#^(opensearch|elasticsearch)\s*=.*#opensearch = ${ARK_ES_URL}#; \
       s#^interface\s*=.*#interface = ${iface}#; \
       s#^viewPort\s*=.*#viewPort = ${ARK_VIEW_PORT}#; \
       s#^authMode\s*=.*#authMode = ${ARK_AUTH_MODE}#" "$cfg"
  fi

  quiet_run with_sudo chown -R arkime:arkime /opt/arkime/raw /opt/arkime/logs
  quiet_run with_sudo setcap cap_net_raw,cap_net_admin+eip /opt/arkime/bin/capture || true

  # init indices
  log "[arkime] initializing indices (${ARK_ILS:-none})"
  if [[ -n "$ARK_ES_USER" || -n "$ARK_ES_PASS" ]]; then
    case "$ARK_ILS" in
      ilm) with_sudo /opt/arkime/db/db.pl --esuser "${ARK_ES_USER}:${ARK_ES_PASS}" "${ARK_ES_URL}" init --ilm ;;
      ism) with_sudo /opt/arkime/db/db.pl --esuser "${ARK_ES_USER}:${ARK_ES_PASS}" "${ARK_ES_URL}" init --ism ;;
      *)   with_sudo /opt/arkime/db/db.pl --esuser "${ARK_ES_USER}:${ARK_ES_PASS}" "${ARK_ES_URL}" init ;;
    esac
  else
    case "$ARK_ILS" in
      ilm) with_sudo /opt/arkime/db/db.pl "${ARK_ES_URL}" init --ilm ;;
      ism) with_sudo /opt/arkime/db/db.pl "${ARK_ES_URL}" init --ism ;;
      *)   with_sudo /opt/arkime/db/db.pl "${ARK_ES_URL}" init ;;
    esac
  fi

  # admin user
  if [[ -n "$ARK_UI_ADMIN" && -n "$ARK_UI_PASS" ]]; then
    log "[arkime] ensuring UI user '${ARK_UI_ADMIN}'"
    quiet_run with_sudo /opt/arkime/bin/arkime_add_user.sh \
      "$ARK_UI_ADMIN" "$ARK_UI_NAME" "$ARK_UI_PASS" --admin || true
  fi

  # enable & start services
  log "[arkime] enabling services (arkimecapture, arkimeviewer)"
  quiet_run with_sudo systemctl enable --now arkimecapture
  quiet_run with_sudo systemctl enable --now arkimeviewer

  # wait for viewer
  local vurl="http://localhost:${ARK_VIEW_PORT}"
  local tries=30
  while (( tries-- )); do
    if [[ "$ARK_AUTH_MODE" == "anonymous" ]]; then
      curl -s "$vurl/eshealth.json" | grep -q '{' && { log "[arkime] viewer healthy at ${vurl}"; break; }
    else
      curl -s --digest -u "${ARK_UI_ADMIN}:${ARK_UI_PASS}" "$vurl/eshealth.json" | grep -q '{' && { log "[arkime] viewer healthy at ${vurl}"; break; }
    fi
    sleep 1
  done
  (( tries >= 0 )) || warn "[arkime] viewer health not reachable yet; check /opt/arkime/logs/viewer.log"

  log "[arkime] install + configure complete"
}

post() {
  log "[arkime] post: smoke"
  systemctl is-active --quiet arkimecapture || warn "[arkime] arkimecapture not active"
  systemctl is-active --quiet arkimeviewer  || warn "[arkime] arkimeviewer not active"
  /opt/arkime/bin/capture -v >/dev/null 2>&1 || warn "[arkime] capture -v failed"
  curl -s "http://localhost:${ARK_VIEW_PORT}/eshealth.json" | grep -q '{' || warn "[arkime] eshealth probe failed"
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac

