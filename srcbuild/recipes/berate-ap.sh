#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
[[ -f "./lib/common.sh" ]] && source "./lib/common.sh"

# ---------- env ----------
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"
: "${REPO=https://github.com/sensepost/berate_ap}"
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
    warn "[berate-ap] hostapd-mana not found in PATH. Build/install it (AUR: hostapd-mana[-git]) before running attacks."
  fi
  for c in ip iw iptables dnsmasq; do
    command -v "$c" >/dev/null 2>&1 || warn "[berate-ap] missing runtime tool: $c"
  done
}

pre() {
  log "[berate-ap] preflight: repo + deps"
  curl -fsI "$REPO" >/dev/null || warn "[berate-ap] GitHub HEAD failed"
  _preflight_warns
}

fetch() {
  require_cmd git
  log "[berate-ap] fetching sources"
  quiet_run git clone --depth=1 "$REPO" "$SRC"
}

build() { :; }  # shell script only

install() {
  log "[berate-ap] installing"
  # Script
  quiet_run with_sudo install -Dm755 "$SRC/berate_ap" "$PREFIX/bin/berate-ap"

  # Bash completion (if available)
  if [[ -f "$SRC/bash_completion" ]]; then
    quiet_run with_sudo install -Dm644 "$SRC/bash_completion" /usr/share/bash-completion/completions/berate-ap
  fi

  # Config
  quiet_run with_sudo install -d /etc/berate-ap
  if [[ -f "$SRC/berate_ap.conf" ]]; then
    quiet_run with_sudo install -Dm644 "$SRC/berate_ap.conf" /etc/berate-ap/berate_ap.conf
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
  if [[ -f "$SRC/berate-ap.service" ]]; then
    # adapt ExecStart path & config location if needed
    sed -E \
      -e "s#/etc/berate-ap/berate-ap.conf#/etc/berate-ap/berate-ap.conf#g" \
      -e "s#/usr/bin/berate-ap#${PREFIX}/bin/berate-ap#g" \
      "$SRC/berate-ap.service" | with_sudo tee "$unit" >/dev/null
  else
    # fallback minimal unit
    with_sudo tee "$unit" >/dev/null <<UNIT
[Unit]
Description=berate-ap rogue AP orchestrator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/berate-ap/berate-ap.conf
ExecStart=${PREFIX}/bin/berate-ap \$ARGS
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  fi

  quiet_run with_sudo systemctl daemon-reload
  log "[berate-ap] installed to ${PREFIX}/bin/berate-ap"
  _preflight_warns
}

post() {
  log "[berate-ap] post: smoke"
  "${PREFIX}/bin/berate-ap" --help >/dev/null || warn "[berate-ap] --help returned non-zero"
  command -v hostapd-mana >/dev/null 2>&1 || warn "[berate-ap] hostapd-mana still missing (required by upstream)"
  log "[berate-ap] tip: set ARGS in /etc/berate-ap/berate-ap.conf then: sudo systemctl enable --now berate-ap"
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
