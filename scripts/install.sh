#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Partner Node Zero-Touch Installer (Linux)
# Usage (recommended):
#   curl -fsSL https://install.example.com/partner-node/install.sh | \
#     sudo bash -s -- --partner-key <KEY> --country US --main-server https://main.example.com
###############################################################################

PARTNER_KEY=""
COUNTRY="US"
MAIN_SERVER=""
BINARY_URL="http://chatmod-test.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.1.0"
DOCTOR_BINARY_URL=""
INSTALL_PREFIX="/usr/local/bin"
CONFIG_DIR="/etc/partner-node"
DATA_DIR="/var/lib/partner-node"
LOG_DIR="/var/log/partner-node"
SERVICE_NAME="partner-node"
RUN_USER="partner-node"
SKIP_START="false"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  cat <<EOF
Zero-touch installer for partner-node.

Required:
  --partner-key <key>            Optional if interactive TTY is available.

Optional:
  --country <code>                Default: US
  --main-server <url>             Required in non-interactive mode
  --binary-url <url>              Direct URL to node-agent binary
  --doctor-binary-url <url>       Direct URL to doctor binary
  --install-prefix <dir>          Default: /usr/local/bin
  --skip-start                    Install only, do not start service
  --help
EOF
}

is_tty() {
  [[ -r /dev/tty ]]
}

prompt_if_needed() {
  if [[ -z "${PARTNER_KEY}" ]]; then
    if is_tty; then
      read -r -p "Enter partner key: " PARTNER_KEY </dev/tty
    fi
  fi

  if [[ -z "${MAIN_SERVER}" ]]; then
    if is_tty; then
      read -r -p "Enter MAIN server URL (e.g. https://main.yourdomain.com): " input_main </dev/tty
      if [[ -n "${input_main}" ]]; then
        MAIN_SERVER="${input_main}"
      fi
    fi
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_err "Run as root (or use sudo)."
    exit 1
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"
    return
  fi
  log_err "Unsupported distro: apt/dnf/yum not found."
  exit 1
}

install_packages() {
  local pkg_mgr="$1"
  case "${pkg_mgr}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y ca-certificates curl git tar gzip jq systemd systemd-sysv
      apt-get install -y wireguard-tools modemmanager 3proxy || true
      ;;
    dnf)
      dnf install -y ca-certificates curl git tar gzip jq systemd
      dnf install -y wireguard-tools ModemManager 3proxy || true
      ;;
    yum)
      yum install -y ca-certificates curl git tar gzip jq systemd
      yum install -y wireguard-tools ModemManager 3proxy || true
      ;;
  esac
}

arch_to_go() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      log_err "Unsupported architecture: ${machine}"
      exit 1
      ;;
  esac
}

install_from_binary() {
  local arch url doctor_url tmpdir
  arch="$(arch_to_go)"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  if [[ -n "${BINARY_URL}" ]]; then
    url="${BINARY_URL}"
  else
    log_err "No binary URL available. Provide --binary-url."
    exit 1
  fi

  if [[ "${arch}" != "amd64" && "${url}" == "http://chatmod-test.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.1.0" ]]; then
    log_err "Default binary is amd64-only. Provide --binary-url for ${arch}."
    exit 1
  fi

  log_info "Downloading node-agent binary from ${url}"
  curl -fsSL "${url}" -o "${tmpdir}/node-agent"
  install -m 0755 "${tmpdir}/node-agent" "${INSTALL_PREFIX}/node-agent"

  if [[ -n "${DOCTOR_BINARY_URL}" ]]; then
    doctor_url="${DOCTOR_BINARY_URL}"
    log_info "Downloading doctor binary from ${doctor_url}"
    curl -fsSL "${doctor_url}" -o "${tmpdir}/doctor"
    install -m 0755 "${tmpdir}/doctor" "${INSTALL_PREFIX}/doctor"
  fi
}

create_user_and_dirs() {
  if ! id -u "${RUN_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${RUN_USER}" || true
  fi
  mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"
  chown -R "${RUN_USER}:${RUN_USER}" "${DATA_DIR}" "${LOG_DIR}" || true
  chmod 0755 "${DATA_DIR}" "${LOG_DIR}"
}

write_config() {
  local config_path
  config_path="${CONFIG_DIR}/config.yaml"
  cat > "${config_path}" <<EOF
api:
  main_server: "${MAIN_SERVER}"
  partner_key: "${PARTNER_KEY}"

agent:
  id: ""
  token: ""
  country: "${COUNTRY}"
  heartbeat_interval: 10s
  health_check_interval: 30s

modem:
  mmcli_path: "/usr/bin/mmcli"
  discovery_interval: 30s
  health_check_interval: 60s

proxy:
  binary_path: "/usr/bin/3proxy"
  config_path: "/etc/3proxy/3proxy.conf"
  max_connections: 10000
  buffer_size: 65536

tunnel:
  wireguard:
    interface_name: "wg0"
    assigned_ip: ""
    allowed_ips: "0.0.0.0/0"
    peer_endpoint: ""
    peer_public_key: ""
    persistent_keepalive: 25
    mtu: 1420
  mtls:
    enabled: true
    listen_addr: "127.0.0.1"
    listen_port: 8443
    cert_path: "/etc/partner-node/certs/client.crt"
    key_path: "/etc/partner-node/certs/client.key"
    ca_path: "/etc/partner-node/certs/ca.crt"
    insecure_skip_verify: false
    min_tls_version: "1.2"

storage:
  data_dir: "${DATA_DIR}"

security:
  allowed_commands:
    - "rotate_ip"
    - "drain"
    - "quarantine"
    - "restart_proxy"
    - "reconcile_config"
    - "self_check"
EOF
  chmod 0600 "${config_path}"
}

write_systemd_unit() {
  local service_path
  service_path="/etc/systemd/system/${SERVICE_NAME}.service"
  cat > "${service_path}" <<EOF
[Unit]
Description=Partner Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${INSTALL_PREFIX}/node-agent -config ${CONFIG_DIR}/config.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

start_service() {
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  if [[ "${SKIP_START}" == "true" ]]; then
    log_warn "Skipping service start (--skip-start)."
    return
  fi
  systemctl restart "${SERVICE_NAME}"
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log_info "Service ${SERVICE_NAME} is active."
  else
    log_warn "Service ${SERVICE_NAME} is not active yet. Check: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --partner-key) PARTNER_KEY="${2:-}"; shift 2 ;;
      --country) COUNTRY="${2:-}"; shift 2 ;;
      --main-server) MAIN_SERVER="${2:-}"; shift 2 ;;
      --binary-url) BINARY_URL="${2:-}"; shift 2 ;;
      --doctor-binary-url) DOCTOR_BINARY_URL="${2:-}"; shift 2 ;;
      --install-prefix) INSTALL_PREFIX="${2:-}"; shift 2 ;;
      --skip-start) SKIP_START="true"; shift ;;
      --help|-h) usage; exit 0 ;;
      *)
        log_err "Unknown arg: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_root
  prompt_if_needed

  if [[ -z "${PARTNER_KEY}" ]]; then
    log_err "--partner-key is required (or provide it interactively)."
    usage
    exit 1
  fi
  if [[ -z "${MAIN_SERVER}" ]]; then
    log_err "Set --main-server (or provide it interactively)."
    usage
    exit 1
  fi

  log_info "Starting partner-node zero-touch installation"
  local pkg_mgr
  pkg_mgr="$(detect_pkg_manager)"
  log_info "Detected package manager: ${pkg_mgr}"
  install_packages "${pkg_mgr}"
  install_from_binary

  create_user_and_dirs
  write_config
  write_systemd_unit
  start_service

  log_info "Installation finished."
  echo
  echo "Useful commands:"
  echo "  systemctl status ${SERVICE_NAME}"
  echo "  journalctl -u ${SERVICE_NAME} -f"
  echo "  ${INSTALL_PREFIX}/doctor version || true"
}

main "$@"
