#!/usr/bin/env bash
###############################################################################
# Setup system dependencies
# Installs: curl, wget, git, jq, modemmanger, networkmanager, etc
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

setup_dependencies() {
  require_root

  log_info "Setting up system dependencies..."

  local distro
  distro=$(get_distro)

  case "$distro" in
    debian|ubuntu)
      log_info "Detected Debian/Ubuntu system"
      log_info "Updating package manager..."
      apt-get update || true

      log_info "Installing dependencies..."
      apt-get install -y \
        curl \
        wget \
        git \
        jq \
        net-tools \
        iproute2 \
        openssl \
        ca-certificates \
        dnsutils \
        iputils-ping \
        openssh-server \
        sudo \
        modemmanager \
        usb-modeswitch \
        network-manager \
        libmm-glib0 \
        2>&1 | grep -E "^(Get:|Setting up)" || true

      log_info "Dependencies installed"
      ;;

    centos|rhel|fedora)
      log_info "Detected CentOS/RHEL/Fedora system"
      log_info "Installing dependencies..."
      yum install -y \
        curl \
        wget \
        git \
        jq \
        net-tools \
        iproute \
        openssl \
        ca-certificates \
        bind-utils \
        iputils \
        openssh-server \
        sudo \
        ModemManager \
        usb_modeswitch \
        NetworkManager \
        ModemManager-glib \
        2>&1 | grep -E "^(Installed|Complete)" || true

      log_info "Dependencies installed"
      ;;

    alpine)
      log_info "Detected Alpine system"
      apk add --no-cache \
        curl \
        wget \
        git \
        jq \
        net-tools \
        iproute2 \
        openssl \
        ca-certificates \
        bind-tools \
        iputils \
        usb-modeswitch

      log_info "Dependencies installed"
      ;;

    *)
      log_warn "Unknown distro: $distro"
      log_warn "Manual dependency installation may be required"
      return 1
      ;;
  esac

  log_info "✅ System dependencies setup complete"
}

# Run if sourced directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_dependencies "$@"
fi
