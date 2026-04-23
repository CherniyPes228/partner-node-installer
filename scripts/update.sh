#!/usr/bin/env bash

###############################################################################
# Partner Node In-Place Update
# Updates runtime components without full reinstall or config reset
###############################################################################

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -n "${0:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
else
  SCRIPT_DIR="."
fi

set -euo pipefail

LIB_DIR="/tmp/partner-node-update-lib-$$"
mkdir -p "$LIB_DIR"

curl -fsSL https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/lib/common.sh -o "$LIB_DIR/common.sh" 2>/dev/null || {
  echo "❌ Failed to download common.sh - check internet connection"
  exit 1
}

source "$LIB_DIR/common.sh"

BINARY_URL="${BINARY_URL:-https://chatmod.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.5.16}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/partner-node}"
SERVICE_NAME="${SERVICE_NAME:-partner-node}"
UI_SERVICE_NAME="${UI_SERVICE_NAME:-partner-node-ui}"
UI_DIR="${UI_DIR:-/opt/partner-node-ui}"
UI_PORT="${UI_PORT:-}"
MAIN_SERVER="${MAIN_SERVER:-}"
PARTNER_KEY="${PARTNER_KEY:-}"
PARTNER_NODE_UPDATE_PATH="${PARTNER_NODE_UPDATE_PATH:-/usr/local/sbin/partner-node-update.sh}"
INSTALLER_RAW_BASE_URL="${INSTALLER_RAW_BASE_URL:-https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main}"
WITH_DEPENDENCIES="false"

usage() {
  cat <<EOF
Partner Node In-Place Update

Usage: $0 [OPTIONS]

Optional:
  --binary-url <url>          Custom node-agent binary URL
  --main-server <url>         Override MAIN server from installed config
  --partner-key <key>         Override partner key from installed config
  --ui-port <port>            Override local UI port (default: from installed ui.env or 19090)
  --with-dependencies         Also refresh system dependencies
  --help, -h                  Show this help message

Examples:
  $0
  curl -fsSL https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/update.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/update.sh | sudo bash -s -- --binary-url https://example.com/node-agent
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binary-url) BINARY_URL="${2:-}"; shift 2 ;;
      --main-server) MAIN_SERVER="${2:-}"; shift 2 ;;
      --partner-key) PARTNER_KEY="${2:-}"; shift 2 ;;
      --ui-port) UI_PORT="${2:-}"; shift 2 ;;
      --with-dependencies) WITH_DEPENDENCIES="true"; shift ;;
      --help|-h) usage; exit 0 ;;
      *)
        log_err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

read_yaml_scalar() {
  local file="$1"
  local section="$2"
  local key="$3"
  [[ -f "$file" ]] || return 0
  awk -v section="$section" -v key="$key" '
    $0 ~ "^" section ":" { in_section=1; next }
    in_section && $0 ~ "^[^[:space:]]" { in_section=0 }
    in_section && $0 ~ "^[[:space:]]+" key ":" {
      line=$0
      sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "", line)
      gsub(/^[\"\047]/, "", line)
      gsub(/[\"\047][[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$file"
}

read_env_scalar() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=\\\"\\{0,1\\}\\([^\\\"#]*\\)\\\"\\{0,1\\}$/\\1/p" "$file" | head -n 1
}

load_existing_install_context() {
  local config_file="${CONFIG_DIR}/config.yaml"
  local ui_env_file="${UI_DIR}/ui.env"

  if [[ -z "${MAIN_SERVER}" ]]; then
    MAIN_SERVER="$(read_yaml_scalar "$config_file" "api" "main_server" | tr -d '\r')"
  fi
  if [[ -z "${PARTNER_KEY}" ]]; then
    PARTNER_KEY="$(read_yaml_scalar "$config_file" "api" "partner_key" | tr -d '\r')"
  fi
  if [[ -z "${UI_PORT}" ]]; then
    UI_PORT="$(read_env_scalar "$ui_env_file" "UI_PORT" | tr -d '\r')"
  fi
  if [[ -z "${UI_PORT}" ]]; then
    UI_PORT="19090"
  fi

  if [[ -z "${MAIN_SERVER}" || -z "${PARTNER_KEY}" ]]; then
    log_err "Could not read MAIN_SERVER / PARTNER_KEY from installed config. Pass them explicitly."
    exit 1
  fi
}

main() {
  require_root
  parse_args "$@"
  load_existing_install_context

  log_info "╔════════════════════════════════════════════════════════════╗"
  log_info "║                Partner Node In-Place Update               ║"
  log_info "╚════════════════════════════════════════════════════════════╝"
  log_info "MAIN Server: $MAIN_SERVER"
  log_info "Binary URL: $BINARY_URL"
  log_info "UI Port: $UI_PORT"

  local failed=0

  log_info "Downloading update helpers..."
  for script in setup-dependencies setup-node-agent setup-systemd setup-routing setup-modem-dhcp setup-flash setup-ui setup-update; do
    download_file "${INSTALLER_RAW_BASE_URL}/scripts/lib/${script}.sh" "${LIB_DIR}/${script}.sh" || {
      log_err "Failed to download ${script}.sh"
      ((failed++))
    }
  done

  if [[ $failed -gt 0 ]]; then
    log_err "Failed to download some update helpers"
    exit 1
  fi

  export BINARY_URL INSTALL_PREFIX CONFIG_DIR SERVICE_NAME UI_SERVICE_NAME UI_DIR UI_PORT
  export MAIN_SERVER PARTNER_KEY INSTALLER_RAW_BASE_URL PARTNER_NODE_UPDATE_PATH
  export MODEM_FLASH_ENABLED="${MODEM_FLASH_ENABLED:-true}"
  export MODEM_FLASH_SCRIPT_PATH="${MODEM_FLASH_SCRIPT_PATH:-/usr/local/sbin/partner-node-provision-hilink.sh}"
  export MODEM_HILINK_FLASH_PATH="${MODEM_HILINK_FLASH_PATH:-/usr/local/sbin/partner-node-flash-hilink.sh}"
  export MODEM_NEEDLE_RECOVERY_PATH="${MODEM_NEEDLE_RECOVERY_PATH:-/usr/local/sbin/partner-node-needle-mod.sh}"
  export MODEM_SET_IP_SCRIPT_PATH="${MODEM_SET_IP_SCRIPT_PATH:-/usr/local/sbin/partner-node-set-modem-ip.sh}"
  export FLASH_ASSETS_BASE_URL="${FLASH_ASSETS_BASE_URL:-https://chatmod.warforgalaxy.com/downloads/partner-node/flash}"
  export FLASH_ASSETS_FALLBACK_BASE_URL="${FLASH_ASSETS_FALLBACK_BASE_URL:-https://raw.githubusercontent.com/CherniyPes228/moderation_chat/main/public/downloads/partner-node/flash}"

  if [[ "${WITH_DEPENDENCIES}" == "true" ]]; then
    log_info "Step 1/8: Refreshing system dependencies..."
    bash "$LIB_DIR/setup-dependencies.sh" || ((failed++))
  else
    log_info "Step 1/8: Skipping dependency refresh (use --with-dependencies to include it)"
  fi

  log_info "Step 2/8: Updating node-agent..."
  bash "$LIB_DIR/setup-node-agent.sh" || ((failed++))

  log_info "Step 3/8: Refreshing systemd units..."
  bash "$LIB_DIR/setup-systemd.sh" || ((failed++))

  log_info "Step 4/8: Refreshing routing enforcement..."
  bash "$LIB_DIR/setup-routing.sh" || ((failed++))

  log_info "Step 5/8: Refreshing USB modem routing policy..."
  bash "$LIB_DIR/setup-modem-dhcp.sh" || ((failed++))

  log_info "Step 6/8: Updating flash assets and helper scripts..."
  bash "$LIB_DIR/setup-flash.sh" || ((failed++))

  log_info "Step 7/8: Updating local partner UI..."
  bash "$LIB_DIR/setup-ui.sh" || ((failed++))

  log_info "Step 8/8: Refreshing local update helper..."
  bash "$LIB_DIR/setup-update.sh" || ((failed++))

  log_info "Restarting services..."
  systemctl restart "$SERVICE_NAME" || log_warn "Failed to restart $SERVICE_NAME"
  systemctl restart "$UI_SERVICE_NAME" || log_warn "Failed to restart $UI_SERVICE_NAME"

  if [[ $failed -gt 0 ]]; then
    log_warn "⚠️  $failed step(s) failed during update"
  else
    log_info "✅ In-place update complete"
  fi

  log_info "Agent status: $(systemctl is-active "$SERVICE_NAME" || echo 'inactive')"
  log_info "UI status: $(systemctl is-active "$UI_SERVICE_NAME" || echo 'inactive')"
  log_info "Update command: ${PARTNER_NODE_UPDATE_PATH}"

  rm -rf "$LIB_DIR"
}

main "$@"
