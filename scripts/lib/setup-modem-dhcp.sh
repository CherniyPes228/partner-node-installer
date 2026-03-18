#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Setup USB Modem Auto-DHCP Configuration
# Ensures USB modems (enx* interfaces) automatically get IP via DHCP
# when plugged in or reconnected
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NETPLAN_FILE="/etc/netplan/90-auto-modem-dhcp.yaml"
SETUP_SCRIPT="/usr/local/bin/auto-modem-setup.sh"

log_info "Configuring auto-DHCP for USB modems..."

# Create netplan configuration for USB modems
log_info "  Creating netplan config for USB modem auto-DHCP..."
sudo tee "$NETPLAN_FILE" > /dev/null << 'NETPLAN'
# Auto-enable DHCP for USB modems (enx* interfaces)
# This ensures modems like Huawei E3372 automatically get IP when connected
network:
  version: 2
  renderer: networkd
  ethernets:
    usb-modem:
      match:
        name: "enx*"
      dhcp4: true
      dhcp6: true
      routes:
        - to: 0.0.0.0/0
          via: 192.168.13.1
          metric: 1000  # Lower priority than WiFi (600)
NETPLAN

# Fix permissions (netplan requires strict permissions)
sudo chmod 600 "$NETPLAN_FILE"

# Remove old config that disabled DHCP (if it exists from previous installations)
if [[ -f "/etc/netplan/99-modem-disable.yaml" ]]; then
  log_info "  Removing old modem-disable config..."
  sudo rm -f "/etc/netplan/99-modem-disable.yaml"
fi

# Create helper script for manual setup if needed
log_info "  Creating helper script for manual modem setup..."
sudo tee "$SETUP_SCRIPT" > /dev/null << 'SCRIPT'
#!/bin/bash
# Auto-configure USB modems with DHCP
# This script ensures that USB modems (enx* interfaces) always get IP via DHCP

set -euo pipefail

NETPLAN_FILE="/etc/netplan/90-auto-modem-dhcp.yaml"

echo "Setting up auto-DHCP for USB modems..."

# Create netplan config for USB modems
sudo tee "$NETPLAN_FILE" > /dev/null << 'NETPLAN'
# Auto-enable DHCP for USB modems (enx* interfaces)
network:
  version: 2
  renderer: networkd
  ethernets:
    usb-modem:
      match:
        name: "enx*"
      dhcp4: true
      dhcp6: true
      routes:
        - to: 0.0.0.0/0
          via: 192.168.13.1
          metric: 1000
NETPLAN

# Fix permissions
sudo chmod 600 "$NETPLAN_FILE"

# Remove old configs that disable modems
sudo rm -f /etc/netplan/99-modem-disable.yaml

# Apply netplan
echo "Applying netplan configuration..."
sudo netplan apply

echo "✅ USB modem auto-DHCP configured!"
echo "   USB modems will now automatically get IP when plugged in"
echo "   Test: plug in modem, wait 2-3 seconds, run: ip addr show enx*"
SCRIPT

sudo chmod +x "$SETUP_SCRIPT"

# Apply netplan configuration
log_info "  Applying netplan configuration..."
sudo netplan apply || {
  log_warn "netplan apply failed, will try again on next boot"
}

# Wait a moment for changes to take effect
sleep 2

log_info "✅ USB modem auto-DHCP setup complete"
log_info "   USB modems will now automatically get IP when connected/reconnected"
log_info "   Helper script: $SETUP_SCRIPT"
