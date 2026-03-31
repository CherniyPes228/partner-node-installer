#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Setup safe modem flashing assets for E3372h-153
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MODEM_FLASH_ENABLED="${MODEM_FLASH_ENABLED:-true}"
FLASH_ASSETS_BASE_URL="${FLASH_ASSETS_BASE_URL:-https://chatmod.warforgalaxy.com/downloads/partner-node/flash}"
FLASH_ROOT="${FLASH_ROOT:-/opt/partner-node-flash}"
FLASH_SCRIPT_PATH="${MODEM_FLASH_SCRIPT_PATH:-/usr/local/sbin/partner-node-flash-e3372h.sh}"

write_flash_script() {
  cat > "${FLASH_SCRIPT_PATH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODEM_ID=""
ORDINAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modem-id) MODEM_ID="${2:-}"; shift 2 ;;
    --ordinal) ORDINAL="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

FLASH_ROOT="${FLASH_ROOT:-/opt/partner-node-flash}"
TOOLS_DIR="${TOOLS_DIR:-${FLASH_ROOT}/tools}"
IMAGES_DIR="${IMAGES_DIR:-${FLASH_ROOT}/images}"
PORT="${FLASH_PORT:-/dev/ttyUSB0}"

BALONG_USBLOAD="${BALONG_USBLOAD:-${TOOLS_DIR}/balong-usbload}"
BALONG_FLASH="${BALONG_FLASH:-${TOOLS_DIR}/balong_flash}"
USBLOADER="${USBLOADER:-${TOOLS_DIR}/usbloader-3372h.bin}"
USBLSAFE="${USBLSAFE:-${TOOLS_DIR}/usblsafe-3372h.bin}"
INTERMEDIATE_IMAGE="${INTERMEDIATE_IMAGE:-${IMAGES_DIR}/E3372h-153_Update_21.329.05.00.00_M_01.10_for_.143.bin}"
MAIN_IMAGE="${MAIN_IMAGE:-${IMAGES_DIR}/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin}"
WEBUI_IMAGE="${WEBUI_IMAGE:-${IMAGES_DIR}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin}"

find_huawei_pid() {
  lsusb | awk 'tolower($0) ~ /12d1:/ && toupper($0) ~ /E3372/ { for (i=1; i<=NF; ++i) if ($i ~ /^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$/) { split(tolower($i), a, ":"); print a[2]; exit } }'
}

wait_for_port() {
  local timeout="${1:-30}"
  local elapsed=0
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local first
    first=$(compgen -G "/dev/ttyUSB*" | sort | head -n 1 || true)
    if [[ -n "${first}" && -e "${first}" ]]; then
      echo "${first}"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

maybe_switch_mode() {
  local pid="${1:-}"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  if ! command -v usb_modeswitch >/dev/null 2>&1; then
    return 0
  fi

  case "${pid}" in
    1f01|14dc|1506|14db|1505|10c6)
      echo "STAGE:mode_switch"
      usb_modeswitch -v 0x12d1 -p "0x${pid}" -J >/dev/null 2>&1 || true
      sleep 4
      ;;
  esac
}

echo "STAGE:precheck"
for f in "$BALONG_USBLOAD" "$BALONG_FLASH" "$USBLOADER" "$USBLSAFE" "$INTERMEDIATE_IMAGE" "$MAIN_IMAGE" "$WEBUI_IMAGE"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR:missing file $f"
    exit 2
  fi
done
if [[ ! -e "$PORT" ]]; then
  PID="$(find_huawei_pid || true)"
  if [[ -z "${PID}" ]]; then
    echo "ERROR:supported Huawei E3372h-153 device was not detected on USB"
    exit 3
  fi
  maybe_switch_mode "${PID}"
  PORT="$(wait_for_port 30 || true)"
  if [[ -z "${PORT}" || ! -e "${PORT}" ]]; then
    echo "ERROR:flash serial port not found after mode switch"
    exit 3
  fi
fi

echo "STAGE:usbload"
"$BALONG_USBLOAD" -p "$PORT" "$USBLOADER"
echo "STAGE:safe_loader"
"$BALONG_FLASH" -p "$PORT" "$USBLSAFE"
echo "STAGE:flash_intermediate"
"$BALONG_FLASH" -p "$PORT" "$INTERMEDIATE_IMAGE"
echo "STAGE:flash_main"
"$BALONG_FLASH" -p "$PORT" "$MAIN_IMAGE"
echo "STAGE:flash_webui"
"$BALONG_FLASH" -p "$PORT" "$WEBUI_IMAGE"
echo "STAGE:verify"
echo "modem_id=${MODEM_ID} ordinal=${ORDINAL} port=${PORT}"
echo "STAGE:completed"
EOF
  chmod 0755 "${FLASH_SCRIPT_PATH}"
}

download_asset() {
  local url="$1"
  local out="$2"
  curl -fsSL "${url}" -o "${out}"
}

setup_flash() {
  require_root

  if [[ "${MODEM_FLASH_ENABLED}" != "true" ]]; then
    log_warn "Modem flash support is disabled"
    return 0
  fi

  if [[ -z "${FLASH_ASSETS_BASE_URL}" ]]; then
    log_warn "FLASH_ASSETS_BASE_URL is empty, skipping flash setup"
    return 0
  fi

  local tools_dir images_dir
  tools_dir="${FLASH_ROOT}/tools"
  images_dir="${FLASH_ROOT}/images"
  mkdir -p "${tools_dir}" "${images_dir}" "$(dirname "${FLASH_SCRIPT_PATH}")"

  log_info "Downloading safe flash assets from ${FLASH_ASSETS_BASE_URL}"
  download_asset "${FLASH_ASSETS_BASE_URL}/balong-usbload" "${tools_dir}/balong-usbload"
  download_asset "${FLASH_ASSETS_BASE_URL}/balong_flash" "${tools_dir}/balong_flash"
  download_asset "${FLASH_ASSETS_BASE_URL}/usbloader-3372h.bin" "${tools_dir}/usbloader-3372h.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/usblsafe-3372h.bin" "${tools_dir}/usblsafe-3372h.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/E3372h-153_Update_21.329.05.00.00_M_01.10_for_.143.bin" "${images_dir}/E3372h-153_Update_21.329.05.00.00_M_01.10_for_.143.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin" "${images_dir}/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin" "${images_dir}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin"

  chmod 0755 "${tools_dir}/balong-usbload" "${tools_dir}/balong_flash" || true
  chmod 0644 "${tools_dir}/usbloader-3372h.bin" "${tools_dir}/usblsafe-3372h.bin" || true
  chmod 0644 "${images_dir}/"*.bin || true
  write_flash_script
  log_info "Safe flash assets are installed into ${FLASH_ROOT}"
  log_info "✅ Flash setup complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_flash "$@"
fi
