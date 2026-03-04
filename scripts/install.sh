#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Partner Node Zero-Touch Installer (Linux)
# Usage (recommended):
#   curl -fsSL https://install.example.com/partner-node/install.sh | \
#     sudo bash -s -- --partner-key <KEY> --main-server https://main.example.com
###############################################################################

PARTNER_KEY=""
COUNTRY=""
MAIN_SERVER=""
BINARY_URL="http://chatmod-test.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.1.4"
DOCTOR_BINARY_URL=""
MODEM_ROTATION_METHOD="auto" # auto|mmcli|api
HILINK_ENABLED="true"
HILINK_BASE_URL=""
HILINK_TIMEOUT="15s"
THREEPROXY_VERSION="0.9.5"
THREEPROXY_PACKAGE_URL="https://chatmod-test.warforgalaxy.com/downloads/partner-node/3proxy.deb"
INSTALL_PREFIX="/usr/local/bin"
CONFIG_DIR="/etc/partner-node"
DATA_DIR="/var/lib/partner-node"
LOG_DIR="/var/log/partner-node"
PROXY_BINARY_PATH="/usr/bin/3proxy"
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
  --country <code>                Optional; auto-detected from public IP (fallback: US)
  --main-server <url>             Required in non-interactive mode
  --binary-url <url>              Direct URL to node-agent binary
  --modem-rotation-method <m>     auto|mmcli|api|api_reboot (default: auto)
  --hilink-enabled <true|false>   Default: true
  --hilink-base-url <url>         Example: http://192.168.13.1
  --hilink-timeout <duration>     Default: 15s
  --doctor-binary-url <url>       Direct URL to doctor binary
  --threeproxy-package-url <url>  Custom 3proxy package URL (.rpm/.deb)
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
      apt-get install -y ca-certificates curl git tar gzip jq systemd systemd-sysv build-essential
      apt-get install -y wireguard-tools modemmanager || true
      ;;
    dnf)
      dnf install -y ca-certificates curl git tar gzip jq systemd gcc make
      dnf install -y wireguard-tools ModemManager || true
      ;;
    yum)
      yum install -y ca-certificates curl git tar gzip jq systemd gcc make
      yum install -y wireguard-tools ModemManager || true
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

  if [[ -n "${BINARY_URL}" ]]; then
    url="${BINARY_URL}"
  else
    log_err "No binary URL available. Provide --binary-url."
    exit 1
  fi

  if [[ "${arch}" != "amd64" && "${url}" == "http://chatmod-test.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.1.4" ]]; then
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

  rm -rf "${tmpdir}"
}

install_3proxy_fallback() {
  local tmpdir archive_url
  tmpdir="$(mktemp -d)"
  archive_url="https://github.com/3proxy/3proxy/archive/refs/tags/${THREEPROXY_VERSION}.tar.gz"

  log_warn "3proxy package not found, building from source (${THREEPROXY_VERSION})"
  curl -fsSL "${archive_url}" -o "${tmpdir}/3proxy.tar.gz"
  tar -xzf "${tmpdir}/3proxy.tar.gz" -C "${tmpdir}"

  pushd "${tmpdir}/3proxy-${THREEPROXY_VERSION}" >/dev/null
  make -f Makefile.Linux
  install -m 0755 ./bin/3proxy "${INSTALL_PREFIX}/3proxy"
  popd >/dev/null

  ln -sf "${INSTALL_PREFIX}/3proxy" /usr/bin/3proxy
  rm -rf "${tmpdir}"
}

install_3proxy_from_custom_package() {
  local pkg_mgr="$1"
  local url="${THREEPROXY_PACKAGE_URL}"
  local tmpdir file ext

  if [[ -z "${url}" ]]; then
    return 1
  fi

  tmpdir="$(mktemp -d)"
  file="${tmpdir}/3proxy.pkg"
  log_info "Trying custom 3proxy package: ${url}"
  if ! curl -fsSL "${url}" -o "${file}"; then
    rm -rf "${tmpdir}"
    return 1
  fi

  ext="${url##*.}"
  case "${pkg_mgr}" in
    apt)
      if [[ "${ext}" == "deb" ]]; then
        if apt-get install -y "${file}"; then
          rm -rf "${tmpdir}"
          return 0
        fi
      else
        log_warn "Custom 3proxy package is .${ext}; apt expects .deb. Skipping."
      fi
      ;;
    dnf)
      if [[ "${ext}" == "rpm" ]]; then
        if dnf install -y "${file}"; then
          rm -rf "${tmpdir}"
          return 0
        fi
      else
        log_warn "Custom 3proxy package is .${ext}; dnf expects .rpm. Skipping."
      fi
      ;;
    yum)
      if [[ "${ext}" == "rpm" ]]; then
        if yum install -y "${file}"; then
          rm -rf "${tmpdir}"
          return 0
        fi
      else
        log_warn "Custom 3proxy package is .${ext}; yum expects .rpm. Skipping."
      fi
      ;;
  esac

  rm -rf "${tmpdir}"
  return 1
}

install_3proxy_from_github_deb() {
  local pkg_mgr="$1"
  local deb_arch candidates=() tmpdir url suffix installed=1

  if [[ "${pkg_mgr}" != "apt" ]]; then
    return 1
  fi
  if ! command -v dpkg >/dev/null 2>&1; then
    return 1
  fi

  deb_arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "${deb_arch}" in
    amd64) candidates=("x86_64") ;;
    arm64) candidates=("aarch64" "arm64") ;;
    *)
      return 1
      ;;
  esac

  tmpdir="$(mktemp -d)"
  for suffix in "${candidates[@]}"; do
    url="https://github.com/3proxy/3proxy/releases/download/${THREEPROXY_VERSION}/3proxy-${THREEPROXY_VERSION}.${suffix}.deb"
    log_info "Trying 3proxy GitHub package: ${url}"
    if curl -fsSL "${url}" -o "${tmpdir}/3proxy.deb"; then
      if apt-get install -y "${tmpdir}/3proxy.deb"; then
        installed=0
        break
      fi
    fi
  done

  rm -rf "${tmpdir}"
  return "${installed}"
}

install_3proxy_from_repo_if_available() {
  local pkg_mgr="$1"
  case "${pkg_mgr}" in
    apt)
      if apt-cache show 3proxy >/dev/null 2>&1; then
        log_info "Installing 3proxy from apt repository"
        apt-get install -y 3proxy
        return $?
      fi
      ;;
    dnf)
      if dnf -q list available 3proxy >/dev/null 2>&1; then
        log_info "Installing 3proxy from dnf repository"
        dnf install -y 3proxy
        return $?
      fi
      ;;
    yum)
      if yum -q list available 3proxy >/dev/null 2>&1; then
        log_info "Installing 3proxy from yum repository"
        yum install -y 3proxy
        return $?
      fi
      ;;
  esac
  return 1
}

ensure_3proxy() {
  local pkg_mgr="${1:-}"
  if command -v 3proxy >/dev/null 2>&1; then
    PROXY_BINARY_PATH="$(command -v 3proxy)"
    log_info "Found 3proxy at ${PROXY_BINARY_PATH}"
    return 0
  fi

  if [[ -n "${pkg_mgr}" ]]; then
    install_3proxy_from_custom_package "${pkg_mgr}" || true
  fi

  if command -v 3proxy >/dev/null 2>&1; then
    PROXY_BINARY_PATH="$(command -v 3proxy)"
    log_info "Installed 3proxy from custom package at ${PROXY_BINARY_PATH}"
    return 0
  fi

  if [[ -n "${pkg_mgr}" ]]; then
    install_3proxy_from_github_deb "${pkg_mgr}" || true
  fi

  if command -v 3proxy >/dev/null 2>&1; then
    PROXY_BINARY_PATH="$(command -v 3proxy)"
    log_info "Installed 3proxy from GitHub package at ${PROXY_BINARY_PATH}"
    return 0
  fi

  if [[ -n "${pkg_mgr}" ]]; then
    install_3proxy_from_repo_if_available "${pkg_mgr}" || true
  fi

  if command -v 3proxy >/dev/null 2>&1; then
    PROXY_BINARY_PATH="$(command -v 3proxy)"
    log_info "Installed 3proxy from repository at ${PROXY_BINARY_PATH}"
    return 0
  fi

  install_3proxy_fallback

  if command -v 3proxy >/dev/null 2>&1; then
    PROXY_BINARY_PATH="$(command -v 3proxy)"
    log_info "Installed 3proxy at ${PROXY_BINARY_PATH}"
    return 0
  fi

  log_warn "3proxy installation failed; proxy manager may not start."
  PROXY_BINARY_PATH="/usr/bin/3proxy"
  return 1
}

ensure_3proxy_config() {
  local conf_dir conf_path
  conf_dir="/etc/3proxy"
  conf_path="${conf_dir}/3proxy.conf"

  mkdir -p "${conf_dir}"
  if [[ -f "${conf_path}" && -s "${conf_path}" ]]; then
    log_info "Found existing 3proxy config at ${conf_path}"
    return 0
  fi

  cat > "${conf_path}" <<'EOF'
daemon
pidfile /var/run/3proxy.pid
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy/3proxy.log D
rotate 30
auth none
allow *
socks -p3128
EOF

  mkdir -p /var/log/3proxy
  chmod 0644 "${conf_path}"
  log_info "Created default 3proxy config at ${conf_path}"
}

autodetect_hilink_base_url() {
  local candidates=(
    "http://192.168.13.1"
    "http://192.168.8.1"
    "http://192.168.3.1"
    "http://192.168.1.1"
  )

  for base in "${candidates[@]}"; do
    if curl -fsS --max-time 3 "${base}/api/webserver/SesTokInfo" >/dev/null 2>&1; then
      HILINK_BASE_URL="${base}"
      log_info "Detected HiLink API at ${HILINK_BASE_URL}"
      return 0
    fi
  done

  return 1
}

autodetect_country() {
  local value
  value="$(curl -fsS --max-time 5 https://ipapi.co/country 2>/dev/null || true)"
  value="$(echo "${value}" | tr '[:lower:]' '[:upper:]' | tr -d '\r\n[:space:]')"
  if [[ "${value}" =~ ^[A-Z]{2}$ ]]; then
    COUNTRY="${value}"
    log_info "Detected country from IP: ${COUNTRY}"
    return 0
  fi

  value="$(curl -fsS --max-time 5 https://ipinfo.io/country 2>/dev/null || true)"
  value="$(echo "${value}" | tr '[:lower:]' '[:upper:]' | tr -d '\r\n[:space:]')"
  if [[ "${value}" =~ ^[A-Z]{2}$ ]]; then
    COUNTRY="${value}"
    log_info "Detected country from IP: ${COUNTRY}"
    return 0
  fi

  return 1
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
  rotation:
    default_method: "${MODEM_ROTATION_METHOD}"
  hilink:
    enabled: ${HILINK_ENABLED}
    base_url: "${HILINK_BASE_URL}"
    timeout: "${HILINK_TIMEOUT}"

proxy:
  binary_path: "${PROXY_BINARY_PATH}"
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
      --modem-rotation-method) MODEM_ROTATION_METHOD="${2:-}"; shift 2 ;;
      --hilink-enabled) HILINK_ENABLED="${2:-}"; shift 2 ;;
      --hilink-base-url) HILINK_BASE_URL="${2:-}"; shift 2 ;;
      --hilink-timeout) HILINK_TIMEOUT="${2:-}"; shift 2 ;;
      --doctor-binary-url) DOCTOR_BINARY_URL="${2:-}"; shift 2 ;;
      --threeproxy-package-url) THREEPROXY_PACKAGE_URL="${2:-}"; shift 2 ;;
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
  if [[ "${MODEM_ROTATION_METHOD}" != "auto" && "${MODEM_ROTATION_METHOD}" != "mmcli" && "${MODEM_ROTATION_METHOD}" != "api" && "${MODEM_ROTATION_METHOD}" != "api_reboot" ]]; then
    log_err "--modem-rotation-method must be auto, mmcli, api or api_reboot."
    exit 1
  fi

  log_info "Starting partner-node zero-touch installation"
  local pkg_mgr
  pkg_mgr="$(detect_pkg_manager)"
  log_info "Detected package manager: ${pkg_mgr}"
  install_packages "${pkg_mgr}"
  install_from_binary
  ensure_3proxy "${pkg_mgr}" || true
  ensure_3proxy_config

  if [[ "${HILINK_ENABLED}" == "true" && -z "${HILINK_BASE_URL}" ]]; then
    if ! autodetect_hilink_base_url; then
      log_warn "HiLink auto-detect failed. Falling back to http://192.168.13.1"
      HILINK_BASE_URL="http://192.168.13.1"
    fi
  fi

  if [[ -z "${COUNTRY}" ]]; then
    if ! autodetect_country; then
      COUNTRY="US"
      log_warn "Country auto-detect failed. Falling back to ${COUNTRY}."
    fi
  fi

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
