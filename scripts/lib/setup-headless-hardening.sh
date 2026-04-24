#!/usr/bin/env bash
###############################################################################
# Setup headless appliance hardening.
# Desktop-safe installs must not restart logind or change power/lid policy.
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN_PATH="${LOGIND_DROPIN_DIR}/partner-node-headless.conf"
PARTNER_NODE_HEADLESS_APPLIANCE="${PARTNER_NODE_HEADLESS_APPLIANCE:-false}"

is_true() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

disable_service_if_present() {
  local service="$1"

  if ! systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$service"; then
    return 0
  fi

  log_info "  Disabling ${service}"
  systemctl disable --now "$service" >/dev/null 2>&1 || true
}

mask_service_if_present() {
  local service="$1"

  if ! systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$service"; then
    return 0
  fi

  log_info "  Masking ${service}"
  systemctl disable --now "$service" >/dev/null 2>&1 || true
  systemctl mask "$service" >/dev/null 2>&1 || true
}

setup_headless_hardening() {
  require_root

  log_info "Applying headless appliance policy..."

  if ! is_true "${PARTNER_NODE_HEADLESS_APPLIANCE}"; then
    log_info "  Preserving desktop session; headless hardening disabled"
    if [[ -f "$LOGIND_DROPIN_PATH" ]]; then
      log_info "  Removing legacy logind drop-in: ${LOGIND_DROPIN_PATH}"
      rm -f "$LOGIND_DROPIN_PATH"
    fi
    log_info "  Not restarting systemd-logind in desktop-safe mode"
    log_info "Headless appliance policy skipped"
    return 0
  fi

  log_info "  Headless appliance mode is enabled: disabling graphical boot path"

  mkdir -p "$LOGIND_DROPIN_DIR"
  cat > "$LOGIND_DROPIN_PATH" <<'EOF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
HandleSuspendKey=ignore
HandleSuspendKeyLongPress=ignore
HandleHibernateKey=ignore
HandleHibernateKeyLongPress=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  chmod 0644 "$LOGIND_DROPIN_PATH"

  log_info "  Setting default target to multi-user.target"
  systemctl set-default multi-user.target >/dev/null 2>&1 || true

  disable_service_if_present "gdm.service"
  disable_service_if_present "gdm3.service"
  disable_service_if_present "lightdm.service"
  disable_service_if_present "sddm.service"

  mask_service_if_present "packagekit.service"
  mask_service_if_present "packagekit-offline-update.service"

  log_info "  Reloading systemd and restarting logind"
  systemctl daemon-reload
  systemctl try-restart systemd-logind.service >/dev/null 2>&1 || true

  log_info "Headless appliance hardening applied"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_headless_hardening "$@"
fi
