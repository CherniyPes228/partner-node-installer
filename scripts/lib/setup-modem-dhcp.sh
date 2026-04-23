#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Setup NetworkManager dispatcher for calm modem/uplink reconcile.
# Reuses the shared reconcile helper instead of mutating connections on every event.
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RECONCILE_SCRIPT="/usr/local/bin/partner-node-network-reconcile.sh"
DISPATCHER_PATH="/etc/NetworkManager/dispatcher.d/90-partner-node-network-reconcile"
LEGACY_DISPATCHER="/etc/NetworkManager/dispatcher.d/90-huawei-modem-routing"
LEGACY_DISPATCHER_DISABLED="/etc/NetworkManager/dispatcher.d/90-huawei-modem-routing.disabled"

setup_modem_dhcp() {
  require_root

  log_info "Configuring NetworkManager dispatcher for partner-node network reconcile..."

  rm -f "${LEGACY_DISPATCHER}" "${LEGACY_DISPATCHER_DISABLED}"

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log_info "  Installing NetworkManager dispatcher hook"
    mkdir -p "$(dirname "${DISPATCHER_PATH}")"
    cat > "${DISPATCHER_PATH}" <<'DISPATCHER'
#!/bin/bash
set -euo pipefail

iface="${1:-}"
action="${2:-}"
preferred_file="/var/lib/partner-node/preferred-uplink"
reconcile_script="/usr/local/bin/partner-node-network-reconcile.sh"

is_huawei_iface() {
  local iface="$1"
  local path vendor

  [[ -n "${iface}" ]] || return 1
  path=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
  while [[ -n "${path}" && "${path}" != "/" ]]; do
    if [[ -f "${path}/idVendor" ]]; then
      vendor=$(tr '[:upper:]' '[:lower:]' < "${path}/idVendor" 2>/dev/null || true)
      [[ "${vendor}" == "12d1" ]]
      return
    fi
    path=$(dirname "${path}")
  done
  return 1
}

preferred_uplink_iface() {
  [[ -f "${preferred_file}" ]] || return 1
  head -n 1 "${preferred_file}" | tr -d '\r'
}

is_management_candidate() {
  local iface="$1"
  local type

  type=$(nmcli -g GENERAL.TYPE device show "${iface}" 2>/dev/null | head -n 1 | tr -d '\r' || true)
  [[ "${type}" == "ethernet" || "${type}" == "wifi" ]]
}

case "${action}" in
  up|down|dhcp4-change|dhcp6-change) ;;
  *) exit 0 ;;
esac

[[ -x "${reconcile_script}" ]] || exit 0

preferred_iface="$(preferred_uplink_iface || true)"
if is_huawei_iface "${iface}" || is_management_candidate "${iface}" || [[ -n "${preferred_iface}" && "${iface}" == "${preferred_iface}" ]]; then
  "${reconcile_script}" --trigger dispatcher --iface "${iface}" --action "${action}" >/dev/null 2>&1 || true
fi
DISPATCHER
    chmod 0755 "${DISPATCHER_PATH}"
    log_info "  Dispatcher installed at ${DISPATCHER_PATH}"
  else
    log_info "  NetworkManager is not active; dispatcher hook skipped"
  fi

  rm -f /etc/netplan/90-auto-modem-dhcp.yaml
  rm -f /etc/netplan/99-modem-disable.yaml

  log_info "  Ensuring /etc/3proxy directory permissions..."
  chmod 755 /etc/3proxy 2>/dev/null || true

  log_info "  Setting up cron job for filesystem health..."
  cat > /etc/cron.hourly/partner-node-fs-health <<'CRON'
#!/bin/bash
chmod 755 /etc/3proxy 2>/dev/null || true
chmod 755 /var/lib/partner-node 2>/dev/null || true
CRON
  chmod 0755 /etc/cron.hourly/partner-node-fs-health

  if [[ -x "${RECONCILE_SCRIPT}" ]]; then
    "${RECONCILE_SCRIPT}" --trigger install >/dev/null 2>&1 || true
  fi

  log_info "вњ… NetworkManager dispatcher setup complete"
  log_info "   Relevant interface changes now trigger the shared reconcile helper without NM churn"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_modem_dhcp "$@"
fi
