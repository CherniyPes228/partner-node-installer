#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Setup USB modem routing policy
# Keeps Huawei HiLink modems managed but prevents them from stealing
# the host default route. Only proxy/source-bound traffic should leave
# through the modem interface.
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SETUP_SCRIPT="/usr/local/bin/auto-modem-setup.sh"
NM_DISPATCHER="/etc/NetworkManager/dispatcher.d/90-huawei-modem-routing"

log_info "Configuring USB modem routing policy..."

log_info "  Creating helper script for Huawei modem setup..."
sudo tee "$SETUP_SCRIPT" > /dev/null << 'SCRIPT'
#!/bin/bash
set -euo pipefail

PREFERRED_UPLINK_FILE="/var/lib/partner-node/preferred-uplink"

is_huawei_iface() {
  local iface="$1"
  local path vendor
  path=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)
  while [[ -n "$path" && "$path" != "/" ]]; do
    if [[ -f "$path/idVendor" ]]; then
      vendor=$(tr '[:upper:]' '[:lower:]' < "$path/idVendor" 2>/dev/null || true)
      [[ "$vendor" == "12d1" ]]
      return
    fi
    path=$(dirname "$path")
  done
  return 1
}

list_huawei_ifaces() {
  local iface
  for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}'); do
    [[ "$iface" == "lo" ]] && continue
    if is_huawei_iface "$iface"; then
      echo "$iface"
    fi
  done
}

list_non_huawei_ifaces() {
  local iface
  for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}'); do
    [[ "$iface" == "lo" ]] && continue
    if ! is_huawei_iface "$iface"; then
      echo "$iface"
    fi
  done
}

cleanup_stale_non_huawei_ips() {
  local iface
  for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}'); do
    [[ "$iface" == "lo" ]] && continue
    if is_huawei_iface "$iface"; then
      continue
    fi
    ip addr del 192.168.8.100/24 dev "$iface" 2>/dev/null || true
    ip addr del 192.168.1.100/24 dev "$iface" 2>/dev/null || true
  done
}

configure_nm_connection() {
  local iface="$1"
  local conn

  nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
  conn=$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null | head -n 1 | tr -d '\r' || true)
  if [[ -z "$conn" || "$conn" == "--" ]]; then
    nmcli device connect "$iface" >/dev/null 2>&1 || true
    conn=$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null | head -n 1 | tr -d '\r' || true)
  fi

  if [[ -n "$conn" && "$conn" != "--" ]]; then
    nmcli connection modify "$conn" \
      ipv4.never-default yes \
      ipv6.never-default yes \
      ipv4.route-metric 1000 \
      ipv6.route-metric 1000 \
      connection.autoconnect-priority -50 \
      connection.autoconnect yes >/dev/null 2>&1 || true
    nmcli device reapply "$iface" >/dev/null 2>&1 || true
  fi
}

load_preferred_uplink() {
  [[ -f "$PREFERRED_UPLINK_FILE" ]] || return 1
  head -n 1 "$PREFERRED_UPLINK_FILE" | tr -d '\r'
}

preferred_uplink_iface() {
  local iface remembered

  remembered=$(load_preferred_uplink || true)
  if [[ -n "$remembered" && -d "/sys/class/net/$remembered" ]] && ! is_huawei_iface "$remembered"; then
    echo "$remembered"
    return 0
  fi

  iface=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }')
  if [[ -n "$iface" ]] && ! is_huawei_iface "$iface"; then
    echo "$iface"
    return 0
  fi

  iface=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: '$2 == "ethernet" && $3 == "connected" { print $1; exit }')
  if [[ -n "$iface" ]] && ! is_huawei_iface "$iface"; then
    echo "$iface"
    return 0
  fi

  for iface in $(list_non_huawei_ifaces); do
    if ip -4 -o addr show dev "$iface" scope global 2>/dev/null | grep -q 'inet '; then
      echo "$iface"
      return 0
    fi
  done

  return 1
}

configure_uplink_connection() {
  local iface="$1"
  local conn type metric

  [[ -n "$iface" ]] || return 0
  nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
  conn=$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null | head -n 1 | tr -d '\r' || true)
  if [[ -z "$conn" || "$conn" == "--" ]]; then
    nmcli device connect "$iface" >/dev/null 2>&1 || true
    conn=$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null | head -n 1 | tr -d '\r' || true)
  fi

  type=$(nmcli -g GENERAL.TYPE device show "$iface" 2>/dev/null | head -n 1 | tr -d '\r' || true)
  case "$type" in
    wifi) metric=40 ;;
    ethernet) metric=60 ;;
    *) metric=80 ;;
  esac

  if [[ -n "$conn" && "$conn" != "--" ]]; then
    nmcli connection modify "$conn" \
      connection.autoconnect yes \
      connection.autoconnect-priority 100 \
      ipv4.never-default no \
      ipv6.never-default no \
      ipv4.route-metric "$metric" \
      ipv6.route-metric "$metric" >/dev/null 2>&1 || true
    nmcli device reapply "$iface" >/dev/null 2>&1 || true
    nmcli connection up "$conn" ifname "$iface" >/dev/null 2>&1 || true
  fi
}

cleanup_stale_non_huawei_ips

if command -v nmcli >/dev/null 2>&1; then
  for iface in $(list_huawei_ifaces); do
    configure_nm_connection "$iface"
  done

  uplink_iface=$(preferred_uplink_iface || true)
  if [[ -n "${uplink_iface:-}" ]]; then
    configure_uplink_connection "$uplink_iface"
  fi
fi

if [[ -x /usr/local/bin/enforce-wifi-routing.sh ]]; then
  /usr/local/bin/enforce-wifi-routing.sh >/dev/null 2>&1 || true
fi

echo "OK: Huawei modem routing policy refreshed"
SCRIPT
sudo chmod +x "$SETUP_SCRIPT"

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
  log_info "  Creating NetworkManager dispatcher for Huawei modem routing..."
  sudo mkdir -p "$(dirname "$NM_DISPATCHER")"
  sudo tee "$NM_DISPATCHER" > /dev/null << 'DISPATCHER'
#!/bin/bash
set -euo pipefail

action="${2:-}"

case "$action" in
  up|down|dhcp4-change|dhcp6-change|connectivity-change|reapply|vpn-up|vpn-down|hostname)
    /usr/local/bin/auto-modem-setup.sh >/dev/null 2>&1 || true
    ;;
esac
DISPATCHER
  sudo chmod +x "$NM_DISPATCHER"
  log_info "  NetworkManager dispatcher installed."
else
  log_info "  NetworkManager is not active; only manual helper installed."
fi

# Remove old netplan-based behavior. NetworkManager/dispatcher now owns this.
sudo rm -f /etc/netplan/90-auto-modem-dhcp.yaml
sudo rm -f /etc/netplan/99-modem-disable.yaml

# Ensure /etc/3proxy is writable
log_info "  Ensuring /etc/3proxy directory permissions..."
sudo chmod 755 /etc/3proxy 2>/dev/null || true

# Create cron job to ensure /etc/3proxy is always writable (handles remount RO issues)
log_info "  Setting up cron job for filesystem health..."
sudo tee /etc/cron.hourly/partner-node-fs-health > /dev/null << 'CRON'
#!/bin/bash
# Ensure partner-node filesystem directories are writable
chmod 755 /etc/3proxy 2>/dev/null || true
chmod 755 /var/lib/partner-node 2>/dev/null || true
CRON
sudo chmod +x /etc/cron.hourly/partner-node-fs-health

sleep 2

log_info "вњ… USB modem routing policy setup complete"
log_info "   Huawei modems will stay reachable but not become the host default internet route"
log_info "   Helper script: $SETUP_SCRIPT"
if [[ -f "$NM_DISPATCHER" ]]; then
  log_info "   NetworkManager dispatcher: $NM_DISPATCHER"
fi
log_info "   Filesystem health job: /etc/cron.hourly/partner-node-fs-health"
