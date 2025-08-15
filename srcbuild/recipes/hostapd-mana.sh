#!/usr/bin/env bash
# hostapd-mana: install prebuilt ELF on Arch/Manjaro
# Env knobs:
#   PREFIX=/usr/local
#   MANA_VERSION=2.6.4
#   MANA_URL=https://github.com/sensepost/hostapd-mana/releases/download/2.6.4/hostapd-mana-ELF-x86-64.zip
#   MANA_BIN=hostapd-mana
#   MANA_FORCE_REINSTALL=0

set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${NAME:="hostapd-mana"}"
: "${CLI:="hostapd-mana_cli"}"
: "${PREFIX:=/usr/local}"
: "${BIN:=${PREFIX}/bin}"
: "${SRC:?set by srcbuild}"
: "${MANA_VERSION:=2.6.4}"
: "${MANA_URL:=https://github.com/sensepost/hostapd-mana/releases/download/${MANA_VERSION}/hostapd-mana-ELF-x86-64.zip}"
: "${MANA_FORCE_REINSTALL:=0}"
: "${SYSTEMD:=/etc/systemd/system}"
# ---------- env ----------

deps() { cat <<'EOF'
curl
unzip
libcap
EOF
}

pre() {
  log "[${NAME}] preflight: checking download URL"
  curl -fsI "${MANA_URL}" >/dev/null || warn "[${NAME}] HEAD request failed (will try anyway)"
}


fetch() {
  require_cmd curl
  require_cmd unzip
  log "[$NAME}] fetching prebuilt ELF ${MANA_VERSION}"
  mkdir -p "${SRC}"
  local zip="${SRC}/${NAME}.zip"
  quiet_run curl -fL "${MANA_URL}" -o "${zip}"

  # List contents and extract
  mapfile -t entries < <(unzip -Z1 "${zip}" 2>/dev/null || true)
  [[ ${#entries[@]} -gt 0 ]] || die "[${NAME}] ZIP appears empty"

  quiet_run unzip -o "${zip}" -d "${SRC}/unzip" >/dev/null

  # Prefer explicit names; fall back to “first executable ELF”
  local hostapd_path="" hostapd_cli_path=""

  # find hostapd
  while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    case "${base}" in
      hostapd)        hostapd_path="${f}"; break ;;
    esac
  done < <(find "${SRC}/unzip" -type f -name 'hostapd' -print0)

  # find hostapd_cli (optional)
  while IFS= read -r -d '' f; do
    base="$(basename "${f}")"
    case "${base}" in
      hostapd_cli)    hostapd_cli_path="${f}"; break ;;
    esac
  done < <(find "${SRC}/unzip" -type f -name 'hostapd_cli' -print0)

  # Fallback: first executable ELF if hostapd not found by name
  if [[ -z "${hostapd_path}" ]]; then
    while IFS= read -r -d '' f; do
      if file "${f}" 2>/dev/null | grep -q 'ELF .* executable'; then
        hostapd_path="${f}"; break
      fi
    done < <(find "${SRC}/unzip" -type f -print0)
  fi

  [[ -n "${hostapd_path}" ]] || die "[${NAME}] could not find an executable hostapd in ZIP"

  cp -f "${hostapd_path}" "${SRC}/${NAME}"
  chmod +x "${SRC}/${NAME}"

  if [[ -n "${hostapd_cli_path}" ]]; then
    cp -f "${hostapd_cli_path}" "${SRC}/${CLI}"
    chmod +x "${SRC}/${CLI}"
  fi
}

build() { :; }  # prebuilt

install() {
  local destbin="${BIN}/${NAME}"
  log "[${NAME}] installing ${destbin}"
  quiet_run with_sudo install -Dm755 "${SRC}/${NAME}" "${destbin}"
  quiet_run with_sudo setcap cap_net_admin,cap_net_raw+eip "${destbin}" || warn "[${NAME}] setcap failed; run as root"

  # Optional CLI
  if [[ -f "${SRC}/${CLI}" ]]; then
    local destcli="${BIN}/${CLI}"
    quiet_run with_sudo install -Dm755 "${SRC}/${CLI" "${destcli}"
  fi

  log "[${NAME}] installing config skeleton"
  quiet_run with_sudo install -d /etc/hostapd-mana /var/log/hostapd-mana
  if [[ ! -f /etc/hostapd-mana/hostapd.conf ]]; then
    with_sudo tee /etc/hostapd-mana/hostapd.conf >/dev/null <<'CFG'
# Minimal hostapd-mana example (edit for your interface/SSID/key)
interface=wlan0
driver=nl80211
ssid=ManaAP
hw_mode=g
channel=6
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=passw0rd123
# Mana bits (uncomment as needed)
# enable_mana=1
# mana_wpaout=/var/log/hostapd-mana/wpa.log
# mana_eapsuccess=1
# mana_loud=1
CFG
  fi

  local unit=${SYSTEMD}/${NAME}@.service
  if [[ ! -f "${unit}" ]]; then
    with_sudo tee "${unit}" >/dev/null <<UNIT
[Unit]
Description=hostapd-mana rogue AP (%i)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${destbin} -s -K -t -f /var/log/hostapd-mana/%i.log /etc/hostapd-mana/%i.conf
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    quiet_run with_sudo systemctl daemon-reload
  fi

  log "[${NAME}] installed. Try: sudo systemctl enable --now hostapd-mana@hostapd"
}

post() {
  log "[${NAME}] post: smoke"
  "${BIN}/${NAME}" -v >/dev/null 2>&1 || warn "[${NAME}] version probe failed (run as root?)"
  command -v "${BIN}/${NAME}" >/dev/null || die "[${NAME}] binary not in PATH"
}

uninstall() {
  log "[${NAME}] stopping templated services"
  if command -v systemctl >/dev/null 2>&1; then
    # Stop any active instances
    mapfile -t units < <(systemctl list-units --type=service --state=active 'hostapd-mana@*.service' --no-legend 2>/dev/null | awk '{print $1}')
    for u in "${units[@]}"; do
      [[ -n "$u" ]] && with_sudo systemctl disable --now "$u" 2>/dev/null || true
    done
    # Remove template unit
    rm_if_exists "/etc/systemd/system/hostapd-mana@.service"
    with_sudo systemctl daemon-reload 2>/dev/null || true
  fi

  log "[${NAME}] killing stray processes"
  with_sudo pkill -x hostapd-mana 2>/dev/null || true

  log "[${NAME}] removing binaries, configs, logs"
  rm_if_exists \
    "${BIN}/${NAME}" \
    "${BIN}/${CLI}"


  with_sudo rm -rf /etc/hostapd-mana 2>/dev/null || true
  with_sudo rm -rf /var/log/hostapd-mana 2>/dev/null || true

  # stray control sockets
  with_sudo rm -f /var/run/hostapd*.ctrl 2>/dev/null || true

  log "[${NAME}] cleanup complete"
}


case "${1:-}" in
  deps|pre|fetch|build|install|post|uninstall) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post|uninstall}" ;;
esac
