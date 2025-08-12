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
: "${PREFIX:=/usr/local}"
: "${SRC:?set by srcbuild}"

: "${MANA_VERSION:=2.6.4}"
: "${MANA_URL:=https://github.com/sensepost/hostapd-mana/releases/download/${MANA_VERSION}/hostapd-mana-ELF-x86-64.zip}"
: "${MANA_BIN:=hostapd-mana}"
: "${MANA_FORCE_REINSTALL:=0}"
# ---------- env ----------

deps() { cat <<'EOF'
curl
unzip
libcap
EOF
}

pre() {
  log "[hostapd-mana] preflight: checking download URL"
  curl -fsI "$MANA_URL" >/dev/null || warn "[hostapd-mana] HEAD request failed (will try anyway)"
}


fetch() {
  require_cmd curl
  require_cmd unzip
  log "[hostapd-mana] fetching prebuilt ELF ${MANA_VERSION}"
  mkdir -p "$SRC"
  local zip="$SRC/hostapd-mana.zip"
  quiet_run curl -fL "$MANA_URL" -o "$zip"

  # List contents and extract
  mapfile -t entries < <(unzip -Z1 "$zip" 2>/dev/null || true)
  [[ ${#entries[@]} -gt 0 ]] || die "[hostapd-mana] ZIP appears empty"

  quiet_run unzip -o "$zip" -d "$SRC/unzip" >/dev/null

  # Prefer explicit names; fall back to “first executable ELF”
  local hostapd_path="" hostapd_cli_path=""

  # find hostapd
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    case "$base" in
      hostapd)        hostapd_path="$f"; break ;;
    esac
  done < <(find "$SRC/unzip" -type f -name 'hostapd' -print0)

  # find hostapd_cli (optional)
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    case "$base" in
      hostapd_cli)    hostapd_cli_path="$f"; break ;;
    esac
  done < <(find "$SRC/unzip" -type f -name 'hostapd_cli' -print0)

  # Fallback: first executable ELF if hostapd not found by name
  if [[ -z "$hostapd_path" ]]; then
    while IFS= read -r -d '' f; do
      if file "$f" 2>/dev/null | grep -q 'ELF .* executable'; then
        hostapd_path="$f"; break
      fi
    done < <(find "$SRC/unzip" -type f -print0)
  fi

  [[ -n "$hostapd_path" ]] || die "[hostapd-mana] could not find an executable hostapd in ZIP"

  cp -f "$hostapd_path" "$SRC/${MANA_BIN}"
  chmod +x "$SRC/${MANA_BIN}"

  if [[ -n "$hostapd_cli_path" ]]; then
    cp -f "$hostapd_cli_path" "$SRC/${MANA_BIN}_cli"
    chmod +x "$SRC/${MANA_BIN}_cli"
  fi
}

build() { :; }  # prebuilt

install() {
  local destbin="${PREFIX}/bin/${MANA_BIN}"
  log "[hostapd-mana] installing ${destbin}"
  quiet_run with_sudo install -Dm755 "$SRC/${MANA_BIN}" "$destbin"
  quiet_run with_sudo setcap cap_net_admin,cap_net_raw+eip "$destbin" || warn "[hostapd-mana] setcap failed; run as root"

  # Optional CLI
  if [[ -f "$SRC/${MANA_BIN}_cli" ]]; then
    local destcli="${PREFIX}/bin/${MANA_BIN}_cli"
    quiet_run with_sudo install -Dm755 "$SRC/${MANA_BIN}_cli" "$destcli"
  fi

  log "[hostapd-mana] installing config skeleton"
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

  local unit=/etc/systemd/system/hostapd-mana@.service
  if [[ ! -f "$unit" ]]; then
    with_sudo tee "$unit" >/dev/null <<UNIT
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

  log "[hostapd-mana] installed. Try: sudo systemctl enable --now hostapd-mana@hostapd"
}

post() {
  log "[hostapd-mana] post: smoke"
  "${PREFIX}/bin/${MANA_BIN}" -v >/dev/null 2>&1 || warn "[hostapd-mana] version probe failed (run as root?)"
  command -v "${PREFIX}/bin/${MANA_BIN}" >/dev/null || die "[hostapd-mana] binary not in PATH"
}

case "${1:-}" in
  deps|pre|fetch|build|install|post) "$1" ;;
  *) die "usage: $0 {deps|pre|fetch|build|install|post}" ;;
esac
