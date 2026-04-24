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

BINARY_URL="${BINARY_URL:-https://chatmod.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.5.22}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/partner-node}"
SERVICE_NAME="${SERVICE_NAME:-partner-node}"
UI_SERVICE_NAME="${UI_SERVICE_NAME:-partner-node-ui}"
UI_DIR="${UI_DIR:-/opt/partner-node-ui}"
UI_PORT="${UI_PORT:-}"
MAIN_SERVER="${MAIN_SERVER:-}"
PARTNER_KEY="${PARTNER_KEY:-}"
PARTNER_NODE_HEADLESS_APPLIANCE="${PARTNER_NODE_HEADLESS_APPLIANCE:-}"
PARTNER_NODE_DISABLE_SLEEP="${PARTNER_NODE_DISABLE_SLEEP:-}"
PARTNER_NODE_KEEP_SCREEN_ON="${PARTNER_NODE_KEEP_SCREEN_ON:-}"
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
  --headless-appliance <bool> Force appliance TTY-only mode and disable display manager (default: false)
  --disable-sleep <bool>      Prevent sleep/suspend/hibernate/lid sleep (default: true)
  --keep-screen-on <bool>     Prevent desktop screen blanking where supported (default: true)
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
      --headless-appliance) PARTNER_NODE_HEADLESS_APPLIANCE="${2:-}"; shift 2 ;;
      --disable-sleep) PARTNER_NODE_DISABLE_SLEEP="${2:-}"; shift 2 ;;
      --keep-screen-on) PARTNER_NODE_KEEP_SCREEN_ON="${2:-}"; shift 2 ;;
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
  local install_env_file="${CONFIG_DIR}/install.env"

  if [[ -z "${MAIN_SERVER}" ]]; then
    MAIN_SERVER="$(read_yaml_scalar "$config_file" "api" "main_server" | tr -d '\r')"
  fi
  if [[ -z "${PARTNER_KEY}" ]]; then
    PARTNER_KEY="$(read_yaml_scalar "$config_file" "api" "partner_key" | tr -d '\r')"
  fi
  if [[ -z "${UI_PORT}" ]]; then
    UI_PORT="$(read_env_scalar "$ui_env_file" "UI_PORT" | tr -d '\r')"
  fi
  if [[ -z "${PARTNER_NODE_HEADLESS_APPLIANCE}" ]]; then
    PARTNER_NODE_HEADLESS_APPLIANCE="$(read_env_scalar "$install_env_file" "PARTNER_NODE_HEADLESS_APPLIANCE" | tr -d '\r')"
  fi
  if [[ -z "${PARTNER_NODE_DISABLE_SLEEP}" ]]; then
    PARTNER_NODE_DISABLE_SLEEP="$(read_env_scalar "$install_env_file" "PARTNER_NODE_DISABLE_SLEEP" | tr -d '\r')"
  fi
  if [[ -z "${PARTNER_NODE_KEEP_SCREEN_ON}" ]]; then
    PARTNER_NODE_KEEP_SCREEN_ON="$(read_env_scalar "$install_env_file" "PARTNER_NODE_KEEP_SCREEN_ON" | tr -d '\r')"
  fi
  if [[ -z "${UI_PORT}" ]]; then
    UI_PORT="19090"
  fi
  if [[ -z "${PARTNER_NODE_HEADLESS_APPLIANCE}" ]]; then
    PARTNER_NODE_HEADLESS_APPLIANCE="false"
  fi
  if [[ -z "${PARTNER_NODE_DISABLE_SLEEP}" ]]; then
    PARTNER_NODE_DISABLE_SLEEP="true"
  fi
  if [[ -z "${PARTNER_NODE_KEEP_SCREEN_ON}" ]]; then
    PARTNER_NODE_KEEP_SCREEN_ON="true"
  fi

  if [[ -z "${MAIN_SERVER}" || -z "${PARTNER_KEY}" ]]; then
    log_err "Could not read MAIN_SERVER / PARTNER_KEY from installed config. Pass them explicitly."
    exit 1
  fi
  if [[ "${PARTNER_NODE_HEADLESS_APPLIANCE}" != "true" && "${PARTNER_NODE_HEADLESS_APPLIANCE}" != "false" ]]; then
    log_err "Invalid PARTNER_NODE_HEADLESS_APPLIANCE value: ${PARTNER_NODE_HEADLESS_APPLIANCE} (expected true or false)"
    exit 1
  fi
  if [[ "${PARTNER_NODE_DISABLE_SLEEP}" != "true" && "${PARTNER_NODE_DISABLE_SLEEP}" != "false" ]]; then
    log_err "Invalid PARTNER_NODE_DISABLE_SLEEP value: ${PARTNER_NODE_DISABLE_SLEEP} (expected true or false)"
    exit 1
  fi
  if [[ "${PARTNER_NODE_KEEP_SCREEN_ON}" != "true" && "${PARTNER_NODE_KEEP_SCREEN_ON}" != "false" ]]; then
    log_err "Invalid PARTNER_NODE_KEEP_SCREEN_ON value: ${PARTNER_NODE_KEEP_SCREEN_ON} (expected true or false)"
    exit 1
  fi
}

upsert_install_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced=0 }
      $0 ~ "^" key "=" {
        print key "=\"" value "\""
        replaced=1
        next
      }
      { print }
      END {
        if (replaced == 0) {
          print key "=\"" value "\""
        }
      }
    ' "$file" > "$tmp"
  else
    printf '%s="%s"\n' "$key" "$value" > "$tmp"
  fi

  mv "$tmp" "$file"
}

write_install_policy_env() {
  local env_file="${CONFIG_DIR}/install.env"

  mkdir -p "$CONFIG_DIR"
  touch "$env_file"
  chmod 0600 "$env_file"

  upsert_install_env_var "$env_file" "PARTNER_NODE_HEADLESS_APPLIANCE" "$PARTNER_NODE_HEADLESS_APPLIANCE"
  upsert_install_env_var "$env_file" "PARTNER_NODE_DISABLE_SLEEP" "$PARTNER_NODE_DISABLE_SLEEP"
  upsert_install_env_var "$env_file" "PARTNER_NODE_KEEP_SCREEN_ON" "$PARTNER_NODE_KEEP_SCREEN_ON"

  chmod 0600 "$env_file"
  chown root:root "$env_file" 2>/dev/null || true
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
  for script in setup-dependencies setup-power-policy setup-headless-hardening setup-node-agent setup-systemd setup-routing setup-modem-dhcp setup-flash setup-ui setup-update; do
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
  export PARTNER_NODE_HEADLESS_APPLIANCE
  export PARTNER_NODE_DISABLE_SLEEP PARTNER_NODE_KEEP_SCREEN_ON
  export MAIN_SERVER PARTNER_KEY INSTALLER_RAW_BASE_URL PARTNER_NODE_UPDATE_PATH
  export MODEM_FLASH_ENABLED="${MODEM_FLASH_ENABLED:-true}"
  export MODEM_FLASH_SCRIPT_PATH="${MODEM_FLASH_SCRIPT_PATH:-/usr/local/sbin/partner-node-provision-hilink.sh}"
  export MODEM_HILINK_FLASH_PATH="${MODEM_HILINK_FLASH_PATH:-/usr/local/sbin/partner-node-flash-hilink.sh}"
  export MODEM_NEEDLE_RECOVERY_PATH="${MODEM_NEEDLE_RECOVERY_PATH:-/usr/local/sbin/partner-node-needle-mod.sh}"
  export MODEM_SET_IP_SCRIPT_PATH="${MODEM_SET_IP_SCRIPT_PATH:-/usr/local/sbin/partner-node-set-modem-ip.sh}"
  export FLASH_ASSETS_BASE_URL="${FLASH_ASSETS_BASE_URL:-https://chatmod.warforgalaxy.com/downloads/partner-node/flash}"
  export FLASH_ASSETS_FALLBACK_BASE_URL="${FLASH_ASSETS_FALLBACK_BASE_URL:-https://raw.githubusercontent.com/CherniyPes228/moderation_chat/main/public/downloads/partner-node/flash}"

  if [[ "${WITH_DEPENDENCIES}" == "true" ]]; then
    log_info "Step 1/10: Refreshing system dependencies..."
    bash "$LIB_DIR/setup-dependencies.sh" || ((failed++))
  else
    log_info "Step 1/10: Skipping dependency refresh (use --with-dependencies to include it)"
  fi

  log_info "Step 2/10: Applying power policy..."
  bash "$LIB_DIR/setup-power-policy.sh" || ((failed++))

  log_info "Step 3/10: Applying headless appliance hardening..."
  bash "$LIB_DIR/setup-headless-hardening.sh" || ((failed++))

  log_info "Step 4/10: Updating node-agent..."
  bash "$LIB_DIR/setup-node-agent.sh" || ((failed++))

  log_info "Step 5/10: Refreshing systemd units..."
  bash "$LIB_DIR/setup-systemd.sh" || ((failed++))

  log_info "Step 6/10: Refreshing routing policy..."
  bash "$LIB_DIR/setup-routing.sh" || ((failed++))

  log_info "Step 7/10: Refreshing NetworkManager dispatcher policy..."
  bash "$LIB_DIR/setup-modem-dhcp.sh" || ((failed++))

  log_info "Step 8/10: Updating flash assets and helper scripts..."
  bash "$LIB_DIR/setup-flash.sh" || ((failed++))

  log_info "Step 9/10: Updating local partner UI..."
  bash "$LIB_DIR/setup-ui.sh" || ((failed++))

  log_info "Step 10/10: Refreshing local update helper..."
  bash "$LIB_DIR/setup-update.sh" || ((failed++))

  log_info "Recording install power policy preferences..."
  write_install_policy_env

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
