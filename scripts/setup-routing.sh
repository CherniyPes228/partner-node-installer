#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Partner Node Routing Setup
# Configures system to use WiFi/Ethernet for main traffic,
# and modem ONLY for 3proxy proxy traffic
###############################################################################

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

setup_routing() {
  log_info "Setting up routing: system via WiFi/Ethernet, proxy via modem"

  # Find modem interfaces (USB modems typically have enx* names)
  local modem_interfaces
  modem_interfaces=$(ip link 2>/dev/null | grep "enx" | awk '{print $2}' | sed 's/:$//' || true)

  if [[ -z "$modem_interfaces" ]]; then
    log_warn "No modem interfaces (enx*) detected. Skipping routing setup."
    return 0
  fi

  log_info "Found modem interface(s): $modem_interfaces"

  # Remove default routes from modems (they should only route local traffic)
  for iface in $modem_interfaces; do
    log_info "Removing default route from modem interface: $iface"

    # Try to remove any default route via this interface
    ip route show | grep "^default" | grep "$iface" | while read route; do
      ip route del $route 2>/dev/null || true
    done
  done

  # Create NetworkManager dispatcher script for persistent routing
  log_info "Creating NetworkManager dispatcher for persistent routing"
  mkdir -p /etc/NetworkManager/dispatcher.d

  cat > /etc/NetworkManager/dispatcher.d/99-modem-routing << 'DISPATCHER_SCRIPT'
#!/bin/bash

INTERFACE=$1
ACTION=$2

# Fix routing when modem interface comes up
if [[ "$INTERFACE" =~ ^enx && "$ACTION" == "up" ]]; then
  sleep 1

  # Remove any default routes from this modem interface
  ip route show | grep "^default" | grep "$INTERFACE" | while read route; do
    ip route del $route 2>/dev/null || true
  done

  echo "[$(date)] Fixed routing for $INTERFACE" >> /var/log/modem-routing.log 2>&1 || true
fi
DISPATCHER_SCRIPT

  chmod +x /etc/NetworkManager/dispatcher.d/99-modem-routing
  log_info "NetworkManager dispatcher script created at /etc/NetworkManager/dispatcher.d/99-modem-routing"

  # Verify routing state
  log_info "Current routing configuration:"
  ip route show | grep "^default" || log_warn "No default route configured!"

  log_info "Routing setup complete!"
  log_info "✅ System traffic: WiFi/Ethernet (default route)"
  log_info "✅ Proxy traffic: Modem (via 3proxy on localhost:31001+)"
}

# Run setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $EUID -ne 0 ]]; then
    log_err "This script must be run as root"
    exit 1
  fi
  setup_routing
fi
