#!/usr/bin/env bash
###############################################################################
# Setup systemd units for node-agent and 3proxy
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/partner-node}"
DATA_DIR="${DATA_DIR:-/var/lib/partner-node}"
LOG_DIR="${LOG_DIR:-/var/log/partner-node}"
SERVICE_NAME="${SERVICE_NAME:-partner-node}"

setup_systemd() {
  require_root

  log_info "Setting up systemd units..."

  mkdir -p /etc/systemd/system "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" /etc/3proxy /var/log/3proxy

  # Keep a wrapper for compatibility, but do not mutate networking on service start.
  log_info "Creating node-agent wrapper script"
  cat > $INSTALL_PREFIX/node-agent-wrapper.sh <<WRAPPER
#!/bin/bash
exec /usr/local/bin/node-agent "\$@"
WRAPPER

  chmod +x $INSTALL_PREFIX/node-agent-wrapper.sh

  # Create node-agent service
  log_info "Creating $SERVICE_NAME.service"
  cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=Partner Node Agent
Documentation=https://github.com/CherniyPes228/partner-node
After=network-online.target partner-node-network-reconcile.service
Wants=network-online.target partner-node-network-reconcile.service

[Service]
Type=simple
User=root
ExecStart=$INSTALL_PREFIX/node-agent-wrapper.sh -config $CONFIG_DIR/config.yaml
Restart=always
RestartSec=5
TimeoutStopSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=partner-node

# Security and resource limits
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ReadWritePaths=$CONFIG_DIR $DATA_DIR $LOG_DIR /etc/3proxy /var/log/3proxy /etc/amneziawg
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
