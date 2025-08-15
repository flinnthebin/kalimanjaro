#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
: "${REPO=https://github.com/sensepost/berate_ap}"
: "${FILE=berate_ap}"
: "${NAME="berate-ap"}"
# ---------- env ----------

deps() {
  # core deps
  local want=(
    git
    bash
    util-linux
    procps-ng
    iproute2
    iw
    wireless_tools
    dnsmasq
  )

  # Pick exactly one iptables backend to avoid conflicts:
  if pacman -Qq iptables >/dev/null 2>&1; then
    # legacy backend present — keep it, don't add iptables-nft
    :
  elif pacman -Qq iptables-nft >/dev/null 2>&1; then
    # nft backend present — fine
    :
  else
    # none present — prefer nft backend
    want+=(iptables-nft)
  fi

  printf '%s\n' "${want[@]}"
}

_preflight_warns() {
  # hostapd-mana is required by berate-ap (not plain hostapd).
  if ! command -v hostapd-mana >/dev/null 2>&1; then
    warn "[${NAME}] hostapd-mana not found in PATH. Build/install it (AUR: hostapd-mana[-git]) before running attacks."
  fi
  for c in ip iw iptables dnsmasq; do
    command -v "${c}" >/dev/null 2>&1 || warn "[${NAME}] missing runtime tool: ${c}"
  done
}

pre() {
  log "[${NAME}] preflight: repo + deps"
  curl -fsI "${REPO}" >/dev/null || warn "[${NAME}] GitHub HEAD failed"
  _preflight_warns
}

fetch() {
  require_cmd git
  log "[${NAME}] fetching sources"
  quiet_run git clone --depth=1 "${REPO}" "${SRC}"
}

build() { :; }  # shell script only

install() {
  log "[${NAME}] installing"
  # Script
  quiet_run with_sudo install -Dm755 "${SRC}/${FILE}" "${PREFIX}/bin/${NAME}"

  # Bash completion (if available)
  if [[ -f "${SRC}/bash_completion" ]]; then
    quiet_run with_sudo install -Dm644 "${SRC}/bash_completion" /usr/share/bash-completion/completions/"${NAME}"
  fi

  # Config
  quiet_run with_sudo install -d /etc/berate-ap
  if [[ -f "${SRC}/${FILE}.conf" ]]; then
    quiet_run with_sudo install -Dm644 "${SRC}/${FILE}.conf" /etc/"${NAME}/${FILE}".conf
  else
    # minimal default
    with_sudo tee /etc/berate-ap/berate_ap.conf >/dev/null <<'CFG'
# berate-ap default configuration (edit as needed)
# Examples:
# ARGS="--eap --mana wlan0 eth0 MyAccessPoint"
ARGS=""
CFG
  fi

  # Systemd unit
  local unit=/etc/systemd/system/berate-ap.service
  if [[ -f "${SRC}/berate-ap.service" ]]; then
    # adapt ExecStart path & config location if needed
    sed -E \
      -e "s#/etc/berate-ap/berate-ap.conf#/etc/berate-ap/berate-ap.conf#g" \
      -e "s#/usr/bin/berate-ap#${PREFIX}/bin/berate-ap#g" \
      "${SRC}/berate-ap.service" | with_sudo tee "${unit}" >/dev/null
  else
    # fallback minimal unit
    with_sudo tee "${unit}" >/dev/null <<UNIT
[Unit]
Description=berate-ap rogue AP orchestrator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/berate-ap/berate-ap.conf
ExecStart=${PREFIX}/bin/berate-ap \${ARGS}
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  fi

  quiet_run with_sudo systemctl daemon-reload
  log "[berate-ap] installed to ${PREFIX}/bin/${NAME}"
  _preflight_warns
}

post() {
  log "[${NAME}] post: smoke"
  "${PREFIX}/bin/${NAME}" --help >/dev/null || warn "[${NAME}] --help returned non-zero"
  command -v hostapd-mana >/dev/null 2>&1 || warn "[${NAME}] hostapd-mana still missing (required by upstream)"
  log "[${NAME}] tip: set ARGS in /etc/berate-ap/berate_ap.conf then: sudo systemctl enable --now berate-ap"
}

uninstall() {
  log "[${NAME}] stopping service"
  if command -v systemctl >/dev/null 2>&1; then
    with_sudo systemctl disable --now berate_ap 2>/dev/null || true
    rm_if_exists "/etc/systemd/system/berate_ap.service"
    with_sudo systemctl daemon-reload 2>/dev/null || true
  fi

  log "[${NAME}] killing orchestrator + helpers"
  with_sudo pkill -x berate_ap 2>/dev/null || true
  with_sudo pkill -x hostapd-mana 2>/dev/null || true
  with_sudo pkill -x dnsmasq 2>/dev/null || true

  log "[${NAME}] removing files"
  rm_if_exists \
    "$PREFIX/bin/berate_ap" \
    "/usr/share/bash-completion/completions/berate_ap"

  with_sudo rm -rf /etc/berate_ap 2>/dev/null || true

  log "[$NAME] cleanup complete"
}

case "${1:-}" in
  deps|pre|fetch|build|install|post|uninstall) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post|uninstall}" ;;
esac
