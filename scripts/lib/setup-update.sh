#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Install local partner-node update helper
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTALLER_RAW_BASE_URL="${INSTALLER_RAW_BASE_URL:-https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main}"
PARTNER_NODE_UPDATE_PATH="${PARTNER_NODE_UPDATE_PATH:-/usr/local/sbin/partner-node-update.sh}"

setup_update_script() {
  require_root

  mkdir -p "$(dirname "${PARTNER_NODE_UPDATE_PATH}")"
  log_info "Installing local update helper to ${PARTNER_NODE_UPDATE_PATH}"
  download_file "${INSTALLER_RAW_BASE_URL}/scripts/update.sh" "${PARTNER_NODE_UPDATE_PATH}"
  chmod 0755 "${PARTNER_NODE_UPDATE_PATH}"
  chown root:root "${PARTNER_NODE_UPDATE_PATH}"
  log_info "✅ Update helper installed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_update_script "$@"
fi
