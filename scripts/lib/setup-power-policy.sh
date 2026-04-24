#!/usr/bin/env bash
###############################################################################
# Setup partner-node power policy.
# Keeps appliance nodes awake without restarting logind or breaking GUI sessions.
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CONFIG_DIR="${CONFIG_DIR:-/etc/partner-node}"
PARTNER_NODE_DISABLE_SLEEP="${PARTNER_NODE_DISABLE_SLEEP:-true}"
PARTNER_NODE_KEEP_SCREEN_ON="${PARTNER_NODE_KEEP_SCREEN_ON:-true}"
SUPPORT_SSH_USER="${SUPPORT_SSH_USER:-}"

LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_POWER_DROPIN_PATH="${LOGIND_DROPIN_DIR}/partner-node-power.conf"
POWER_POLICY_MARKER_PATH="${CONFIG_DIR}/power-policy-managed"
SCREEN_BLANK_SCRIPT_PATH="/usr/local/bin/partner-node-no-screen-blank"
SCREEN_BLANK_AUTOSTART_PATH="/etc/xdg/autostart/partner-node-no-screen-blank.desktop"
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)

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

detect_desktop_user() {
  local candidate=""

  if [[ -n "${SUPPORT_SSH_USER}" ]] && id -u "${SUPPORT_SSH_USER}" >/dev/null 2>&1; then
    echo "${SUPPORT_SSH_USER}"
    return 0
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
    echo "${SUDO_USER}"
    return 0
  fi

  if command_exists loginctl; then
    candidate="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 ~ /^seat/ { print $3; exit }')"
    if [[ -n "${candidate}" ]] && id -u "${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  fi

  candidate="$(logname 2>/dev/null || true)"
  if [[ -n "${candidate}" ]] && id -u "${candidate}" >/dev/null 2>&1; then
    echo "${candidate}"
    return 0
  fi

  return 1
}

run_as_user() {
  local user="$1"
  shift

  local uid
  uid="$(id -u "${user}")"

  local -a env_args=(
    "HOME=$(getent passwd "${user}" | cut -d: -f6)"
    "XDG_RUNTIME_DIR=/run/user/${uid}"
  )

  if [[ -S "/run/user/${uid}/bus" ]]; then
    env_args+=("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus")
  fi

  if command_exists runuser; then
    runuser -u "${user}" -- env "${env_args[@]}" "$@"
  elif command_exists sudo; then
    sudo -H -u "${user}" env "${env_args[@]}" "$@"
  else
    su -s /bin/bash "${user}" -c "$(printf '%q ' env "${env_args[@]}" "$@")"
  fi
}

set_gsetting_if_writable() {
  local user="$1"
  local schema="$2"
  local key="$3"
  local value="$4"

  if ! command_exists gsettings; then
    log_debug "gsettings is unavailable; skipping desktop power key ${schema}.${key}"
    return 0
  fi

  if ! run_as_user "${user}" gsettings writable "${schema}" "${key}" >/dev/null 2>&1; then
    log_debug "Skipping unavailable gsetting ${schema}.${key}"
    return 0
  fi

  if run_as_user "${user}" gsettings set "${schema}" "${key}" "${value}" >/dev/null 2>&1; then
    log_info "  Set ${schema}.${key}=${value}"
  else
    log_warn "  Failed to set ${schema}.${key}; leaving current desktop value"
  fi
}

write_sleep_logind_dropin() {
  mkdir -p "${LOGIND_DROPIN_DIR}"
  cat > "${LOGIND_POWER_DROPIN_PATH}" <<'EOF'
[Login]
IdleAction=ignore
HandleSuspendKey=ignore
HandleSuspendKeyLongPress=ignore
HandleHibernateKey=ignore
HandleHibernateKeyLongPress=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  chmod 0644 "${LOGIND_POWER_DROPIN_PATH}"
}

mask_sleep_targets() {
  if ! command_exists systemctl; then
    log_warn "  systemctl is unavailable; sleep target masking skipped"
    return 0
  fi

  local target
  for target in "${SLEEP_TARGETS[@]}"; do
    log_info "  Masking ${target}"
    systemctl mask "${target}" >/dev/null 2>&1 || log_warn "  Could not mask ${target}"
  done

  systemctl daemon-reload >/dev/null 2>&1 || true
  log_info "  Skipping logind restart to preserve desktop session"
}

unmask_sleep_targets_if_managed() {
  if [[ ! -f "${POWER_POLICY_MARKER_PATH}" ]]; then
    log_info "  Sleep targets were not marked as partner-node managed; not unmasking"
    return 0
  fi
  if ! grep -Eq '^PARTNER_NODE_DISABLE_SLEEP="?true"?' "${POWER_POLICY_MARKER_PATH}" 2>/dev/null; then
    log_info "  Partner-node marker exists, but sleep targets were not managed; not unmasking"
    return 0
  fi

  if ! command_exists systemctl; then
    return 0
  fi

  local target
  for target in "${SLEEP_TARGETS[@]}"; do
    log_info "  Unmasking ${target}"
    systemctl unmask "${target}" >/dev/null 2>&1 || true
  done

  systemctl daemon-reload >/dev/null 2>&1 || true
}

write_screen_blank_fallback() {
  mkdir -p "$(dirname "${SCREEN_BLANK_SCRIPT_PATH}")" "$(dirname "${SCREEN_BLANK_AUTOSTART_PATH}")"

  cat > "${SCREEN_BLANK_SCRIPT_PATH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if command -v xset >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
  xset -dpms >/dev/null 2>&1 || true
  xset s off >/dev/null 2>&1 || true
  xset s noblank >/dev/null 2>&1 || true
fi
EOF
  chmod 0755 "${SCREEN_BLANK_SCRIPT_PATH}"

  cat > "${SCREEN_BLANK_AUTOSTART_PATH}" <<EOF
[Desktop Entry]
Type=Application
Name=Partner Node Keep Screen On
Comment=Disable X11 screen blanking for partner-node appliance hosts
Exec=${SCREEN_BLANK_SCRIPT_PATH}
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  chmod 0644 "${SCREEN_BLANK_AUTOSTART_PATH}"
}

apply_desktop_screen_policy() {
  local user
  if ! user="$(detect_desktop_user)"; then
    log_warn "  Screen blanking: desktop user not detected; installed X11 autostart fallback only"
    write_screen_blank_fallback
    return 0
  fi

  log_info "  Screen blanking: disabled for user ${user}"

  set_gsetting_if_writable "${user}" "org.gnome.desktop.session" "idle-delay" "0"
  set_gsetting_if_writable "${user}" "org.gnome.settings-daemon.plugins.power" "idle-dim" "false"
  set_gsetting_if_writable "${user}" "org.gnome.settings-daemon.plugins.power" "sleep-inactive-ac-type" "nothing"
  set_gsetting_if_writable "${user}" "org.gnome.settings-daemon.plugins.power" "sleep-inactive-battery-type" "nothing"
  set_gsetting_if_writable "${user}" "org.gnome.desktop.screensaver" "lock-enabled" "false"
  set_gsetting_if_writable "${user}" "org.gnome.desktop.screensaver" "idle-activation-enabled" "false"

  write_screen_blank_fallback
}

remove_screen_policy_artifacts() {
  rm -f "${SCREEN_BLANK_SCRIPT_PATH}" "${SCREEN_BLANK_AUTOSTART_PATH}"
}

write_policy_marker() {
  mkdir -p "${CONFIG_DIR}"
  cat > "${POWER_POLICY_MARKER_PATH}" <<EOF
# Managed by partner-node-installer setup-power-policy.sh
PARTNER_NODE_DISABLE_SLEEP="${PARTNER_NODE_DISABLE_SLEEP}"
PARTNER_NODE_KEEP_SCREEN_ON="${PARTNER_NODE_KEEP_SCREEN_ON}"
UPDATED_AT="$(date -Is)"
EOF
  chmod 0644 "${POWER_POLICY_MARKER_PATH}"
}

remove_policy_marker_if_unused() {
  if ! is_true "${PARTNER_NODE_DISABLE_SLEEP}" && ! is_true "${PARTNER_NODE_KEEP_SCREEN_ON}"; then
    rm -f "${POWER_POLICY_MARKER_PATH}"
  fi
}

setup_power_policy() {
  require_root

  log_info "Applying partner-node power policy..."

  if is_true "${PARTNER_NODE_DISABLE_SLEEP}"; then
    log_info "  Sleep policy: disabled"
    write_sleep_logind_dropin
    mask_sleep_targets
  else
    log_info "  Sleep policy: installer-managed disable is off"
    rm -f "${LOGIND_POWER_DROPIN_PATH}"
    unmask_sleep_targets_if_managed
  fi

  if is_true "${PARTNER_NODE_KEEP_SCREEN_ON}"; then
    apply_desktop_screen_policy
  else
    log_info "  Screen blanking policy: installer-managed disable is off"
    remove_screen_policy_artifacts
  fi

  if is_true "${PARTNER_NODE_DISABLE_SLEEP}" || is_true "${PARTNER_NODE_KEEP_SCREEN_ON}"; then
    write_policy_marker
  else
    remove_policy_marker_if_unused
  fi

  log_info "Partner-node power policy applied"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_power_policy "$@"
fi
