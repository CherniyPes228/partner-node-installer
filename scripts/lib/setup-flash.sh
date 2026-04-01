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
RECOVERY_IMAGE="${RECOVERY_IMAGE:-${IMAGES_DIR}/E3372h-153_Update_21.329.62.00.209.bin}"
INTERMEDIATE_IMAGE="${INTERMEDIATE_IMAGE:-${IMAGES_DIR}/E3372h-153_Update_21.329.05.00.00_M_01.10_for_.143.bin}"
MAIN_IMAGE="${MAIN_IMAGE:-${IMAGES_DIR}/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin}"
WEBUI_IMAGE="${WEBUI_IMAGE:-${IMAGES_DIR}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin}"
RECOVERY_MAIN_IMAGE_209="${RECOVERY_MAIN_IMAGE_209:-${IMAGES_DIR}/E3372h-153_Update_22.333.63.00.209_to_00.raw.bin}"
RECOVERY_WEBUI_IMAGE_209="${RECOVERY_WEBUI_IMAGE_209:-${IMAGES_DIR}/WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin}"
TARGET_MAIN_VERSION="${TARGET_MAIN_VERSION:-22.333.01.00.00}"
TARGET_WEBUI_VERSION="${TARGET_WEBUI_VERSION:-17.100.13.113.03}"
TARGET_WEBUI_PACKAGE_LABEL="${TARGET_WEBUI_PACKAGE_LABEL:-17.100.13.01.03}"
RECOVERY_TARGET_WEBUI_VERSION_209="${RECOVERY_TARGET_WEBUI_VERSION_209:-17.100.18.03.143}"
FLASH_PREFER_HILINK_LOCAL_UPDATE="${FLASH_PREFER_HILINK_LOCAL_UPDATE:-false}"

find_huawei_pid() {
  lsusb | awk 'tolower($0) ~ /12d1:/ { for (i=1; i<=NF; ++i) if ($i ~ /^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$/) { split(tolower($i), a, ":"); pid=a[2]; if (pid=="1f01" || pid=="14dc" || pid=="1442" || pid=="1506" || pid=="14db" || pid=="1505" || pid=="10c6" || pid=="1c20") { print pid; exit } } }'
}

extract_tag() {
  local tag="${1:-}"
  sed -n "s:.*<${tag}>\\(.*\\)</${tag}>.*:\\1:p" | head -n 1
}

find_hilink_base_url() {
  local candidates=()
  while IFS= read -r addr; do
    [[ -z "${addr}" ]] && continue
    candidates+=("http://${addr}")
  done < <(
    ip -o -4 addr show | awk '
      {
        iface=$2
        split($4, cidr, "/")
        split(cidr[1], octets, ".")
        if ((iface ~ /^(enx|usb|wwan)/) && length(octets) == 4) {
          printf "%s.%s.%s.1\n", octets[1], octets[2], octets[3]
        }
      }' | awk '!seen[$0]++'
  )

  candidates+=(
    "http://192.168.13.1"
    "http://192.168.8.1"
    "http://192.168.3.1"
    "http://192.168.123.1"
    "http://192.168.126.1"
    "http://192.168.1.1"
  )

  local seen=""
  local base
  for base in "${candidates[@]}"; do
    if printf '%s\n' "${seen}" | grep -qxF "${base}"; then
      continue
    fi
    seen="${seen}"$'\n'"${base}"
    if curl -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
      echo "${base}"
      return 0
    fi
  done
  return 1
}

get_hilink_token() {
  local base="${1:-}"
  local cookiejar="${2:-}"
  local page

  page=$(curl -fsS --max-time 10 -c "${cookiejar}" "${base}/html/update_local.html" 2>/dev/null || true)
  if [[ -n "${page}" ]]; then
    local token
    token=$(printf '%s' "${page}" | grep -o 'meta name="csrf_token" content="[^"]*"' | head -n 1 | sed 's/.*content="//; s/"$//')
    if [[ -n "${token}" ]]; then
      printf '%s' "${token}"
      return 0
    fi
  fi

  curl -fsS --max-time 10 -c "${cookiejar}" "${base}/api/webserver/SesTokInfo" 2>/dev/null | extract_tag "TokInfo"
}

wait_for_hilink_ready() {
  local base="${1:-}"
  local timeout="${2:-90}"
  local elapsed=0
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    if curl -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

poll_hilink_update_status() {
  local base="${1:-}"
  local timeout="${2:-240}"
  local elapsed=0
  local xml=""
  local status=""
  local saw_disconnect=0
  local pid=""

  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    xml=$(curl -fsS --max-time 8 "${base}/api/monitoring/check-notifications" 2>/dev/null || true)
    if [[ -z "${xml}" ]]; then
      saw_disconnect=1
      pid="$(find_huawei_pid || true)"
      if [[ "${pid}" == "1c20" ]]; then
        echo "ERROR:modem entered charging mode (12d1:1c20) during local update; replug and retry flashing"
        return 1
      fi
      if wait_for_hilink_ready "${base}" 30; then
        return 0
      fi
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    fi
    status=$(printf '%s' "${xml}" | extract_tag "OnlineUpdateStatus" | tr -d '\r\n\t ')
    case "${status}" in
      20|70|80)
        echo "ERROR:hilink local update failed with status ${status}"
        return 1
        ;;
      51)
        echo "ERROR:hilink local update blocked by low battery"
        return 1
        ;;
      90|100)
        return 0
        ;;
    esac
    if [[ "${saw_disconnect}" == "1" ]] && wait_for_hilink_ready "${base}" 10; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "ERROR:hilink local update timed out"
  return 1
}

upload_hilink_image() {
  local base="${1:-}"
  local image="${2:-}"
  local stage="${3:-upload}"
  local cookiejar
  local token
  local filename
  local response

  cookiejar="$(mktemp)"
  trap 'rm -f "${cookiejar}"' RETURN
  token="$(get_hilink_token "${base}" "${cookiejar}")"
  if [[ -z "${token}" ]]; then
    echo "ERROR:failed to obtain hilink csrf token"
    return 1
  fi

  filename="$(basename "${image}")"
  echo "STAGE:${stage}"
  response="$(curl -fsS --max-time 120 -b "${cookiejar}" -c "${cookiejar}" \
    -F "csrf_token=csrf:${token}" \
    -F "cur_path=OU:${filename}" \
    -F "uploadfile=@${image};filename=${filename}" \
    "${base}/api/filemanager/upload" 2>&1 || true)"
  if ! printf '%s' "${response}" | grep -qi "ok"; then
    echo "ERROR:hilink upload failed for ${filename}: ${response}"
    return 1
  fi

  if ! poll_hilink_update_status "${base}" 300; then
    return 1
  fi
  if ! wait_for_hilink_ready "${base}" 180; then
    echo "ERROR:modem did not return after local update"
    return 1
  fi
  return 0
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

serial_at() {
  local port="${1:-}"
  local command="${2:-}"
  python3 - "$port" "$command" <<'PY'
import os
import select
import sys
import termios
import time

port = sys.argv[1]
command = sys.argv[2] + "\r"
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
try:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    os.write(fd, command.encode("ascii"))
    deadline = time.time() + 2.0
    chunks = []
    while time.time() < deadline:
      readable, _, _ = select.select([fd], [], [], max(0.0, deadline - time.time()))
      if not readable:
        break
      try:
        chunk = os.read(fd, 4096)
      except BlockingIOError:
        continue
      if not chunk:
        break
      chunks.append(chunk)
      if b"OK" in chunk or b"ERROR" in chunk:
        break
    sys.stdout.buffer.write(b"".join(chunks))
finally:
    os.close(fd)
PY
}

find_viewer_port() {
  local port
  for port in /dev/ttyUSB*; do
    [[ -e "${port}" ]] || continue
    if serial_at "${port}" "AT^DLOADVER?" 2>/dev/null | grep -q "2.0"; then
      echo "${port}"
      return 0
    fi
  done
  return 1
}

pick_serial_port() {
  local viewer
  viewer="$(find_viewer_port || true)"
  if [[ -n "${viewer}" ]]; then
    echo "${viewer}"
    return 0
  fi
  wait_for_port "$@"
}

wait_for_port_reconnect() {
  local current="${1:-}"
  local timeout="${2:-90}"
  local elapsed=0
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local first
    first=$(compgen -G "/dev/ttyUSB*" | sort | head -n 1 || true)
    if [[ -n "${first}" && -e "${first}" ]]; then
      local viewer
      viewer="$(find_viewer_port || true)"
      if [[ -n "${viewer}" ]]; then
        echo "${viewer}"
        return 0
      fi
      if ! lsof "${current}" >/dev/null 2>&1; then
        echo "${first}"
        return 0
      fi
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

current_webui_version() {
  local port="${1:-}"
  serial_at "${port}" "AT^VERSION?" 2>/dev/null | sed -n 's/.*\^VERSION:EXTD:\(.*\)$/\1/p' | head -n 1
}

current_main_version() {
  local port="${1:-}"
  serial_at "${port}" "AT^VERSION?" 2>/dev/null | sed -n 's/.*\^VERSION:EXTS:\(.*\)$/\1/p' | head -n 1
}

read_hilink_device_info() {
  local base="${1:-}"
  local cookiejar
  local token
  local xml
  cookiejar="$(mktemp)"
  trap 'rm -f "${cookiejar}"' RETURN
  token="$(get_hilink_token "${base}" "${cookiejar}")"
  if [[ -z "${token}" ]]; then
    return 1
  fi
  xml="$(curl -fsS --max-time 15 \
    -b "${cookiejar}" -c "${cookiejar}" \
    -H "__RequestVerificationToken: ${token}" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "Accept: */*" \
    -H "Origin: ${base}" \
    -H "Referer: ${base}/html/update_local.html" \
    "${base}/api/device/information" 2>/dev/null || true)"
  [[ -n "${xml}" ]] || return 1
  printf '%s' "${xml}"
}

verify_target_versions() {
  local base="${1:-}"
  local expected_webui="${2:-${TARGET_WEBUI_VERSION}}"
  local expected_label="${3:-${TARGET_WEBUI_PACKAGE_LABEL}}"
  local xml
  local fw
  local webui
  xml="$(read_hilink_device_info "${base}")" || {
    echo "ERROR:failed to read device information from ${base}"
    return 1
  }
  fw="$(printf '%s' "${xml}" | extract_tag "SoftwareVersion" | tr -d '\r\n\t ')"
  webui="$(printf '%s' "${xml}" | extract_tag "WebUIVersion" | tr -d '\r\n\t ')"
  echo "firmware=${fw}"
  echo "webui=${webui}"
  [[ "${fw}" == "${TARGET_MAIN_VERSION}"* ]] || {
    echo "ERROR:unexpected firmware version ${fw}, expected ${TARGET_MAIN_VERSION}"
    return 1
  }
  [[ "${webui}" == "${expected_webui}"* || "${webui}" == *"${expected_label}"* ]] || {
    echo "ERROR:unexpected webui version ${webui}, expected ${expected_webui} (${expected_label})"
    return 1
  }
}

reset_userdata_via_telnet() {
  local base="${1:-}"
  local host="${base#http://}"
  host="${host%%/*}"
  [[ -n "${host}" ]] || return 1
  echo "STAGE:reset_userdata"
  {
    printf 'mount -o remount,rw /data\n'
    printf 'rm -rf /data/userdata/* /data/userdata1/* /data/dontpanic/* 2>/dev/null\n'
    printf 'sync\n'
    printf 'reboot\n'
  } | nc "${host}" 23 >/dev/null 2>&1 || return 1
  return 0
}

switch_to_hilink_composition() {
  local port="${1:-}"
  [[ -n "${port}" && -e "${port}" ]] || return 1
  echo "STAGE:switch_to_hilink"
  serial_at "${port}" 'AT^SETPORT="FF;10,12,16,A2"' >/dev/null 2>&1 || return 1
  sleep 2
  return 0
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
    1f01|14dc|1442|1506|14db|1505|10c6|1c20)
      echo "STAGE:mode_switch"
      usb_modeswitch -v 0x12d1 -p "0x${pid}" -J >/dev/null 2>&1 || true
      sleep 4
      ;;
  esac
}

maybe_bind_option_driver() {
  local pid="${1:-}"
  if [[ "${pid}" != "14dc" ]]; then
    return 0
  fi
  if [[ ! -w /sys/bus/usb-serial/drivers/option1/new_id ]]; then
    return 0
  fi
  modprobe option >/dev/null 2>&1 || true
  echo "STAGE:bind_option_driver"
  echo "12d1 14dc" > /sys/bus/usb-serial/drivers/option1/new_id 2>/dev/null || true
  sleep 3
}

echo "STAGE:precheck"
for f in "$BALONG_USBLOAD" "$BALONG_FLASH" "$USBLOADER" "$USBLSAFE" "$RECOVERY_IMAGE" "$INTERMEDIATE_IMAGE" "$MAIN_IMAGE" "$WEBUI_IMAGE" "$RECOVERY_MAIN_IMAGE_209" "$RECOVERY_WEBUI_IMAGE_209"; do
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
  maybe_bind_option_driver "${PID}"
  PORT="$(pick_serial_port 10 || true)"
fi

if [[ "${FLASH_PREFER_HILINK_LOCAL_UPDATE}" == "true" && ! -e "$PORT" ]]; then
  PID="$(find_huawei_pid || true)"
  HILINK_BASE="$(find_hilink_base_url || true)"
  if [[ -n "${HILINK_BASE}" ]]; then
    if curl -fsS --max-time 10 "${HILINK_BASE}/html/update_local.html" >/dev/null 2>&1; then
      echo "STAGE:hilink_local_update"
      upload_hilink_image "${HILINK_BASE}" "${INTERMEDIATE_IMAGE}" "flash_intermediate" || exit 4
      upload_hilink_image "${HILINK_BASE}" "${MAIN_IMAGE}" "flash_main" || exit 4
      upload_hilink_image "${HILINK_BASE}" "${WEBUI_IMAGE}" "flash_webui" || exit 4
      echo "STAGE:verify"
      echo "modem_id=${MODEM_ID} ordinal=${ORDINAL} mode=hilink base=${HILINK_BASE}"
      echo "STAGE:completed"
      exit 0
    fi
  fi
fi

if [[ ! -e "$PORT" ]]; then
  PID="$(find_huawei_pid || true)"
  if [[ -z "${PID}" ]]; then
    echo "ERROR:supported Huawei E3372h-153 device was not detected on USB"
    exit 3
  fi
  maybe_switch_mode "${PID}"
  PORT="$(pick_serial_port 30 || true)"
  if [[ -z "${PORT}" || ! -e "${PORT}" ]]; then
    PID_AFTER="$(find_huawei_pid || true)"
    if [[ "${PID_AFTER}" == "1c20" ]]; then
      echo "ERROR:modem is stuck in charging mode (12d1:1c20); replug the modem and retry flashing"
      exit 4
    fi
    echo "ERROR:flash serial port not found after mode switch"
    exit 3
  fi
fi

echo "STAGE:usbload"
"$BALONG_USBLOAD" -p "$PORT" "$USBLOADER"
echo "STAGE:safe_loader"
"$BALONG_FLASH" -p "$PORT" "$USBLSAFE"
echo "STAGE:flash_recovery"
"$BALONG_FLASH" -p "$PORT" "$RECOVERY_IMAGE"
echo "STAGE:wait_reconnect_after_recovery"
PORT="$(wait_for_port_reconnect "$PORT" 120 || true)"
if [[ -z "${PORT}" || ! -e "${PORT}" ]]; then
  echo "ERROR:flash serial port not found after recovery firmware reboot"
  exit 5
fi
CURRENT_MAIN="$(current_main_version "$PORT" | tr -d '\r\n\t ')"
USE_209_RECOVERY_CHAIN=false
if [[ "${CURRENT_MAIN}" == 21.329.62.00.209* ]]; then
  USE_209_RECOVERY_CHAIN=true
fi
if [[ "${USE_209_RECOVERY_CHAIN}" == "true" ]]; then
  echo "STAGE:flash_main_209"
  "$BALONG_FLASH" -p "$PORT" "$RECOVERY_MAIN_IMAGE_209"
else
  echo "STAGE:flash_intermediate"
  "$BALONG_FLASH" -p "$PORT" "$INTERMEDIATE_IMAGE"
  echo "STAGE:wait_reconnect_after_intermediate"
  PORT="$(wait_for_port_reconnect "$PORT" 120 || true)"
  if [[ -z "${PORT}" || ! -e "${PORT}" ]]; then
    echo "ERROR:flash serial port not found after intermediate reboot"
    exit 5
  fi
  echo "STAGE:flash_main"
  "$BALONG_FLASH" -p "$PORT" "$MAIN_IMAGE"
fi
echo "STAGE:wait_reconnect_after_main"
PORT="$(wait_for_port_reconnect "$PORT" 120 || true)"
if [[ -z "${PORT}" || ! -e "${PORT}" ]]; then
  echo "ERROR:flash serial port not found after main firmware reboot"
  exit 5
fi
if [[ "${USE_209_RECOVERY_CHAIN}" == "true" ]]; then
  echo "STAGE:flash_webui_209"
  "$BALONG_FLASH" -p "$PORT" "$RECOVERY_WEBUI_IMAGE_209"
else
  echo "STAGE:flash_webui"
  "$BALONG_FLASH" -p "$PORT" "$WEBUI_IMAGE"
fi
PORT="$(wait_for_port_reconnect "$PORT" 90 || true)"
if [[ -n "${PORT}" && -e "${PORT}" ]]; then
  switch_to_hilink_composition "$PORT" || true
fi
HILINK_BASE="$(find_hilink_base_url || true)"
if [[ -z "${HILINK_BASE}" ]] || ! wait_for_hilink_ready "${HILINK_BASE}" 120; then
  echo "ERROR:hilink api did not return after webui flash"
  exit 6
fi
if reset_userdata_via_telnet "${HILINK_BASE}"; then
  sleep 8
  if ! wait_for_hilink_ready "${HILINK_BASE}" 180; then
    HILINK_BASE="$(find_hilink_base_url || true)"
    if [[ -z "${HILINK_BASE}" ]] || ! wait_for_hilink_ready "${HILINK_BASE}" 180; then
      echo "ERROR:modem did not return after userdata reset"
      exit 6
    fi
  fi
fi
echo "STAGE:verify"
if [[ "${USE_209_RECOVERY_CHAIN}" == "true" ]]; then
  verify_target_versions "${HILINK_BASE}" "${RECOVERY_TARGET_WEBUI_VERSION_209}" "${RECOVERY_TARGET_WEBUI_VERSION_209}" || exit 7
else
  verify_target_versions "${HILINK_BASE}" || exit 7
fi
echo "modem_id=${MODEM_ID} ordinal=${ORDINAL} port=${PORT} base=${HILINK_BASE}"
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
  download_asset "${FLASH_ASSETS_BASE_URL}/E3372h-153_Update_21.329.62.00.209.bin" "${images_dir}/E3372h-153_Update_21.329.62.00.209.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/E3372h-153_Update_21.329.05.00.00_M_01.10_for_.143.bin" "${images_dir}/E3372h-153_Update_21.329.05.00.00_M_01.10_for_.143.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin" "${images_dir}/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin" "${images_dir}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/E3372h-153_Update_22.333.63.00.209_to_00.raw.bin" "${images_dir}/E3372h-153_Update_22.333.63.00.209_to_00.raw.bin"
  download_asset "${FLASH_ASSETS_BASE_URL}/WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin" "${images_dir}/WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin"

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
