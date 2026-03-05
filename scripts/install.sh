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
BINARY_URL="http://chatmod-test.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.1.21"
BINARY_URL_EXPLICIT="false"
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
UI_SERVICE_NAME="partner-node-ui"
UI_DIR="/opt/partner-node-ui"
UI_PORT="19090"
AUTO_UPDATE_SERVICE_NAME="partner-node-self-update"
AUTO_UPDATE_TIMER_NAME="partner-node-self-update.timer"
AUTO_UPDATE_ENABLED="false"
AUTO_UPDATE_INTERVAL="6h"
INSTALLER_URL="https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/install.sh"
RUN_USER="partner-node"
SKIP_START="false"
SKIP_FIREWALL="false"

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
  --skip-firewall                 Do not apply host firewall hardening
  --ui-port <port>                Local partner UI port (default: 19090)
  --auto-update-enabled <bool>    true|false (default: false)
  --auto-update-interval <dur>    systemd duration, default: 6h
  --installer-url <url>           URL used by self-update timer
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
      apt-get install -y ca-certificates curl git tar gzip jq systemd systemd-sysv build-essential python3
      apt-get install -y wireguard-tools modemmanager || true
      ;;
    dnf)
      dnf install -y ca-certificates curl git tar gzip jq systemd gcc make python3
      dnf install -y wireguard-tools ModemManager || true
      ;;
    yum)
      yum install -y ca-certificates curl git tar gzip jq systemd gcc make python3
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

  if [[ "${arch}" != "amd64" && "${url}" == "http://chatmod-test.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.1.21" ]]; then
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

harden_secret_permissions() {
  local certs_dir secrets_dir
  certs_dir="${CONFIG_DIR}/certs"
  secrets_dir="${CONFIG_DIR}/secrets"

  chown -R root:root "${CONFIG_DIR}" || true
  chmod 0700 "${CONFIG_DIR}" || true

  if [[ -f "${CONFIG_DIR}/config.yaml" ]]; then
    chmod 0600 "${CONFIG_DIR}/config.yaml" || true
  fi

  if [[ -d "${certs_dir}" ]]; then
    chmod 0700 "${certs_dir}" || true
    find "${certs_dir}" -type f -exec chmod 0600 {} \; || true
  fi

  if [[ -d "${secrets_dir}" ]]; then
    chmod 0700 "${secrets_dir}" || true
    find "${secrets_dir}" -type f -exec chmod 0600 {} \; || true
  fi
}

configure_firewall() {
  if [[ "${SKIP_FIREWALL}" == "true" ]]; then
    log_warn "Skipping firewall hardening (--skip-firewall)."
    return 0
  fi

  if ! command -v iptables >/dev/null 2>&1; then
    log_warn "iptables not found; cannot enforce inbound firewall policy."
    return 1
  fi

  # Reset INPUT policy and set strict defaults.
  iptables -F INPUT
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  # Allow loopback and established traffic.
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Keep SSH access.
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT

  # Allow 3proxy ports only via WireGuard interface.
  iptables -A INPUT -i wg0 -p tcp --dport 31001:32000 -j ACCEPT

  log_info "Firewall policy applied: incoming blocked by default; 3proxy allowed only via wg0."
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
    - "force_fallback"
    - "force_primary"
    - "transport_self_check"
    - "self_update"
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

write_partner_ui_files() {
  mkdir -p "${UI_DIR}"

  cat > "${UI_DIR}/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Partner Node Local Dashboard</title>
  <style>
    :root { --bg:#f5f7fa; --card:#fff; --line:#d8dee7; --text:#1f2937; --accent:#0b6d6d; }
    body { margin:0; font-family:Segoe UI, sans-serif; background:var(--bg); color:var(--text); }
    .wrap { max-width: 1000px; margin: 0 auto; padding: 16px; }
    .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px; margin-bottom:12px; }
    .row { display:flex; gap:8px; flex-wrap:wrap; align-items:center; margin-bottom:8px; }
    input, select, button, textarea { border:1px solid var(--line); border-radius:8px; padding:8px; font:inherit; }
    button { border:0; color:#fff; background:var(--accent); cursor:pointer; }
    table { width:100%; border-collapse:collapse; }
    th, td { text-align:left; padding:6px; border-bottom:1px solid #edf2f7; font-size:13px; }
    .muted { color:#64748b; }
    .error { color:#b42318; }
  </style>
</head>
<body>
  <div class="wrap">
    <h2>Partner Node Local Dashboard</h2>
    <div id="error" class="error"></div>

    <div class="card">
      <div class="row">
        <button onclick="refresh()">Refresh</button>
      </div>
      <div id="meta" class="muted">No data</div>
    </div>

    <div class="card">
      <h3>Command</h3>
      <div class="row">
        <select id="cmdType">
          <option>self_check</option>
          <option>rotate_ip</option>
          <option>restart_proxy</option>
          <option>reconcile_config</option>
          <option>transport_self_check</option>
        </select>
        <input id="timeout" type="number" min="1" value="30" />
        <button onclick="sendCommand()">Send</button>
      </div>
      <textarea id="params" rows="3" style="width:100%">{"reason":"manual"}</textarea>
      <div id="cmdResult" class="muted" style="margin-top:8px"></div>
    </div>

    <div class="card">
      <h3>Modems</h3>
      <table>
        <thead><tr><th>#</th><th>ID</th><th>State</th><th>WAN IP</th><th>Operator</th><th>Signal</th><th>Port</th></tr></thead>
        <tbody id="modems"></tbody>
      </table>
    </div>
  </div>

  <script>
    function formatBytes(value){
      const bytes = Number(value || 0);
      if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
      const units = ['B','KB','MB','GB','TB'];
      const exp = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
      const num = bytes / Math.pow(1024, exp);
      return `${num.toFixed(exp === 0 ? 0 : 2)} ${units[exp]}`;
    }
    function setError(msg){ document.getElementById('error').textContent = msg || ''; }
    function showMeta(d){
      document.getElementById('meta').textContent =
        `node=${d.node_id || '-'} status=${d.node_status || '-'} ip=${d.external_ip || '-'} ` +
        `traffic_in=${formatBytes(d.bytes_in_total)} traffic_out=${formatBytes(d.bytes_out_total)} pending=${d.pending_commands || 0}`;
    }
    function showModems(items, externalIP){
      const body = document.getElementById('modems');
      body.innerHTML = '';
      (items || []).forEach(m => {
        const ip = m.wan_ip || m.ip || '';
        const tr = document.createElement('tr');
        tr.innerHTML = `<td>${m.ordinal || '-'}</td><td>${m.id || ''}</td><td>${m.state || ''}</td><td>${ip}</td><td>${m.operator || ''}</td><td>${m.signal_strength || 0}</td><td>${m.port || ''}</td>`;
        body.appendChild(tr);
      });
    }
    function showCommandResult(text, ok){
      const el = document.getElementById('cmdResult');
      el.textContent = text || '';
      el.style.color = ok ? '#166534' : '#b42318';
      el.style.fontWeight = '600';
    }
    async function refresh(){
      try {
        setError('');
        const r = await fetch('/api/overview');
        if(!r.ok) throw new Error(await r.text());
        const d = await r.json();
        showMeta(d);
        showModems(d.modems || [], d.external_ip || '');
        const last = (d.last_results || [])[0];
        if (last) {
          const msg = `[${last.status || 'unknown'}] ${last.message || ''} (id=${last.command_id || '-'})`;
          showCommandResult(msg, last.status === 'success');
        }
      } catch(e) { setError(String(e.message || e)); }
    }
    async function sendCommand(){
      try {
        setError('');
        let params = {};
        const raw = document.getElementById('params').value.trim();
        if(raw) params = JSON.parse(raw);
        const payload = {
          type: document.getElementById('cmdType').value,
          timeout_sec: Number(document.getElementById('timeout').value || 30),
          params
        };
        const r = await fetch('/api/command', {
          method:'POST',
          headers:{'Content-Type':'application/json'},
          body: JSON.stringify(payload)
        });
        if(!r.ok) throw new Error(await r.text());
        const res = await r.json();
        const cmdId = res?.command?.id || '-';
        showCommandResult(`[pending] command queued (id=${cmdId})`, true);
        await refresh();
      } catch(e) { setError(String(e.message || e)); }
    }
    refresh();
    setInterval(refresh, 7000);
  </script>
</body>
</html>
EOF

  cat > "${UI_DIR}/server.py" <<'EOF'
#!/usr/bin/env python3
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

MAIN_SERVER = os.environ.get("MAIN_SERVER", "").rstrip("/")
PARTNER_KEY = os.environ.get("PARTNER_KEY", "")
LISTEN_ADDR = os.environ.get("UI_LISTEN_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("UI_PORT", "19090"))
INDEX_PATH = os.path.join(os.path.dirname(__file__), "index.html")

ALLOWED = {"self_check", "rotate_ip", "restart_proxy", "reconcile_config", "transport_self_check"}

def json_request(url, method="GET", payload=None):
  body = None
  headers = {"Content-Type": "application/json"}
  if payload is not None:
    body = json.dumps(payload).encode("utf-8")
  req = urllib.request.Request(url, method=method, data=body, headers=headers)
  with urllib.request.urlopen(req, timeout=20) as resp:
    data = resp.read()
    return json.loads(data.decode("utf-8"))

class Handler(BaseHTTPRequestHandler):
  def _send_json(self, code, payload):
    body = json.dumps(payload).encode("utf-8")
    self.send_response(code)
    self.send_header("Content-Type", "application/json")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)

  def _send_text(self, code, text):
    body = text.encode("utf-8")
    self.send_response(code)
    self.send_header("Content-Type", "text/plain; charset=utf-8")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)

  def do_GET(self):
    if self.path in ("/", "/index.html"):
      with open(INDEX_PATH, "rb") as f:
        html = f.read()
      self.send_response(200)
      self.send_header("Content-Type", "text/html; charset=utf-8")
      self.send_header("Content-Length", str(len(html)))
      self.end_headers()
      self.wfile.write(html)
      return
    if self.path == "/api/overview":
      try:
        qs = urllib.parse.urlencode({"partner_key": PARTNER_KEY})
        data = json_request(f"{MAIN_SERVER}/api/partner/overview?{qs}")
        self._send_json(200, data)
      except urllib.error.HTTPError as e:
        self._send_text(e.code, e.read().decode("utf-8", errors="ignore"))
      except Exception as e:
        self._send_text(502, str(e))
      return
    if self.path == "/healthz":
      self._send_text(200, "ok")
      return
    self._send_text(404, "not found")

  def do_POST(self):
    if self.path != "/api/command":
      self._send_text(404, "not found")
      return
    try:
      length = int(self.headers.get("Content-Length", "0"))
      raw = self.rfile.read(length) if length > 0 else b"{}"
      req = json.loads(raw.decode("utf-8"))
      cmd_type = str(req.get("type", "")).strip()
      if cmd_type not in ALLOWED:
        self._send_text(403, "command not allowed")
        return
      payload = {
        "partner_key": PARTNER_KEY,
        "type": cmd_type,
        "timeout_sec": int(req.get("timeout_sec", 30)),
        "params": req.get("params", {}),
      }
      data = json_request(f"{MAIN_SERVER}/api/partner/command", method="POST", payload=payload)
      self._send_json(200, data)
    except urllib.error.HTTPError as e:
      self._send_text(e.code, e.read().decode("utf-8", errors="ignore"))
    except Exception as e:
      self._send_text(400, str(e))

  def log_message(self, fmt, *args):
    return

if __name__ == "__main__":
  server = HTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler)
  server.serve_forever()
EOF

  chmod 0755 "${UI_DIR}/server.py"
  chmod 0644 "${UI_DIR}/index.html"
}

write_partner_ui_env() {
  local path
  path="${UI_DIR}/ui.env"
  cat > "${path}" <<EOF
MAIN_SERVER="${MAIN_SERVER}"
PARTNER_KEY="${PARTNER_KEY}"
UI_LISTEN_ADDR="127.0.0.1"
UI_PORT="${UI_PORT}"
EOF
  chmod 0600 "${path}"
}

write_partner_ui_systemd_unit() {
  local service_path
  service_path="/etc/systemd/system/${UI_SERVICE_NAME}.service"
  cat > "${service_path}" <<EOF
[Unit]
Description=Partner Node Local UI
After=network-online.target ${SERVICE_NAME}.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=${UI_DIR}/ui.env
ExecStart=/usr/bin/python3 ${UI_DIR}/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

start_partner_ui_service() {
  systemctl daemon-reload
  systemctl enable "${UI_SERVICE_NAME}"
  if [[ "${SKIP_START}" == "true" ]]; then
    log_warn "Skipping ${UI_SERVICE_NAME} start (--skip-start)."
    return
  fi
  systemctl restart "${UI_SERVICE_NAME}"
  sleep 1
  if systemctl is-active --quiet "${UI_SERVICE_NAME}"; then
    log_info "Service ${UI_SERVICE_NAME} is active."
  else
    log_warn "Service ${UI_SERVICE_NAME} is not active yet. Check: journalctl -u ${UI_SERVICE_NAME} -n 100 --no-pager"
  fi
}

write_install_env() {
  local path binary_url_override
  path="${CONFIG_DIR}/install.env"
  binary_url_override=""
  if [[ "${BINARY_URL_EXPLICIT}" == "true" ]]; then
    binary_url_override="${BINARY_URL}"
  fi
  cat > "${path}" <<EOF
PARTNER_KEY="${PARTNER_KEY}"
COUNTRY="${COUNTRY}"
MAIN_SERVER="${MAIN_SERVER}"
BINARY_URL_OVERRIDE="${binary_url_override}"
DOCTOR_BINARY_URL="${DOCTOR_BINARY_URL}"
MODEM_ROTATION_METHOD="${MODEM_ROTATION_METHOD}"
HILINK_ENABLED="${HILINK_ENABLED}"
HILINK_BASE_URL="${HILINK_BASE_URL}"
HILINK_TIMEOUT="${HILINK_TIMEOUT}"
THREEPROXY_PACKAGE_URL="${THREEPROXY_PACKAGE_URL}"
INSTALL_PREFIX="${INSTALL_PREFIX}"
SKIP_FIREWALL="${SKIP_FIREWALL}"
UI_PORT="${UI_PORT}"
AUTO_UPDATE_ENABLED="${AUTO_UPDATE_ENABLED}"
AUTO_UPDATE_INTERVAL="${AUTO_UPDATE_INTERVAL}"
INSTALLER_URL="${INSTALLER_URL}"
EOF
  chmod 0600 "${path}"
  chown root:root "${path}" || true
}

write_self_update_script() {
  local path
  path="/usr/local/sbin/partner-node-self-update.sh"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/partner-node/install.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[partner-node-self-update] install.env not found, skipping."
  exit 0
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

if [[ "${AUTO_UPDATE_ENABLED:-true}" != "true" && "${SELF_UPDATE_FORCE:-false}" != "true" ]]; then
  echo "[partner-node-self-update] auto-update disabled."
  exit 0
fi

if [[ -z "${PARTNER_KEY:-}" || -z "${MAIN_SERVER:-}" ]]; then
  echo "[partner-node-self-update] missing PARTNER_KEY or MAIN_SERVER."
  exit 1
fi

TMP="$(mktemp)"
TMP_BIN="$(mktemp)"
trap 'rm -f "${TMP}" "${TMP_BIN}"' EXIT
curl -fsSL "${INSTALLER_URL}" -o "${TMP}"

TARGET_BINARY_URL="${BINARY_URL_OVERRIDE:-}"
if [[ -z "${TARGET_BINARY_URL}" ]]; then
  TARGET_BINARY_URL="$(sed -n 's/^BINARY_URL=\"\\(.*\\)\"$/\\1/p' "${TMP}" | head -n 1)"
fi

if [[ -n "${TARGET_BINARY_URL}" && -f "/usr/local/bin/node-agent" ]]; then
  if curl -fsSL "${TARGET_BINARY_URL}" -o "${TMP_BIN}"; then
    LOCAL_HASH="$(sha256sum /usr/local/bin/node-agent | awk '{print $1}')"
    REMOTE_HASH="$(sha256sum "${TMP_BIN}" | awk '{print $1}')"
    if [[ -n "${LOCAL_HASH}" && "${LOCAL_HASH}" == "${REMOTE_HASH}" ]]; then
      echo "[partner-node-self-update] node-agent already up to date (${LOCAL_HASH})."
      exit 0
    fi
  fi
fi

ARGS=(
  --partner-key "${PARTNER_KEY}"
  --main-server "${MAIN_SERVER}"
  --modem-rotation-method "${MODEM_ROTATION_METHOD:-auto}"
  --hilink-enabled "${HILINK_ENABLED:-true}"
  --hilink-timeout "${HILINK_TIMEOUT:-15s}"
  --install-prefix "${INSTALL_PREFIX:-/usr/local/bin}"
  --ui-port "${UI_PORT:-19090}"
  --auto-update-enabled "${AUTO_UPDATE_ENABLED:-true}"
  --auto-update-interval "${AUTO_UPDATE_INTERVAL:-6h}"
  --installer-url "${INSTALLER_URL}"
)

if [[ -n "${COUNTRY:-}" ]]; then ARGS+=(--country "${COUNTRY}"); fi
if [[ -n "${BINARY_URL_OVERRIDE:-}" ]]; then ARGS+=(--binary-url "${BINARY_URL_OVERRIDE}"); fi
if [[ -n "${DOCTOR_BINARY_URL:-}" ]]; then ARGS+=(--doctor-binary-url "${DOCTOR_BINARY_URL}"); fi
if [[ -n "${HILINK_BASE_URL:-}" ]]; then ARGS+=(--hilink-base-url "${HILINK_BASE_URL}"); fi
if [[ -n "${THREEPROXY_PACKAGE_URL:-}" ]]; then ARGS+=(--threeproxy-package-url "${THREEPROXY_PACKAGE_URL}"); fi
if [[ "${SKIP_FIREWALL:-false}" == "true" ]]; then ARGS+=(--skip-firewall); fi
if [[ "${SELF_UPDATE_SKIP_START:-false}" == "true" ]]; then ARGS+=(--skip-start); fi

bash "${TMP}" "${ARGS[@]}"
EOF
  chmod 0755 "${path}"
  chown root:root "${path}" || true
}

write_self_update_systemd_units() {
  cat > "/etc/systemd/system/${AUTO_UPDATE_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Partner Node Self-Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/partner-node-self-update.sh
EOF

  cat > "/etc/systemd/system/${AUTO_UPDATE_TIMER_NAME}" <<EOF
[Unit]
Description=Run Partner Node Self-Update periodically

[Timer]
OnBootSec=3min
OnUnitActiveSec=${AUTO_UPDATE_INTERVAL}
Persistent=true
Unit=${AUTO_UPDATE_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF
}

start_self_update_timer() {
  systemctl daemon-reload
  if [[ "${AUTO_UPDATE_ENABLED}" != "true" ]]; then
    systemctl disable --now "${AUTO_UPDATE_TIMER_NAME}" >/dev/null 2>&1 || true
    log_warn "Self-update timer is disabled."
    return 0
  fi
  systemctl enable "${AUTO_UPDATE_TIMER_NAME}"
  if [[ "${SKIP_START}" == "true" ]]; then
    log_warn "Skipping ${AUTO_UPDATE_TIMER_NAME} start (--skip-start)."
    return 0
  fi
  systemctl restart "${AUTO_UPDATE_TIMER_NAME}"
  log_info "Self-update timer is active (${AUTO_UPDATE_INTERVAL})."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --partner-key) PARTNER_KEY="${2:-}"; shift 2 ;;
      --country) COUNTRY="${2:-}"; shift 2 ;;
      --main-server) MAIN_SERVER="${2:-}"; shift 2 ;;
      --binary-url) BINARY_URL="${2:-}"; BINARY_URL_EXPLICIT="true"; shift 2 ;;
      --modem-rotation-method) MODEM_ROTATION_METHOD="${2:-}"; shift 2 ;;
      --hilink-enabled) HILINK_ENABLED="${2:-}"; shift 2 ;;
      --hilink-base-url) HILINK_BASE_URL="${2:-}"; shift 2 ;;
      --hilink-timeout) HILINK_TIMEOUT="${2:-}"; shift 2 ;;
      --doctor-binary-url) DOCTOR_BINARY_URL="${2:-}"; shift 2 ;;
      --threeproxy-package-url) THREEPROXY_PACKAGE_URL="${2:-}"; shift 2 ;;
      --ui-port) UI_PORT="${2:-}"; shift 2 ;;
      --auto-update-enabled) AUTO_UPDATE_ENABLED="${2:-}"; shift 2 ;;
      --auto-update-interval) AUTO_UPDATE_INTERVAL="${2:-}"; shift 2 ;;
      --installer-url) INSTALLER_URL="${2:-}"; shift 2 ;;
      --install-prefix) INSTALL_PREFIX="${2:-}"; shift 2 ;;
      --skip-start) SKIP_START="true"; shift ;;
      --skip-firewall) SKIP_FIREWALL="true"; shift ;;
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
  if ! [[ "${UI_PORT}" =~ ^[0-9]+$ ]] || [[ "${UI_PORT}" -lt 1 || "${UI_PORT}" -gt 65535 ]]; then
    log_err "--ui-port must be a valid TCP port (1..65535)."
    exit 1
  fi
  if [[ "${AUTO_UPDATE_ENABLED}" != "true" && "${AUTO_UPDATE_ENABLED}" != "false" ]]; then
    log_err "--auto-update-enabled must be true or false."
    exit 1
  fi
  if [[ -z "${AUTO_UPDATE_INTERVAL}" ]]; then
    log_err "--auto-update-interval cannot be empty."
    exit 1
  fi
  if [[ -z "${INSTALLER_URL}" ]]; then
    log_err "--installer-url cannot be empty."
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
  harden_secret_permissions
  configure_firewall || true
  write_systemd_unit
  start_service
  write_partner_ui_files
  write_partner_ui_env
  write_partner_ui_systemd_unit
  start_partner_ui_service
  write_install_env
  write_self_update_script
  write_self_update_systemd_units
  start_self_update_timer

  log_info "Installation finished."
  echo
  echo "Useful commands:"
  echo "  systemctl status ${SERVICE_NAME}"
  echo "  systemctl status ${UI_SERVICE_NAME}"
  echo "  systemctl status ${AUTO_UPDATE_TIMER_NAME}"
  echo "  journalctl -u ${SERVICE_NAME} -f"
  echo "  journalctl -u ${UI_SERVICE_NAME} -f"
  echo "  journalctl -u ${AUTO_UPDATE_SERVICE_NAME} -n 100 --no-pager"
  echo "  ${INSTALL_PREFIX}/doctor version || true"
  echo
  echo "Local dashboard URL:"
  echo "  http://127.0.0.1:${UI_PORT}"
}

main "$@"




