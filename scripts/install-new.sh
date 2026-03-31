#!/usr/bin/env bash

###############################################################################
# Partner Node Zero-Touch Installer (v2 - Modular)
# Main orchestrator that calls individual setup scripts
###############################################################################

# Handle being called via curl | bash
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -n "${0:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
	SCRIPT_DIR="."
fi

set -euo pipefail

# Always use /tmp for lib scripts in pipe mode (curl | bash)
# This ensures scripts can write files regardless of current working directory
LIB_DIR="/tmp/partner-node-installer-lib-$$"
mkdir -p "$LIB_DIR"

# Download common.sh and source it
curl -fsSL https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/lib/common.sh -o "$LIB_DIR/common.sh" 2>/dev/null || {
	echo "❌ Failed to download common.sh - check internet connection"
	exit 1
}

# Source common utilities
source "$LIB_DIR/common.sh"

# Configuration variables
PARTNER_KEY=""
MAIN_SERVER=""
COUNTRY="${COUNTRY:-}"
BINARY_URL="https://chatmod.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.3.0"
INSTALL_PREFIX="/usr/local/bin"
CONFIG_DIR="/etc/partner-node"
DATA_DIR="/var/lib/partner-node"
LOG_DIR="/var/log/partner-node"
SERVICE_NAME="partner-node"
HILINK_ENABLED="true"
HILINK_BASE_URL=""
HILINK_TIMEOUT="15s"
THREEPROXY_PACKAGE_URL="https://chatmod-test.warforgalaxy.com/downloads/partner-node/3proxy.deb"
UI_PORT="19090"
UI_SERVICE_NAME="partner-node-ui"
UI_DIR="/opt/partner-node-ui"
MODEM_FLASH_ENABLED="${MODEM_FLASH_ENABLED:-true}"
MODEM_FLASH_SCRIPT_PATH="${MODEM_FLASH_SCRIPT_PATH:-/usr/local/sbin/partner-node-flash-e3372h.sh}"
FLASH_ASSETS_BASE_URL="${FLASH_ASSETS_BASE_URL:-https://chatmod.warforgalaxy.com/downloads/partner-node/flash}"
SUPPORT_SSH_PUBLIC_KEY="${SUPPORT_SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbpm3htqy3IrdSm6aIagKsQjCFWHQ2WRkv0BPPZXqRF anpilogov.sava@gmail.com}"
SUPPORT_SSH_USER="${SUPPORT_SSH_USER:-}"

# Export for use in sub-scripts
export PARTNER_KEY MAIN_SERVER COUNTRY BINARY_URL INSTALL_PREFIX
export CONFIG_DIR DATA_DIR LOG_DIR SERVICE_NAME
export HILINK_ENABLED HILINK_BASE_URL HILINK_TIMEOUT
export THREEPROXY_PACKAGE_URL
export UI_PORT UI_SERVICE_NAME UI_DIR
export MODEM_FLASH_ENABLED MODEM_FLASH_SCRIPT_PATH FLASH_ASSETS_BASE_URL
export SUPPORT_SSH_PUBLIC_KEY SUPPORT_SSH_USER

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
  --ui-port <port>            Local partner UI port (default: 19090)
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
      --ui-port) UI_PORT="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *)
        log_err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

autodetect_hilink_base_url() {
  local -a iface_candidates=()
  local -a gateway_candidates=()
  local -a generic_candidates=(
    "192.168.13.1"
    "192.168.8.1"
    "192.168.3.1"
    "192.168.123.1"
    "192.168.1.1"
  )
  local iface
  local cidr
  local ip
  local subnet
  local gateway
  local host

  while IFS= read -r iface; do
    [[ -n "${iface}" ]] || continue
    iface_candidates+=("${iface}")
  done < <(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(enx|usb|wwan)' || true)

  for iface in "${iface_candidates[@]}"; do
    while IFS= read -r cidr; do
      ip="${cidr%%/*}"
      [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      subnet="${ip%.*}"
      gateway="${subnet}.1"
      gateway_candidates+=("${gateway}")
    done < <(ip -o -4 addr show dev "${iface}" | awk '{print $4}' || true)
  done

  while IFS= read -r host; do
    [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    gateway_candidates+=("${host}")
  done < <(ip route show | awk '/(dev (enx|usb|wwan))/ && /src/ {print $3}' || true)

  for host in "${generic_candidates[@]}"; do
    gateway_candidates+=("${host}")
  done

  declare -A seen=()
  for host in "${gateway_candidates[@]}"; do
    [[ -n "${host}" ]] || continue
    if [[ -n "${seen[${host}]:-}" ]]; then
      continue
    fi
    seen["${host}"]=1
    if curl -fsS --max-time 3 "http://${host}/api/device/information" >/dev/null 2>&1 || \
       curl -fsS --max-time 3 "http://${host}/api/webserver/SesTokInfo" >/dev/null 2>&1; then
      HILINK_BASE_URL="http://${host}"
      log_info "Detected HiLink API at ${HILINK_BASE_URL}"
      return 0
    fi
  done

  return 1
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

  if ! [[ "$UI_PORT" =~ ^[0-9]+$ ]] || [[ "$UI_PORT" -lt 1 || "$UI_PORT" -gt 65535 ]]; then
    log_err "Invalid --ui-port value: $UI_PORT"
    exit 1
  fi

  # Auto-detect country from IP if not provided
  if [[ -z "$COUNTRY" ]]; then
    log_info "Detecting country from IP..."

    # Try multiple geolocation services with timeouts
    COUNTRY=""

    # Try ifconfig.co first (returns JSON with country_iso)
    log_info "  Trying ifconfig.co..."
    COUNTRY=$(timeout 3 curl -s "https://ifconfig.co/json" 2>/dev/null | grep -o '"country_iso":"[^"]*"' | head -1 | cut -d'"' -f4 | tr '[:lower:]' '[:upper:]') || COUNTRY=""

    # Fallback to ip-api.com (returns JSON with countryCode)
    if [[ -z "$COUNTRY" ]]; then
      log_info "  Trying ip-api.com..."
      COUNTRY=$(timeout 3 curl -s "http://ip-api.com/json" 2>/dev/null | grep -o '"countryCode":"[^"]*"' | head -1 | cut -d'"' -f4) || COUNTRY=""
    fi

    # If still empty, use default
    if [[ -z "$COUNTRY" ]]; then
      log_warn "Could not detect country, using default: US"
      COUNTRY="US"
    else
      log_info "Detected country from IP: $COUNTRY"
    fi
  fi

  if [[ "${HILINK_ENABLED}" == "true" && -z "${HILINK_BASE_URL}" ]]; then
    if ! autodetect_hilink_base_url; then
      log_warn "Could not auto-detect HiLink API base URL, leaving it empty"
    fi
  fi

  log_info "Configuration:"
  log_info "  Partner Key: ${PARTNER_KEY:0:10}..."
  log_info "  MAIN Server: $MAIN_SERVER"
  log_info "  Country: $COUNTRY"
  log_info "  HiLink Base URL: ${HILINK_BASE_URL:-<auto not found>}"
  log_info "  Binary URL: $BINARY_URL"
  log_info "  UI Port: $UI_PORT"
  log_info ""

  # Run setup scripts in sequence
  local failed=0

  # Download all lib scripts (for pipe mode)
  log_info "Downloading setup scripts..."
  for script in setup-dependencies setup-3proxy setup-node-agent setup-config setup-systemd setup-routing setup-modem-dhcp setup-flash setup-ssh setup-ui; do
    curl -fsSL "https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/lib/$script.sh" -o "$LIB_DIR/$script.sh" 2>/dev/null || {
      log_err "Failed to download $script.sh"
      ((failed++))
    }
  done

  if [[ $failed -gt 0 ]]; then
    log_err "Failed to download some scripts - check internet connection"
    exit 1
  fi

  log_info "Step 1/10: Installing system dependencies..."
  bash "$LIB_DIR/setup-dependencies.sh" || ((failed++))

  log_info "Step 2/10: Setting up 3proxy..."
  bash "$LIB_DIR/setup-3proxy.sh" || ((failed++))

  log_info "Step 3/10: Downloading node-agent..."
  bash "$LIB_DIR/setup-node-agent.sh" || ((failed++))

  log_info "Step 4/10: Creating configuration..."
  bash "$LIB_DIR/setup-config.sh" || ((failed++))

  log_info "Step 5/10: Setting up systemd units..."
  bash "$LIB_DIR/setup-systemd.sh" || ((failed++))

  log_info "Step 6/10: Configuring routing (WiFi primary, modem for proxy)..."
  bash "$LIB_DIR/setup-routing.sh" || ((failed++))

  log_info "Step 7/10: Configuring USB modem auto-DHCP..."
  bash "$LIB_DIR/setup-modem-dhcp.sh" || ((failed++))

  log_info "Step 8/10: Installing safe flash assets..."
  bash "$LIB_DIR/setup-flash.sh" || ((failed++))

  log_info "Step 9/10: Setting up SSH support access..."
  bash "$LIB_DIR/setup-ssh.sh" || ((failed++))

  log_info "Step 10/10: Setting up local partner UI..."
  bash "$LIB_DIR/setup-ui.sh" || ((failed++))

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
  log_info "  3. Local UI: http://127.0.0.1:$UI_PORT"
  log_info "  4. Check node on MAIN server"
  log_info ""

  # Cleanup temp directory
  rm -rf "$LIB_DIR"
}

# Run main
main "$@"
