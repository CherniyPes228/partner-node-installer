#!/usr/bin/env bash
set -euo pipefail

# Live E3372h flasher used by the partner UI. This is intentionally not a
# needle-recovery script: support runs needle recovery manually over SSH.

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

FLASHBIN="${FLASHBIN:-${TOOLS_DIR}/balong_flash_recover}"
MAIN_FW="${MAIN_FW:-${IMAGES_DIR}/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin}"
WEBUI_FW="${WEBUI_FW:-${IMAGES_DIR}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin}"
FULL_FW="${FULL_FW:-}"

TARGET_MAIN_VERSION="${TARGET_MAIN_VERSION:-22.333.01.00.00}"
TARGET_WEBUI_VERSION="${TARGET_WEBUI_VERSION:-17.100.13.113.03}"
TARGET_WEBUI_PACKAGE_LABEL="${TARGET_WEBUI_PACKAGE_LABEL:-17.100.13.01.03}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
stage() { printf 'STAGE:%s\n' "$1"; }
die() { printf 'ERROR:%s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_file() { [[ -f "$1" ]] || die "missing file: $1"; }

stop_services() {
  stage "stop_services"
  sudo systemctl stop ModemManager 2>/dev/null || true
  sudo systemctl stop NetworkManager 2>/dev/null || true
}

start_services() {
  sudo systemctl start NetworkManager 2>/dev/null || true
  sudo systemctl start ModemManager 2>/dev/null || true
}
trap start_services EXIT

wait_dev_any() {
  local timeout="${1:-30}" i=0
  while (( i < timeout )); do
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] && return 0
    done
    sleep 1
    ((i+=1))
  done
  return 1
}

wait_huawei_state() {
  local timeout="${1:-45}" i=0
  while (( i < timeout )); do
    if lsusb | grep -Eq '12d1:(14dc|1f01|1506|1442)'; then
      return 0
    fi
    if compgen -G "/dev/ttyUSB*" >/dev/null; then
      return 0
    fi
    sleep 1
    ((i+=1))
  done
  return 1
}

bring_usbnet_up() {
  local iface
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip addr add 192.168.8.100/24 dev "$iface" 2>/dev/null || true
    sudo ip addr add 192.168.1.100/24 dev "$iface" 2>/dev/null || true
  done < <(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' | grep -E '^(enx|usb|wwan|eth)' || true)
}

recover_network() {
  local iface ok=1
  stage "recover_network"
  bring_usbnet_up
  sleep 2
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip route replace 192.168.8.0/24 dev "$iface" 2>/dev/null || true
    sudo ip route replace 192.168.1.0/24 dev "$iface" 2>/dev/null || true
  done < <(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' | grep -E '^(enx|usb|wwan|eth)' || true)
  ping -c 2 192.168.8.1 >/dev/null 2>&1 && ok=0
  ping -c 2 192.168.1.1 >/dev/null 2>&1 && ok=0
  return "$ok"
}

ensure_hilink_mode() {
  local timeout="${1:-30}" i=0
  while (( i < timeout )); do
    lsusb | grep -q '12d1:14dc' && return 0
    if lsusb | grep -q '12d1:1f01'; then
      sudo usb_modeswitch -J -v 0x12d1 -p 0x1f01 || true
    fi
    sleep 2
    ((i+=2))
  done
  lsusb | grep -q '12d1:14dc'
}

wait_adb_on_hilink() {
  local timeout="${1:-40}" i=0
  local host
  while (( i < timeout )); do
    bring_usbnet_up
    for host in 192.168.8.1 192.168.1.1; do
      if curl -fsS --max-time 2 "http://${host}/api/webserver/SesTokInfo" >/dev/null 2>&1 || ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
        timeout 4 adb connect "${host}:5555" >/dev/null 2>&1 || true
      fi
    done
    adb devices | grep -qE '192\.168\.(8|1)\.1:5555' && return 0
    sleep 2
    ((i+=2))
  done
  return 1
}

godload_via_adb() {
  local attempt
  for attempt in 1 2 3 4 5; do
    log "ADB/GODLOAD attempt ${attempt}"
    if wait_adb_on_hilink 20; then
      adb shell 'echo -e "AT^GODLOAD\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
      adb -s 192.168.8.1:5555 shell 'echo -e "AT^GODLOAD\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
      adb -s 192.168.1.1:5555 shell 'echo -e "AT^GODLOAD\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
    fi
    sleep 3
  done
  return 1
}

send_godload_any() {
  local p
  for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
    [[ -e "$p" ]] || continue
    log "sending AT^GODLOAD to ${p}"
    printf 'AT^GODLOAD\r' | sudo tee "$p" >/dev/null || true
    sleep 2
    return 0
  done
  return 1
}

enter_flash_mode() {
  stage "godload"
  if compgen -G "/dev/ttyUSB*" >/dev/null; then
    send_godload_any && return 0
  fi
  if lsusb | grep -q '12d1:1f01'; then
    ensure_hilink_mode 30 || true
  fi
  if lsusb | grep -q '12d1:14dc'; then
    godload_via_adb && return 0
  fi
  if compgen -G "/dev/ttyUSB*" >/dev/null; then
    send_godload_any && return 0
  fi
  return 1
}

choose_flash_port() {
  for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
    [[ -e "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

flash_main_no_needle() {
  local p attempt
  for attempt in 1 2 3; do
    log "main firmware attempt ${attempt}"
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      log "trying main through ${p}"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -k -p "$p" "$MAIN_FW"; then
        printf '%s\n' "$p" > /tmp/e3372_last_flash_port
        return 0
      fi
      sleep 1
    done
    enter_flash_mode || true
    sleep 2
    wait_dev_any 20 || true
  done
  return 1
}

flash_webui_no_needle() {
  local p try flash_port="${1:-}"
  for ((try=1; try<=5; try++)); do
    log "WebUI attempt ${try}"
    if [[ -n "$flash_port" && -e "$flash_port" ]]; then
      log "trying WebUI through primary port ${flash_port}"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$flash_port" "$WEBUI_FW"; then
        return 0
      fi
      sleep 1
    fi
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" && "$p" != "$flash_port" ]] || continue
      log "trying WebUI through ${p}"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
        return 0
      fi
      sleep 1
    done
    enter_flash_mode || true
    sleep 3
    wait_dev_any 20 || true
  done
  return 1
}

find_hilink_base_url() {
  for base in http://192.168.8.1 http://192.168.1.1; do
    if curl -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
      echo "$base"
      return 0
    fi
  done
  return 1
}

extract_tag() {
  local tag="${1:-}"
  sed -n "s:.*<${tag}>\\(.*\\)</${tag}>.*:\\1:p" | head -n 1
}

verify_target_versions() {
  local base="${1:-}" xml fw webui
  stage "verify"
  xml="$(curl -fsS --max-time 15 "${base}/api/device/information" 2>/dev/null || true)"
  [[ -n "$xml" ]] || { log "device information unavailable after flash"; return 0; }
  fw="$(printf '%s' "$xml" | extract_tag "SoftwareVersion" | tr -d '\r\n\t ')"
  webui="$(printf '%s' "$xml" | extract_tag "WebUIVersion" | tr -d '\r\n\t ')"
  log "firmware=${fw} webui=${webui}"
  [[ "$fw" == "$TARGET_MAIN_VERSION"* ]] || die "unexpected firmware version ${fw}, expected ${TARGET_MAIN_VERSION}"
  [[ "$webui" == "$TARGET_WEBUI_VERSION"* || "$webui" == *"$TARGET_WEBUI_PACKAGE_LABEL"* ]] || die "unexpected webui version ${webui}, expected ${TARGET_WEBUI_VERSION}"
}

main() {
  stage "precheck"
  need_cmd lsusb
  need_cmd adb
  need_cmd usb_modeswitch
  need_cmd sudo
  need_file "$FLASHBIN"
  [[ -n "$FULL_FW" ]] || need_file "$MAIN_FW"
  [[ -n "$FULL_FW" ]] || need_file "$WEBUI_FW"
  [[ -z "$FULL_FW" ]] || need_file "$FULL_FW"

  stop_services

  stage "detect_modem"
  wait_huawei_state 45 || die "Huawei E3372h modem is not visible as HiLink or ttyUSB"
  lsusb || true
  ls /dev/ttyUSB* 2>/dev/null || true

  enter_flash_mode || die "failed to enter firmware flashing mode without needle"
  sleep 4

  stage "wait_serial"
  wait_dev_any 35 || die "ttyUSB port did not appear after AT^GODLOAD"
  ls /dev/ttyUSB* 2>/dev/null || true

  local port
  port="$(choose_flash_port)" || die "failed to choose flash port"
  log "flash port: ${port}"

  if [[ -n "$FULL_FW" ]]; then
    stage "flash_full"
    sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$port" "$FULL_FW"
  else
    stage "flash_main"
    flash_main_no_needle || die "main firmware flash failed"
    port="$(choose_flash_port || true)"
    stage "flash_webui"
    flash_webui_no_needle "$port" || die "WebUI flash failed"
  fi

  stage "flash_reboot"
  if [[ -n "${port:-}" && -e "${port:-/dev/null}" ]]; then
    sudo "$FLASHBIN" -p "$port" -r || true
  fi

  start_services
  sleep 5
  recover_network || true

  local base
  base="$(find_hilink_base_url || true)"
  if [[ -n "$base" ]]; then
    verify_target_versions "$base"
  else
    stage "verify"
    log "HiLink API not reachable yet; flash commands completed"
  fi

  echo "modem_id=${MODEM_ID} ordinal=${ORDINAL} base=${base:-unknown}"
  stage "completed"
}

main "$@"
