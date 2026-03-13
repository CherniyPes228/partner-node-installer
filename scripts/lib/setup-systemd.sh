#!/usr/bin/env bash
###############################################################################
# Setup systemd units for node-agent and 3proxy
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/partner-node}"
LOG_DIR="${LOG_DIR:-/var/log/partner-node}"
SERVICE_NAME="${SERVICE_NAME:-partner-node}"

setup_systemd() {
  require_root

  log_info "Setting up systemd units..."

  mkdir -p /etc/systemd/system

  # Create wrapper script for node-agent (ensures WiFi is default route)
  log_info "Creating node-agent wrapper script (for routing fix)"
  cat > $INSTALL_PREFIX/node-agent-wrapper.sh <<'WRAPPER'
#!/bin/bash
# Pre-startup hook for node-agent
# Ensures WiFi is default route, not modem

# Remove all default routes from modem interfaces (enx*)
ip route show 2>/dev/null | grep "^default" | grep "enx" | while read route; do
  ip route del $route 2>/dev/null || true
done

# Ensure a WiFi/Ethernet default route exists
if ! ip route show 2>/dev/null | grep -q "^default"; then
  # Find the primary Ethernet/WiFi interface
  local primary_iface=$(ip route show | grep "^[0-9]" | head -1 | awk '{print $NF}')
  if [[ -n "$primary_iface" ]]; then
    ip route add default via 192.168.0.1 dev "$primary_iface" 2>/dev/null || true
  fi
fi

# Now start the actual node-agent
exec $INSTALL_PREFIX/node-agent "$@"
WRAPPER

  chmod +x $INSTALL_PREFIX/node-agent-wrapper.sh

  # Create node-agent service
  log_info "Creating $SERVICE_NAME.service"
  cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=Partner Node Agent
Documentation=https://github.com/CherniyPes228/partner-node
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$INSTALL_PREFIX/node-agent-wrapper.sh -config $CONFIG_DIR/config.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=partner-node

# Security and resource limits
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
LimitNOFILE=65536
LimitNPROC=512

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 /etc/systemd/system/$SERVICE_NAME.service

  # Reload systemd
  log_info "Reloading systemd daemon..."
  systemctl daemon-reload

  # Enable service (but don't start yet)
  log_info "Enabling $SERVICE_NAME.service"
  systemctl enable $SERVICE_NAME.service

  log_info "✅ Systemd units setup complete"
  log_info "Service will be started after configuration"
}

# Run if sourced directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_systemd "$@"
fi
