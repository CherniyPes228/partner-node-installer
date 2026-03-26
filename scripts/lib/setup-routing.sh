#!/usr/bin/env bash
###############################################################################
# Setup routing: WiFi primary, modem for proxy only
# Creates persistent cron job to enforce routing
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

setup_routing() {
  require_root

  log_info "Setting up routing: system via WiFi/Ethernet, proxy via modem"

  # Find modem interfaces (USB modems typically have enx* names)
  local modem_interfaces
  modem_interfaces=$(ip link 2>/dev/null | grep "enx" | awk '{print $2}' | sed 's/:$//' || true)

  if [[ -z "$modem_interfaces" ]]; then
    log_warn "No modem interfaces (enx*) detected. Routing setup skipped."
    return 0
  fi

  log_info "Found modem interface(s): $modem_interfaces"

  # Remove all current default routes from modems
  for iface in $modem_interfaces; do
    log_info "Removing default route from modem interface: $iface"
    while IFS= read -r route; do
      [[ -z "$route" ]] && continue
      ip route del $route 2>/dev/null || true
    done < <(ip route show 2>/dev/null | grep "^default" | grep "$iface" || true)
  done

  # Create enforcement script (runs via cron every minute)
  log_info "Creating routing enforcement script"
  mkdir -p /usr/local/bin

  cat > /usr/local/bin/enforce-wifi-routing.sh <<'ENFORCEMENT_SCRIPT'
#!/bin/bash
# Enforce WiFi as default route (not modem)
# This script runs every minute via cron to prevent DHCP from adding modem routes

# Remove any default routes from modem interfaces (enx*)
if ip route show 2>/dev/null | grep -q 'default via.*enx'; then
  ip route show 2>/dev/null | grep 'default via.*enx' | while read route; do
    ip route del $route 2>/dev/null || true
  done
  echo "[$(date)] Removed modem default route" >> /var/log/modem-routing.log 2>&1 || true
fi

# Ensure at least one WiFi/Ethernet default route exists
if ! ip route show 2>/dev/null | grep -q 'default via'; then
  # Try to add WiFi default route (192.168.0.1 is common gateway)
  ip route add default via 192.168.0.1 2>/dev/null || true
fi

# Build source-based routing for modem-side IPs so 3proxy traffic bound to
# the local HiLink address leaves through the modem instead of WiFi.
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep '^enx' || true); do
  local_ip=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | head -n 1 | cut -d/ -f1)
  [ -z "$local_ip" ] && continue

  prefix=$(echo "$local_ip" | awk -F. '{print $1 "." $2 "." $3}')
  gateway="${prefix}.1"
  table_id=$(echo "$iface" | cksum | awk '{print 1000 + ($1 % 200)}')

  ip rule del from "${local_ip}/32" table "$table_id" 2>/dev/null || true
  ip route flush table "$table_id" 2>/dev/null || true

  ip route add "${prefix}.0/24" dev "$iface" src "$local_ip" table "$table_id" 2>/dev/null || true
  ip route add default via "$gateway" dev "$iface" table "$table_id" 2>/dev/null || true
  ip rule add from "${local_ip}/32" table "$table_id" priority "$table_id" 2>/dev/null || true
done
ENFORCEMENT_SCRIPT

  chmod +x /usr/local/bin/enforce-wifi-routing.sh
  log_info "Created /usr/local/bin/enforce-wifi-routing.sh"

  # Add to root crontab to run every minute
  log_info "Adding cron job (runs every minute)"
  local cron_entry="* * * * * /usr/local/bin/enforce-wifi-routing.sh"

  # Get current crontab or create empty
  local current_cron
  current_cron=$(crontab -l 2>/dev/null || echo "")

  # Check if entry already exists
  if ! echo "$current_cron" | grep -q "enforce-wifi-routing"; then
    # Add new entry
    (echo "$current_cron"; echo "$cron_entry") | crontab -
    log_info "Cron job installed"
  else
    log_info "Cron job already installed"
  fi

  # Apply modem source-routing immediately; cron then keeps it in sync.
  /usr/local/bin/enforce-wifi-routing.sh || true

  # Verify routing state
  log_info "Current routing configuration:"
  ip route show | grep "^default" || log_warn "No default route found!"

  log_info "✅ Routing setup complete"
  log_info "WiFi is now the primary default route"
  log_info "Modem will only be used for 3proxy proxy traffic"
  log_info "Enforcement runs every minute via cron"
}

# Run if sourced directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_routing "$@"
fi
