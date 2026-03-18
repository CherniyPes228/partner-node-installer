#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Partner Node Zero-Touch Installer (v2 - Modular)
# Main orchestrator that calls individual setup scripts
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Source common utilities
source "$LIB_DIR/common.sh"

# Configuration variables
PARTNER_KEY=""
MAIN_SERVER=""
COUNTRY="${COUNTRY:-}"
BINARY_URL="https://chatmod.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.2.2"
INSTALL_PREFIX="/usr/local/bin"
CONFIG_DIR="/etc/partner-node"
DATA_DIR="/var/lib/partner-node"
LOG_DIR="/var/log/partner-node"
SERVICE_NAME="partner-node"
HILINK_ENABLED="true"
HILINK_BASE_URL="http://192.168.13.1"
HILINK_TIMEOUT="15s"
THREEPROXY_PACKAGE_URL="https://chatmod-test.warforgalaxy.com/downloads/partner-node/3proxy.deb"

# Export for use in sub-scripts
export PARTNER_KEY MAIN_SERVER COUNTRY BINARY_URL INSTALL_PREFIX
export CONFIG_DIR DATA_DIR LOG_DIR SERVICE_NAME
export HILINK_ENABLED HILINK_BASE_URL HILINK_TIMEOUT
export THREEPROXY_PACKAGE_URL

usage() {
  cat <<EOF
Partner Node Zero-Touch Installer (Modular Version)

Usage: $0 [OPTIONS]

Required:
  --partner-key <key>         Partner authentication key
  --main-server <url>         MAIN server URL (e.g., https://main.example.com)

Optional:
  --country <code>            Country code for node (default: auto-detect)
  --binary-url <url>          Custom node-agent binary URL
  --install-prefix <dir>      Installation directory (default: /usr/local/bin)
  --help                       Show this help message

Examples:
  $0 --partner-key abc123 --main-server https://main.example.com
  curl -fsSL https://example.com/install.sh | sudo bash -s -- --partner-key abc123 --main-server https://main.example.com

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --partner-key) PARTNER_KEY="${2:-}"; shift 2 ;;
      --main-server) MAIN_SERVER="${2:-}"; shift 2 ;;
      --country) COUNTRY="${2:-}"; shift 2 ;;
      --binary-url) BINARY_URL="${2:-}"; shift 2 ;;
      --install-prefix) INSTALL_PREFIX="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *)
        log_err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  log_info "╔════════════════════════════════════════════════════════════╗"
  log_info "║     Partner Node Zero-Touch Installer (v2 - Modular)      ║"
  log_info "╚════════════════════════════════════════════════════════════╝"

  require_root
  parse_args "$@"

  # Validate required arguments
  if [[ -z "$PARTNER_KEY" ]]; then
    log_err "Missing required: --partner-key"
    usage
    exit 1
  fi

  if [[ -z "$MAIN_SERVER" ]]; then
    log_err "Missing required: --main-server"
    usage
    exit 1
  fi

  log_info "Configuration:"
  log_info "  Partner Key: ${PARTNER_KEY:0:10}..."
  log_info "  MAIN Server: $MAIN_SERVER"
  log_info "  Binary URL: $BINARY_URL"
  log_info ""

  # Run setup scripts in sequence
  local failed=0

  log_info "Step 1/6: Installing system dependencies..."
  bash "$LIB_DIR/setup-dependencies.sh" || ((failed++))

  log_info "Step 2/6: Setting up 3proxy..."
  bash "$LIB_DIR/setup-3proxy.sh" || ((failed++))

  log_info "Step 3/6: Downloading node-agent..."
  bash "$LIB_DIR/setup-node-agent.sh" || ((failed++))

  log_info "Step 4/6: Creating configuration..."
  bash "$LIB_DIR/setup-config.sh" || ((failed++))

  log_info "Step 5/6: Setting up systemd units..."
  bash "$LIB_DIR/setup-systemd.sh" || ((failed++))

  log_info "Step 6/6: Configuring routing (WiFi primary, modem for proxy)..."
  bash "$LIB_DIR/setup-routing.sh" || ((failed++))

  if [[ $failed -gt 0 ]]; then
    log_warn "⚠️  $failed step(s) failed, but continuing..."
  fi

  # Start service
  log_info ""
  log_info "Starting partner-node service..."
  systemctl start $SERVICE_NAME || {
    log_warn "Failed to start service immediately, will start on next boot"
  }

  # Show status
  log_info ""
  log_info "╔════════════════════════════════════════════════════════════╗"
  log_info "║                   Installation Complete! ✅               ║"
  log_info "╚════════════════════════════════════════════════════════════╝"
  log_info ""
  log_info "Service: $SERVICE_NAME"
  log_info "Status: $(systemctl is-active $SERVICE_NAME || echo 'inactive')"
  log_info "Config: $CONFIG_DIR/config.yaml"
  log_info "Logs: journalctl -u $SERVICE_NAME -f"
  log_info ""
  log_info "Next steps:"
  log_info "  1. Monitor service: systemctl status $SERVICE_NAME"
  log_info "  2. View logs: journalctl -u $SERVICE_NAME -f"
  log_info "  3. Check node on MAIN server"
  log_info ""
}

# Run main
main "$@"
