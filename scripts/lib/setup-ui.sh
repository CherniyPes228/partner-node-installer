#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Install local partner UI assets. The runtime HTTP server is now node-agent.
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

UI_DIR="${UI_DIR:-/opt/partner-node-ui}"
UI_SERVICE_NAME="${UI_SERVICE_NAME:-partner-node-ui}"
UI_PORT="${UI_PORT:-19090}"
MAIN_SERVER="${MAIN_SERVER:-}"
PARTNER_KEY="${PARTNER_KEY:-}"
UI_ASSET_BASE="${UI_ASSET_BASE:-https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/ui-dist}"
PARTNER_NODE_UPDATE_PATH="${PARTNER_NODE_UPDATE_PATH:-/usr/local/sbin/partner-node-update.sh}"
PARTNER_NODE_UPDATE_LOG="${PARTNER_NODE_UPDATE_LOG:-/var/log/partner-node/update.log}"
PARTNER_NODE_UPDATE_URL="${PARTNER_NODE_UPDATE_URL:-https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/update.sh}"

if [[ -z "${MAIN_SERVER}" || -z "${PARTNER_KEY}" ]]; then
  log_err "MAIN_SERVER and PARTNER_KEY must be set"
  exit 1
fi

require_root

mkdir -p "${UI_DIR}/assets"

log_info "Downloading partner UI assets for node-agent local console..."
curl -fsSL "${UI_ASSET_BASE}/index.html" -o "${UI_DIR}/index.html"
curl -fsSL "${UI_ASSET_BASE}/assets/partner-node-ui.js" -o "${UI_DIR}/assets/partner-node-ui.js"
curl -fsSL "${UI_ASSET_BASE}/assets/partner-node-ui.css" -o "${UI_DIR}/assets/partner-node-ui.css"

cat > "${UI_DIR}/ui.env" <<EOF
MAIN_SERVER="${MAIN_SERVER}"
PARTNER_KEY="${PARTNER_KEY}"
UI_LISTEN_ADDR="127.0.0.1"
UI_PORT="${UI_PORT}"
PARTNER_NODE_UPDATE_PATH="${PARTNER_NODE_UPDATE_PATH}"
PARTNER_NODE_UPDATE_LOG="${PARTNER_NODE_UPDATE_LOG}"
PARTNER_NODE_UPDATE_URL="${PARTNER_NODE_UPDATE_URL}"
EOF

chmod 0755 "${UI_DIR}"
chmod 0644 "${UI_DIR}/index.html"
chmod 0644 "${UI_DIR}/assets/partner-node-ui.js"
chmod 0644 "${UI_DIR}/assets/partner-node-ui.css"
chmod 0600 "${UI_DIR}/ui.env"

log_info "Disabling legacy Python partner UI service; node-agent serves http://127.0.0.1:${UI_PORT}"
systemctl stop "${UI_SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl disable "${UI_SERVICE_NAME}" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/${UI_SERVICE_NAME}.service"
systemctl daemon-reload
systemctl reset-failed "${UI_SERVICE_NAME}" >/dev/null 2>&1 || true

log_info "Partner UI assets installed. Runtime: partner-node.service / node-agent local_ui"
