#!/usr/bin/env bash
###############################################################################
# Setup routing policy for headless partner nodes.
# Ethernet is preferred management uplink, Wi-Fi is fallback, modems are proxy-only.
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RECONCILE_SCRIPT="/usr/local/bin/partner-node-network-reconcile.sh"
LEGACY_COMPAT_SCRIPT="/usr/local/bin/auto-modem-setup.sh"
LEGACY_ENFORCE_SCRIPT="/usr/local/bin/enforce-wifi-routing.sh"
RECONCILE_SERVICE="/etc/systemd/system/partner-node-network-reconcile.service"

remove_legacy_cron_entry() {
  local current_cron filtered

  if ! command -v crontab >/dev/null 2>&1; then
    return 0
  fi

  current_cron=$(crontab -l 2>/dev/null || true)
  if [[ -z "${current_cron}" ]]; then
    return 0
  fi
  if ! printf '%s\n' "${current_cron}" | grep -q "enforce-wifi-routing"; then
    return 0
  fi

  filtered=$(printf '%s\n' "${current_cron}" | grep -v "enforce-wifi-routing" || true)
  if [[ -n "${filtered//[$' \t\r\n']/}" ]]; then
    printf '%s\n' "${filtered}" | crontab -
  else
    crontab -r 2>/dev/null || true
  fi
}

setup_routing() {
  require_root

  log_info "Setting up calm network reconcile policy for headless nodes"

  mkdir -p /usr/local/bin /var/lib/partner-node /var/log/partner-node

  log_info "Removing legacy cron-based route enforcement"
  remove_legacy_cron_entry
  rm -f "${LEGACY_ENFORCE_SCRIPT}"

  log_info "Installing network reconcile helper"
  cat > "${RECONCILE_SCRIPT}" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

PREFERRED_UPLINK_FILE="/var/lib/partner-node/preferred-uplink"
STATE_DIR="/var/lib/partner-node"
LOCK_FILE="${STATE_DIR}/network-reconcile.lock"
STAMP_FILE="${STATE_DIR}/network-reconcile.last"
LOG_FILE="/var/log/partner-node/network-reconcile.log"

TRIGGER="manual"
IFACE=""
ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trigger) TRIGGER="${2:-manual}"; shift 2 ;;
    --iface) IFACE="${2:-}"; shift 2 ;;
    --action) ACTION="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  exit 0
fi

debounce_dispatcher() {
  local now_epoch last_epoch

  [[ "${TRIGGER}" == "dispatcher" ]] || return 0

  now_epoch=$(date +%s)
  last_epoch=0
  if [[ -f "${STAMP_FILE}" ]]; then
    last_epoch=$(head -n 1 "${STAMP_FILE}" 2>/dev/null | tr -d '\r' || echo 0)
  fi
  if [[ -n "${last_epoch}" && "${last_epoch}" =~ ^[0-9]+$ ]]; then
    if (( now_epoch - last_epoch < 2 )); then
      exit 0
    fi
  fi
  printf '%s\n' "${now_epoch}" > "${STAMP_FILE}"
}

log() {
  printf '[%s] trigger=%s iface=%s action=%s %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${TRIGGER}" "${IFACE}" "${ACTION}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

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

list_huawei_ifaces() {
  local iface
  for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}'); do
    [[ "${iface}" == "lo" ]] && continue
    if is_huawei_iface "${iface}"; then
      echo "${iface}"
    fi
  done
}

list_non_huawei_ifaces() {
  local iface
  for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}'); do
    [[ "${iface}" == "lo" ]] && continue
    if ! is_huawei_iface "${iface}"; then
      echo "${iface}"
    fi
  done
}

cleanup_stale_non_huawei_ips() {
  local iface
  for iface in $(list_non_huawei_ifaces); do
    ip addr del 192.168.8.100/24 dev "${iface}" 2>/dev/null || true
    ip addr del 192.168.1.100/24 dev "${iface}" 2>/dev/null || true
  done
}

nm_device_field() {
  local iface="$1"
  local field="$2"
  nmcli -g "${field}" device show "${iface}" 2>/dev/null | head -n 1 | tr -d '\r' || true
}

nm_connection_field() {
  local conn="$1"
  local field="$2"
  nmcli -g "${field}" connection show "${conn}" 2>/dev/null | head -n 1 | tr -d '\r' || true
}

connection_name_for_iface() {
  local iface="$1"
  local conn

  conn=$(nm_device_field "${iface}" "GENERAL.CONNECTION")
  if [[ -n "${conn}" && "${conn}" != "--" ]]; then
    echo "${conn}"
    return 0
  fi

  conn=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v iface="${iface}" '$2 == iface { print $1; exit }')
  if [[ -n "${conn}" ]]; then
    echo "${conn}"
    return 0
  fi

  return 1
}

device_type() {
  local iface="$1"
  nm_device_field "${iface}" "GENERAL.TYPE"
}

device_gateway() {
  local iface="$1"
  local gateway

  gateway=$(nm_device_field "${iface}" "IP4.GATEWAY")
  if [[ -z "${gateway}" ]]; then
    gateway=$(ip route show dev "${iface}" 2>/dev/null | awk '/^default via / {print $3; exit}')
  fi
  echo "${gateway}"
}

iface_has_ipv4() {
  local iface="$1"
  ip -4 -o addr show dev "${iface}" scope global 2>/dev/null | grep -q 'inet '
}

connected_iface_by_type() {
  local target_type="$1"
  nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: -v target="${target_type}" '$2 == target && $3 == "connected" { print $1; exit }'
}

remember_preferred_uplink() {
  local iface="$1"
  [[ -n "${iface}" ]] || return 0
  printf '%s\n' "${iface}" > "${PREFERRED_UPLINK_FILE}"
}

load_preferred_uplink() {
  [[ -f "${PREFERRED_UPLINK_FILE}" ]] || return 1
  head -n 1 "${PREFERRED_UPLINK_FILE}" | tr -d '\r'
}

preferred_uplink_iface() {
  local iface remembered current_default

  iface=$(connected_iface_by_type "ethernet")
  if [[ -n "${iface}" && -d "/sys/class/net/${iface}" ]] && ! is_huawei_iface "${iface}"; then
    echo "${iface}"
    return 0
  fi

  iface=$(connected_iface_by_type "wifi")
  if [[ -n "${iface}" && -d "/sys/class/net/${iface}" ]] && ! is_huawei_iface "${iface}"; then
    echo "${iface}"
    return 0
  fi

  remembered=$(load_preferred_uplink || true)
  if [[ -n "${remembered}" && -d "/sys/class/net/${remembered}" ]] && ! is_huawei_iface "${remembered}" && iface_has_ipv4 "${remembered}"; then
    echo "${remembered}"
    return 0
  fi

  current_default=$(ip route show default 2>/dev/null | awk '/^default/ {for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit }}')
  if [[ -n "${current_default}" && -d "/sys/class/net/${current_default}" ]] && ! is_huawei_iface "${current_default}" && iface_has_ipv4 "${current_default}"; then
    echo "${current_default}"
    return 0
  fi

  for iface in $(list_non_huawei_ifaces); do
    if [[ "$(device_type "${iface}")" == "ethernet" ]] && iface_has_ipv4 "${iface}"; then
      echo "${iface}"
      return 0
    fi
  done

  for iface in $(list_non_huawei_ifaces); do
    if [[ "$(device_type "${iface}")" == "wifi" ]] && iface_has_ipv4 "${iface}"; then
      echo "${iface}"
      return 0
    fi
  done

  return 1
}

ensure_connection_profile() {
  local conn="$1"
  local autoconnect="$2"
  local priority="$3"
  local never_default="$4"
  local metric="$5"
  local current_autoconnect current_priority current_never_default current_metric

  [[ -n "${conn}" ]] || return 0

  current_autoconnect=$(nm_connection_field "${conn}" "connection.autoconnect")
  current_priority=$(nm_connection_field "${conn}" "connection.autoconnect-priority")
  current_never_default=$(nm_connection_field "${conn}" "ipv4.never-default")
  current_metric=$(nm_connection_field "${conn}" "ipv4.route-metric")

  if [[ "${current_autoconnect}" == "${autoconnect}" && \
        "${current_priority}" == "${priority}" && \
        "${current_never_default}" == "${never_default}" && \
        "${current_metric}" == "${metric}" ]]; then
    return 0
  fi

  log "updating connection profile ${conn} autoconnect=${autoconnect} priority=${priority} never_default=${never_default} metric=${metric}"
  nmcli connection modify "${conn}" \
    connection.autoconnect "${autoconnect}" \
    connection.autoconnect-priority "${priority}" \
    ipv4.never-default "${never_default}" \
    ipv6.never-default "${never_default}" \
    ipv4.route-metric "${metric}" \
    ipv6.route-metric "${metric}" >/dev/null 2>&1 || true
}

uplink_metric_for_type() {
  local type="$1"
  case "${type}" in
    ethernet) echo "40" ;;
    wifi) echo "80" ;;
    *) echo "120" ;;
  esac
}

uplink_priority_for_type() {
  local type="$1"
  case "${type}" in
    ethernet) echo "200" ;;
    wifi) echo "100" ;;
    *) echo "50" ;;
  esac
}

ensure_uplink_profile() {
  local iface="$1"
  local conn type metric priority

  conn=$(connection_name_for_iface "${iface}" || true)
  type=$(device_type "${iface}")
  metric=$(uplink_metric_for_type "${type}")
  priority=$(uplink_priority_for_type "${type}")

  if [[ -n "${conn}" ]]; then
    ensure_connection_profile "${conn}" "yes" "${priority}" "no" "${metric}"
  fi
}

ensure_modem_profile() {
  local iface="$1"
  local conn

  conn=$(connection_name_for_iface "${iface}" || true)
  if [[ -n "${conn}" ]]; then
    ensure_connection_profile "${conn}" "yes" "-100" "yes" "700"
  fi
}

remove_modem_default_routes() {
  local iface route
  for iface in $(list_huawei_ifaces); do
    while IFS= read -r route; do
      [[ -z "${route}" ]] && continue
      ip route del ${route} 2>/dev/null || true
      log "removed modem default route iface=${iface} route=${route}"
    done < <(ip route show default dev "${iface}" 2>/dev/null || true)
  done
}

set_runtime_default_route() {
  local iface="$1"
  local gateway type metric

  [[ -n "${iface}" ]] || return 0
  gateway=$(device_gateway "${iface}")
  type=$(device_type "${iface}")
  metric=$(uplink_metric_for_type "${type}")

  if [[ -n "${gateway}" ]]; then
    ip route replace default via "${gateway}" dev "${iface}" metric "${metric}" 2>/dev/null || true
    log "set default route iface=${iface} gateway=${gateway} metric=${metric}"
  fi
}

reconcile_source_routing() {
  local iface local_ip prefix gateway table_id

  for iface in $(list_huawei_ifaces); do
    local_ip=$(ip -4 -o addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4}' | head -n 1 | cut -d/ -f1)
    [[ -n "${local_ip}" ]] || continue

    prefix=$(echo "${local_ip}" | awk -F. '{print $1 "." $2 "." $3}')
    gateway="${prefix}.1"
    table_id=$(echo "${iface}" | cksum | awk '{print 1000 + ($1 % 200)}')

    ip rule del from "${local_ip}/32" table "${table_id}" 2>/dev/null || true
    ip route flush table "${table_id}" 2>/dev/null || true

    ip route add "${prefix}.0/24" dev "${iface}" src "${local_ip}" table "${table_id}" 2>/dev/null || true
    ip route add default via "${gateway}" dev "${iface}" table "${table_id}" 2>/dev/null || true
    ip rule add from "${local_ip}/32" table "${table_id}" priority "${table_id}" 2>/dev/null || true
  done
}

main() {
  local iface uplink_iface

  debounce_dispatcher
  cleanup_stale_non_huawei_ips

  for iface in $(list_huawei_ifaces); do
    ensure_modem_profile "${iface}"
  done
  remove_modem_default_routes

  uplink_iface=$(preferred_uplink_iface || true)
  if [[ -n "${uplink_iface}" ]]; then
    remember_preferred_uplink "${uplink_iface}"
    ensure_uplink_profile "${uplink_iface}"
    set_runtime_default_route "${uplink_iface}"
    log "preferred uplink=${uplink_iface}"
  else
    log "no active preferred uplink found"
  fi

  reconcile_source_routing
}

main
SCRIPT
  chmod 0755 "${RECONCILE_SCRIPT}"

  log_info "Installing compatibility wrapper for manual modem-policy refresh"
  cat > "${LEGACY_COMPAT_SCRIPT}" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
exec /usr/local/bin/partner-node-network-reconcile.sh --trigger compat "$@"
SCRIPT
  chmod 0755 "${LEGACY_COMPAT_SCRIPT}"

  log_info "Installing boot-time reconcile service"
  cat > "${RECONCILE_SERVICE}" <<EOF
[Unit]
Description=Partner Node Network Reconcile
After=NetworkManager.service network-online.target
Wants=network-online.target
Before=partner-node.service

[Service]
Type=oneshot
ExecStart=${RECONCILE_SCRIPT} --trigger boot

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${RECONCILE_SERVICE}"

  systemctl daemon-reload
  systemctl enable partner-node-network-reconcile.service >/dev/null 2>&1 || true

  log_info "Running reconcile once immediately"
  "${RECONCILE_SCRIPT}" --trigger install || true

  log_info "Current default routes:"
  ip route show | grep "^default" || log_warn "No default route found"

  log_info "вњ… Routing policy installed"
  log_info "Ethernet is now preferred as management uplink, Wi-Fi is fallback, modems stay proxy-only"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_routing "$@"
fi
