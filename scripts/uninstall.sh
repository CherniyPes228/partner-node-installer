#!/usr/bin/env bash

###############################################################################
# Partner Node Uninstaller
# Removes partner-node services, configs, local UI and related helper scripts
###############################################################################

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -n "${0:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
  SCRIPT_DIR="."
fi

set -euo pipefail

LIB_DIR="/tmp/partner-node-uninstall-lib-$$"
mkdir -p "$LIB_DIR"

curl -fsSL https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/lib/common.sh -o "$LIB_DIR/common.sh" 2>/dev/null || {
  echo "Failed to download common.sh - check internet connection"
  exit 1
}

source "$LIB_DIR/common.sh"

PURGE_PACKAGES="false"
KEEP_PROXY_CONFIG="false"
APPLY_NETPLAN="false"
SERVICE_NAME="${SERVICE_NAME:-partner-node}"
UI_SERVICE_NAME="${UI_SERVICE_NAME:-partner-node-ui}"

usage() {
  cat <<EOF
Partner Node Uninstaller

Usage: $0 [OPTIONS]

Optional:
  --purge-packages      Also remove installed packages (3proxy, wireguard, modemmanager)
  --keep-proxy-config   Keep /etc/3proxy/3proxy.conf
  --apply-netplan       Apply netplan after uninstall (disabled by default to keep connectivity)
  --skip-netplan-apply  Explicitly skip netplan apply after uninstall
  --help, -h            Show this help message

Examples:
  $0
  curl -fsSL https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/uninstall.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/uninstall.sh | sudo bash -s -- --purge-packages
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge-packages) PURGE_PACKAGES="true"; shift ;;
      --keep-proxy-config) KEEP_PROXY_CONFIG="true"; shift ;;
      --apply-netplan) APPLY_NETPLAN="true"; shift ;;
      --skip-netplan-apply) APPLY_NETPLAN="false"; shift ;;
      --help|-h) usage; exit 0 ;;
      *)
        log_err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

stop_and_disable_service() {
  local svc="$1"
  if systemctl list-unit-files | grep -q "^${svc}\.service"; then
    log_info "Stopping ${svc}.service"
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  fi
  if systemctl list-unit-files | grep -q "^${svc}\.timer"; then
    log_info "Stopping ${svc}.timer"
    systemctl stop "${svc}.timer" 2>/dev/null || true
    systemctl disable "${svc}.timer" 2>/dev/null || true
  fi
}

remove_if_exists() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf "$path"
    log_info "Removed $path"
  fi
}

remove_glob_matches() {
  local pattern="$1"
  local matches=()
  shopt -s nullglob
  matches=( $pattern )
  shopt -u nullglob
  local path
  for path in "${matches[@]}"; do
    rm -rf "$path"
    log_info "Removed $path"
  done
}

remove_cron_entry() {
  local pattern="$1"
  local current
  current=$(crontab -l 2>/dev/null || true)
  if [[ -n "$current" ]] && echo "$current" | grep -q "$pattern"; then
    echo "$current" | grep -v "$pattern" | crontab -
    log_info "Removed cron entry matching: $pattern"
  fi
}

read_config_scalar() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^\\s*${key}:\\s*\"\\{0,1\\}\\([^\"#]*\\)\"\\{0,1\\}\\s*$/\\1/p" "$file" | head -n 1
}

read_node_id_from_credentials() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -n 's/^node_id=//p' "$file" | head -n 1
}

best_effort_reset_node_registry() {
  local config_file="/etc/partner-node/config.yaml"
  local credentials_file="/var/lib/partner-node/node_credentials"
  local partner_key=""
  local main_server=""
  local node_id=""

  partner_key="$(read_config_scalar "$config_file" "partner_key" | tr -d '\r')"
  main_server="$(read_config_scalar "$config_file" "main_server" | tr -d '\r')"
  node_id="$(read_node_id_from_credentials "$credentials_file" | tr -d '\r')"

  if [[ -z "$partner_key" || -z "$main_server" || -z "$node_id" ]]; then
    log_info "Skipping server-side node modem registry reset (missing partner_key, main_server or node_id)"
    return 0
  fi

  log_info "Requesting server-side modem registry reset for node ${node_id}"
  curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -d "{\"partner_key\":\"${partner_key}\",\"node_id\":\"${node_id}\"}" \
    "${main_server%/}/api/partner/reset-node" >/dev/null 2>&1 || \
    log_warn "Server-side node modem registry reset failed; continuing with local uninstall"
}

purge_packages() {
  local distro
  distro=$(get_distro)

  case "$distro" in
    debian|ubuntu)
      DEBIAN_FRONTEND=noninteractive apt-get remove -y 3proxy wireguard wireguard-tools modemmanager usb-modeswitch 2>/dev/null || true
      DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
      ;;
    centos|rhel|fedora)
      if command_exists dnf; then
        dnf remove -y 3proxy wireguard-tools ModemManager usb_modeswitch 2>/dev/null || true
      elif command_exists yum; then
        yum remove -y 3proxy wireguard-tools ModemManager usb_modeswitch 2>/dev/null || true
      fi
      ;;
    *)
      log_warn "Package purge not implemented for distro: $distro"
      ;;
  esac
}

main() {
  require_root
  parse_args "$@"

  log_info "╔════════════════════════════════════════════════════════════╗"
  log_info "║                 Partner Node Uninstall                   ║"
  log_info "╚════════════════════════════════════════════════════════════╝"

  best_effort_reset_node_registry

  stop_and_disable_service "$SERVICE_NAME"
  stop_and_disable_service "$UI_SERVICE_NAME"
  stop_and_disable_service "partner-node-self-update"
  stop_and_disable_service "disable-modem"
  stop_and_disable_service "3proxy"

  pkill -9 -f "/usr/local/bin/node-agent -config /etc/partner-node/config.yaml" 2>/dev/null || true
  pkill -9 -f "/usr/local/bin/node-agent" 2>/dev/null || true
  pkill -9 -f "/opt/partner-node-ui/server.py" 2>/dev/null || true

  remove_cron_entry "enforce-wifi-routing"

  remove_if_exists "/etc/systemd/system/${SERVICE_NAME}.service"
  remove_if_exists "/etc/systemd/system/${UI_SERVICE_NAME}.service"
  remove_if_exists "/etc/systemd/system/partner-node-self-update.service"
  remove_if_exists "/etc/systemd/system/partner-node-self-update.timer"
  remove_if_exists "/etc/systemd/system/disable-modem.service"
  remove_if_exists "/etc/systemd/system/3proxy.service.d/override.conf"
  remove_if_exists "/etc/systemd/system/3proxy.service.d"

  systemctl daemon-reload || true

  remove_if_exists "/usr/local/bin/node-agent"
  remove_if_exists "/usr/local/bin/node-agent-wrapper.sh"
  remove_if_exists "/usr/local/bin/doctor"
  remove_if_exists "/usr/local/bin/enforce-wifi-routing.sh"
  remove_if_exists "/usr/local/bin/auto-modem-setup.sh"
  remove_if_exists "/usr/local/sbin/partner-node-self-update.sh"
  remove_if_exists "/usr/local/sbin/partner-node-flash-e3372h.sh"
  remove_if_exists "/usr/local/sbin/partner-node-flash-hilink.sh"
  remove_if_exists "/usr/local/sbin/partner-node-needle-mod.sh"
  remove_if_exists "/usr/local/sbin/partner-node-set-modem-ip.sh"
  remove_if_exists "/usr/local/sbin/recover-e3372h-clean"
  remove_if_exists "/usr/local/sbin/recover-e3372h-needle"

  remove_if_exists "/etc/partner-node"
  remove_if_exists "/var/lib/partner-node"
  remove_if_exists "/var/log/partner-node"
  remove_if_exists "/opt/partner-node-ui"
  remove_if_exists "/opt/partner-node-flash"

  remove_if_exists "/etc/netplan/90-auto-modem-dhcp.yaml"
  remove_if_exists "/etc/netplan/99-modem-disable.yaml"
  remove_if_exists "/etc/NetworkManager/dispatcher.d/90-huawei-modem-routing"
  remove_if_exists "/etc/cron.hourly/partner-node-fs-health"
  remove_if_exists "/var/log/modem-routing.log"
  remove_if_exists "/etc/sudoers.d/partner-node-support"
  remove_if_exists "/var/log/3proxy"
  remove_if_exists "/tmp/node-agent-download"
  remove_if_exists "/tmp/3proxy.deb"
  remove_if_exists "/tmp/e3372_last_flash_port"
  remove_if_exists "/tmp/e3372_fastboot_product.txt"
  remove_glob_matches "/tmp/e3372-live*.log"
  remove_glob_matches "/tmp/e3372-live-after-recovery.log*"
  remove_glob_matches "/tmp/e3372-*.log"
  remove_glob_matches "/tmp/partner-node-uninstall-lib-*"
  remove_glob_matches "/tmp/partner-node-installer-lib-*"

  for home_dir in /home/*; do
    [[ -d "$home_dir/.ssh" ]] || continue
    if [[ -f "$home_dir/.ssh/authorized_keys" ]]; then
      sed -i '/partner-node-support/d' "$home_dir/.ssh/authorized_keys" 2>/dev/null || true
    fi
  done

  if [[ "$KEEP_PROXY_CONFIG" != "true" ]]; then
    remove_if_exists "/etc/3proxy"
  fi

  if [[ "$PURGE_PACKAGES" == "true" ]]; then
    log_info "Purging related packages"
    purge_packages
  else
    log_info "Keeping system packages (3proxy, wireguard, modemmanager)"
  fi

  if [[ "$APPLY_NETPLAN" == "true" ]] && command_exists netplan; then
    netplan apply 2>/dev/null || true
  else
    log_info "Skipping netplan apply during uninstall to avoid disrupting active connectivity"
  fi

  log_info ""
  log_info "Partner node removed"
  log_info "Next install command can be run on a clean host state"
}

main "$@"
