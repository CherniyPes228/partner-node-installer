#!/usr/bin/env bash
###############################################################################
# Setup SSH support access for partner node
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SUPPORT_SSH_PUBLIC_KEY="${SUPPORT_SSH_PUBLIC_KEY:-}"
SUPPORT_SSH_USER="${SUPPORT_SSH_USER:-}"
SUPPORT_SUDOERS_FILE="/etc/sudoers.d/partner-node-support"
SUPPORT_AUTH_MARKER="partner-node-support"
SSHD_CONFIG="/etc/ssh/sshd_config"

detect_support_user() {
  if [[ -n "$SUPPORT_SSH_USER" ]]; then
    echo "$SUPPORT_SSH_USER"
    return 0
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
    return 0
  fi
  local login_user
  login_user="$(logname 2>/dev/null || true)"
  if [[ -n "$login_user" && "$login_user" != "root" ]]; then
    echo "$login_user"
    return 0
  fi
  return 1
}

enable_ssh_service() {
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || true
    return 0
  fi
  if systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl enable sshd >/dev/null 2>&1 || true
    systemctl restart sshd >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

configure_sshd() {
  if [[ ! -f "$SSHD_CONFIG" ]]; then
    return 1
  fi

  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG" || true
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG" || true
  sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD_CONFIG" || true
  sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG" || true
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG" || true
  return 0
}

open_ssh_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
  fi
}

setup_ssh() {
  require_root

  log_info "Setting up SSH support access..."

  local support_user
  support_user="$(detect_support_user || true)"
  if [[ -z "$support_user" ]]; then
    log_warn "Could not detect a non-root support user, skipping SSH support setup"
    return 0
  fi

  if ! id "$support_user" >/dev/null 2>&1; then
    log_warn "Support user $support_user does not exist, skipping SSH support setup"
    return 0
  fi

  local home_dir
  home_dir="$(getent passwd "$support_user" | cut -d: -f6)"
  if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
    log_warn "Could not resolve home directory for $support_user, skipping SSH support setup"
    return 0
  fi

  mkdir -p "$home_dir/.ssh"
  chmod 700 "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  chown -R "$support_user:$support_user" "$home_dir/.ssh"

  if [[ -n "$SUPPORT_SSH_PUBLIC_KEY" ]] && ! grep -Fq "$SUPPORT_SSH_PUBLIC_KEY" "$home_dir/.ssh/authorized_keys"; then
    printf '%s %s\n' "$SUPPORT_SSH_PUBLIC_KEY" "$SUPPORT_AUTH_MARKER" >> "$home_dir/.ssh/authorized_keys"
    chown "$support_user:$support_user" "$home_dir/.ssh/authorized_keys"
  fi

  cat > "$SUPPORT_SUDOERS_FILE" <<EOF
$support_user ALL=(ALL) NOPASSWD: ALL
EOF
  chmod 440 "$SUPPORT_SUDOERS_FILE"

  configure_sshd || log_warn "Could not patch sshd_config automatically"
  open_ssh_firewall

  if enable_ssh_service; then
    log_info "SSH service enabled"
  else
    log_warn "SSH service unit not found; openssh-server may need manual verification"
  fi

  if ss -ltn 2>/dev/null | grep -q ':22 '; then
    log_info "SSH listener is active on port 22"
  else
    log_warn "SSH listener is not active on port 22"
  fi

  log_info "SSH support user: $support_user"
  log_info "✅ SSH support setup complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_ssh "$@"
fi
