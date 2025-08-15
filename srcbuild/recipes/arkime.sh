#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${SRC:?set by srcbuild}"
: "${NAME:=arkime}"
: "${API:=https://api.github.com/repos/arkime/arkime/releases/latest}"
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
  [[ -n "${user}" || -n "${pass}" ]] && auth=(-u "${user}:${pass}")
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
  if [[ -n "${want}" ]] && ip -br link 2>/dev/null | awk -v w="${want}" '$1==w {found=1} END{exit found?0:1}'; then
    echo "${want}"; return 0
  fi
  ip -br link 2>/dev/null | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}' && return 0
  ip -br link 2>/dev/null | awk '$1!="lo"{print $1; exit}' && return 0
  return 1
}

pre() {
  log "[${NAME}] preflight: check release API & OpenSearch availability"

  # 1) Arkime release API reachable (non-fatal)
  curl -fsI "${API}" >/dev/null \
    || warn "[${NAME}] GitHub API not reachable (continuing)"

  # 2) Require OpenSearch
  if _es_up "${ARK_ES_URL}" "${ARK_ES_USER}" "${ARK_ES_PASS}" 5; then
    log "[${NAME}] OpenSearch OK at ${ARK_ES_URL}"
  else
    # Nice hint if using local service
    if [[ "${ARK_ES_URL}" =~ ^https?://(localhost|127\.0\.0\.1)(:|/|$) ]]; then
      if ! systemctl is-active --quiet opensearch 2>/dev/null; then
        die "[${NAME}] OpenSearch not reachable at ${ARK_ES_URL} and service not active. Start it: ./srcbuild opensearch"
      fi
    fi
    die "[${NAME}] OpenSearch not reachable at ${ARK_ES_URL}. Set ARK_ES_URL/ARK_ES_USER/ARK_ES_PASS or start your cluster."
  fi
}

fetch() {
  require_cmd curl; require_cmd jq
  log "[${NAME}] discovering latest Arch package asset"
  mkdir -p "${SRC}/${NAME}"
  local url
  url="$(curl -fsSL "${API}" \
       | jq -r '.assets[]?.browser_download_url | select(test("_arch-x86_64\\.pkg\\.tar\\.zst$"))' \
       | head -n1)" || true
  [[ -n "${url}" ]] || die "[${NAME}] could not find Arch package in latest release"
  log "[${NAME}] downloading $(basename "${url}")"
  quiet_run curl -fsSL "${url}" -o "${SRC}/${NAME}/${NAME}.pkg.tar.zst"
}

build() { :; }

install() {
  local pkg="${SRC}/${NAME}/${NAME}.pkg.tar.zst"
  [[ -f "${pkg}" ]] || die "[${NAME}] package not found (run fetch first)"

  log "[${NAME}] installing package"
  quiet_run with_sudo pacman -U --noconfirm "${pkg}"

  # ensure service account (pkg *should* create; keep idempotent)
  quiet_run with_sudo sh -c "getent passwd ${NAME} >/dev/null || useradd -r -d /opt/${NAME} -s /usr/bin/nologin ${NAME}"

  # pick interface
  local iface; iface="$(_prefer_iface "${ARK_IFACE}")" || die "[${NAME}] no suitable interface found"

  # write config
  local cfg="/opt/${NAME}/etc/config.ini"
  if [[ ! -f "${cfg}" || "${ARK_FORCE_REWRITE_CFG}" == "1" ]]; then
    log "[${NAME}] writing ${cfg} (iface=${iface}, es=${ARK_ES_URL}, viewer=${ARK_VIEW_PORT}, auth=${ARK_AUTH_MODE})"
    quiet_run with_sudo install -d /opt/arkime/etc /opt/arkime/raw /opt/arkime/logs
    with_sudo tee "${cfg}" >/dev/null <<EOF
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
    log "[arkime] keeping existing ${cfg}"
    quiet_run with_sudo sed -i -E \
      "s#^(opensearch|elasticsearch)\s*=.*#opensearch = ${ARK_ES_URL}#; \
       s#^interface\s*=.*#interface = ${iface}#; \
       s#^viewPort\s*=.*#viewPort = ${ARK_VIEW_PORT}#; \
       s#^authMode\s*=.*#authMode = ${ARK_AUTH_MODE}#" "${cfg}"
  fi

  quiet_run with_sudo chown -R arkime:arkime /opt/arkime/raw /opt/arkime/logs
  quiet_run with_sudo setcap cap_net_raw,cap_net_admin+eip /opt/arkime/bin/capture || true

  # init indices
  log "[${NAME}] initializing indices (${ARK_ILS:-none})"
  if [[ -n "${ARK_ES_USER}" || -n "${ARK_ES_PASS}" ]]; then
    case "${ARK_ILS}" in
      ilm) with_sudo /opt/arkime/db/db.pl --esuser "${ARK_ES_USER}:${ARK_ES_PASS}" "${ARK_ES_URL}" init --ilm ;;
      ism) with_sudo /opt/arkime/db/db.pl --esuser "${ARK_ES_USER}:${ARK_ES_PASS}" "${ARK_ES_URL}" init --ism ;;
      *)   with_sudo /opt/arkime/db/db.pl --esuser "${ARK_ES_USER}:${ARK_ES_PASS}" "${ARK_ES_URL}" init ;;
    esac
  else
    case "${ARK_ILS}" in
      ilm) with_sudo /opt/arkime/db/db.pl "${ARK_ES_URL}" init --ilm ;;
      ism) with_sudo /opt/arkime/db/db.pl "${ARK_ES_URL}" init --ism ;;
      *)   with_sudo /opt/arkime/db/db.pl "${ARK_ES_URL}" init ;;
    esac
  fi

  # admin user
  if [[ -n "${ARK_UI_ADMIN}" && -n "${ARK_UI_PASS}" ]]; then
    log "[${NAME}] ensuring UI user '${ARK_UI_ADMIN}'"
    quiet_run with_sudo "/opt/${NAME}/bin/arkime_add_user.sh" \
      "${ARK_UI_ADMIN}" "${ARK_UI_NAME}" "${ARK_UI_PASS}" --admin || true
  fi

  # enable & start services
  log "[${NAME}] enabling services (arkimecapture, arkimeviewer)"
  quiet_run with_sudo systemctl enable --now arkimecapture
  quiet_run with_sudo systemctl enable --now arkimeviewer

  # wait for viewer
  local vurl="http://localhost:${ARK_VIEW_PORT}"
  local tries=30
  while (( tries-- )); do
    if [[ "${ARK_AUTH_MODE}" == "anonymous" ]]; then
      curl -s "${vurl}/eshealth.json" | grep -q '{' && { log "[${NAME}] viewer healthy at ${vurl}"; break; }
    else
      curl -s --digest -u "${ARK_UI_ADMIN}:${ARK_UI_PASS}" "${vurl}/eshealth.json" | grep -q '{' && { log "[${NAME}] viewer healthy at ${vurl}"; break; }
    fi
    sleep 1
  done
  (( tries >= 0 )) || warn "[${NAME}] viewer health not reachable yet; check /opt/${NAME}/logs/viewer.log"

  log "[${NAME}] install + configure complete"
}

post() {
  log "[${NAME}] post: smoke"
  systemctl is-active --quiet arkimecapture || warn "[${NAME}] arkimecapture not active"
  systemctl is-active --quiet arkimeviewer  || warn "[${NAME}] arkimeviewer not active"
  /opt/arkime/bin/capture -v >/dev/null 2>&1 || warn "[${NAME}] capture -v failed"
  curl -s "http://localhost:${ARK_VIEW_PORT}/eshealth.json" | grep -q '{' || warn "[${NAME}] eshealth probe failed"
}

uninstall() {
  log "[${NAME}] stopping & disabling services"
  with_sudo systemctl disable --now arkimecapture arkimeviewer 2>/dev/null || true

  # Prefer clean package removal on Arch/Manjaro
  if command -v pacman >/dev/null 2>&1 && pacman -Qq arkime &>/dev/null; then
    log "[${NAME}] removing pacman package"
    with_sudo pacman -Rns --noconfirm arkime >/dev/null 2>&1 || warn "pacman removal failed; continuing with manual cleanup"
  fi

  log "[${NAME}] removing installed files"
  # Logrotate config
  rm_if_exists "/etc/logrotate.d/arkime"

  # Systemd unit files (package usually installs under /usr/lib)
  rm_if_exists \
    "/usr/lib/systemd/system/arkimecapture.service" \
    "/usr/lib/systemd/system/arkimeviewer.service" \
    "/etc/systemd/system/arkimecapture.service" \
    "/etc/systemd/system/arkimeviewer.service"

  # Remove any dangling symlinks from wants/
  with_sudo rm -f /etc/systemd/system/multi-user.target.wants/arkimecapture.service 2>/dev/null || true
  with_sudo rm -f /etc/systemd/system/multi-user.target.wants/arkimeviewer.service 2>/dev/null || true

  # Main install tree
  with_sudo rm -rf "/opt/arkime" 2>/dev/null || true

  # Reload systemd so unit removals take effect
  with_sudo systemctl daemon-reload 2>/dev/null || true

  log "[${NAME}] cleanup complete"
}


case "${1:-}" in
  deps|pre|fetch|build|install|post|uninstall) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post|uninstall}" ;;
esac

