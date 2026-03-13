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
ExecStart=$INSTALL_PREFIX/node-agent -config $CONFIG_DIR/config.yaml
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
