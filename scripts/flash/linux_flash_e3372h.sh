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

TOOLS_DIR="/opt/partner-node-flash/tools"
IMAGES_DIR="/opt/partner-node-flash/images"

FLASHBIN="$TOOLS_DIR/balong_flash_recover"
FULL_FW=""
MAIN_FW="${MAIN_FW:-$IMAGES_DIR/E3372h-153_Update_22.200.15.00.00_M_AT_05.10.bin}"
WEBUI_FW="${WEBUI_FW:-$IMAGES_DIR/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin}"

USBLOAD="$TOOLS_DIR/balong-usbload"
USBLSAFE="$TOOLS_DIR/usblsafe-3372h.bin"
PTABLE="$TOOLS_DIR/ptable-hilink.bin"

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

stage() {
  printf 'STAGE:%s\n' "$1"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    command "$@"
  else
    command sudo "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

need_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}

wait_dev_any() {
  local timeout="${1:-25}"
  local i=0
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
  local timeout="${1:-40}"
  local i=0
  while (( i < timeout )); do
    if lsusb | grep -Eq '12d1:(14dc|1f01|1506|1442)'; then
      return 0
    fi
    if ls /dev/ttyUSB* >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    ((i+=1))
  done
  return 1
}

huawei_net_interfaces() {
  local iface
  local dev
  local p

  for iface in $(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' | grep -E '^(enx|usb|eth)' || true); do
    dev="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
    p="$dev"
    while [[ -n "$p" && "$p" != "/" ]]; do
      if [[ -r "$p/idVendor" ]] && grep -qi '^12d1$' "$p/idVendor"; then
        echo "$iface"
        break
      fi
      p="$(dirname "$p")"
    done
  done
}

clean_non_huawei_net_addresses() {
  local iface

  for iface in $(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' | grep -E '^(enx|usb|eth)' || true); do
    if ! huawei_net_interfaces | grep -qx "$iface"; then
      sudo ip addr del 192.168.8.100/24 dev "$iface" 2>/dev/null || true
      sudo ip addr del 192.168.1.100/24 dev "$iface" 2>/dev/null || true
    fi
  done
}

bring_usbnet_up() {
  local iface

  clean_non_huawei_net_addresses
  for iface in $(huawei_net_interfaces); do
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip addr add 192.168.8.100/24 dev "$iface" 2>/dev/null || true
    sudo ip addr add 192.168.1.100/24 dev "$iface" 2>/dev/null || true
  done
}

recover_network() {
  local iface
  local ok=1

  ensure_hilink_mode 20 || true
  bring_usbnet_up
  sleep 3

  for iface in $(huawei_net_interfaces); do
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip addr add 192.168.8.100/24 dev "$iface" 2>/dev/null || true
    sudo ip addr add 192.168.1.100/24 dev "$iface" 2>/dev/null || true
    sudo ip route replace 192.168.8.0/24 dev "$iface" 2>/dev/null || true
    sudo ip route replace 192.168.1.0/24 dev "$iface" 2>/dev/null || true
  done

  sleep 3
  ip -br addr || true
  ip route || true

  ping -c 2 192.168.8.1 >/dev/null 2>&1 && ok=0
  ping -c 2 192.168.1.1 >/dev/null 2>&1 && ok=0

  return $ok
}

ensure_hilink_mode() {
  local timeout="${1:-30}"
  local i=0

  while (( i < timeout )); do
    if lsusb | grep -q '12d1:14dc'; then
      return 0
    fi

    if lsusb | grep -q '12d1:1f01'; then
      log "Found 12d1:1f01, switching to 14dc via usb_modeswitch"
      sudo usb_modeswitch -J -v 0x12d1 -p 0x1f01 || true
    fi

    sleep 2
    ((i+=1))
  done

  lsusb | grep -q '12d1:14dc'
}

wait_adb_on_hilink() {
  local timeout="${1:-40}"
  local i=0

  while (( i < timeout )); do
    bring_usbnet_up
    adb connect 192.168.8.1:5555 >/dev/null 2>&1 || true
    adb connect 192.168.1.1:5555 >/dev/null 2>&1 || true

    if adb devices | grep -qE '192\.168\.(8|1)\.1:5555'; then
      return 0
    fi

    sleep 2
    ((i+=2))
  done

  return 1
}

godload_via_adb() {
  local attempt
  for attempt in 1 2 3 4 5; do
    log "ADB/GODLOAD attempt $attempt"
    bring_usbnet_up

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
    log "Sending AT^GODLOAD to $p"
    echo -e "AT^GODLOAD\r" | sudo tee "$p" >/dev/null || true
    sleep 2
    return 0
  done
  return 1
}

enter_flash_mode() {
  stage "godload"
  log "Trying to enter flash mode without needle"

  if ls /dev/ttyUSB* >/dev/null 2>&1; then
    send_godload_any && return 0
  fi

  if lsusb | grep -q '12d1:1f01'; then
    ensure_hilink_mode 30 || true
  fi

  if lsusb | grep -q '12d1:14dc'; then
    godload_via_adb && return 0
  fi

  if ls /dev/ttyUSB* >/dev/null 2>&1; then
    send_godload_any && return 0
  fi

  return 1
}

choose_flash_port_hilink() {
  local p
  for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
    [[ -e "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

stop_services() {
  stage "stop_services"
  log "Stopping ModemManager"
  sudo systemctl stop ModemManager 2>/dev/null || true
}

start_services() {
  log "Starting ModemManager"
  sudo systemctl start ModemManager 2>/dev/null || true
}

cleanup() {
  start_services
}
trap cleanup EXIT

flash_main_no_needle() {
  local p
  local attempt

  stage "flash_main"
  for attempt in 1 2 3 4 5; do
    log "Main attempt #$attempt"
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      log "Trying main via $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$MAIN_FW"; then
        echo "$p" > /tmp/e3372_last_flash_port
        sleep 2
        return 0
      fi
      sleep 2
    done

    log "Main failed, retrying GODLOAD"
    enter_flash_mode || true
    sleep 4
    wait_dev_any 25 || true
    ls /dev/ttyUSB* 2>/dev/null || true
  done

  return 1
}

flash_webui_no_needle() {
  local p
  local try
  local flash_port="${1:-}"

  stage "flash_webui"
  for ((try=1; try<=7; try++)); do
    log "WebUI attempt #$try"

    if [[ -n "$flash_port" && -e "$flash_port" ]]; then
      log "Trying WebUI via primary port $flash_port"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$flash_port" "$WEBUI_FW"; then
        log "WebUI flashed via $flash_port"
        sleep 3
        return 0
      fi
      sleep 2
    fi

    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      [[ "$p" == "$flash_port" ]] && continue
      log "Trying WebUI via $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
        log "WebUI flashed via $p"
        echo "$p" > /tmp/e3372_last_flash_port
        sleep 3
        return 0
      fi
      sleep 2
    done

    log "WebUI failed, retrying GODLOAD"
    enter_flash_mode || true
    sleep 4
    wait_dev_any 25 || true
    ls /dev/ttyUSB* 2>/dev/null || true

    if flash_port="$(choose_flash_port_hilink 2>/dev/null)"; then
      :
    fi
  done

  return 1
}

wait_post_flash_state() {
  local timeout="${1:-40}"
  local i=0

  while (( i < timeout )); do
    if lsusb | grep -Eq '12d1:(14dc|1f01|1506|1442)'; then
      return 0
    fi
    if ls /dev/ttyUSB* >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    ((i+=1))
  done

  return 1
}

get_live_modem_iface() {
  local iface
  for iface in $(huawei_net_interfaces); do
    if ip link show "$iface" 2>/dev/null | grep -q "LOWER_UP"; then
      echo "$iface"
      return 0
    fi
  done
  return 1
}

wait_live_modem_iface() {
  local timeout="${1:-60}"
  local i=0
  local iface

  while (( i < timeout )); do
    bring_usbnet_up
    if iface="$(get_live_modem_iface 2>/dev/null)"; then
      echo "$iface"
      return 0
    fi
    sleep 2
    ((i+=2))
  done

  return 1
}

adb_at_reset() {
  log "Trying AT^RESET via ADB"

  bring_usbnet_up
  wait_adb_on_hilink 20 || return 1

  adb shell 'echo -e "AT^RESET\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
  adb -s 192.168.8.1:5555 shell 'echo -e "AT^RESET\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
  adb -s 192.168.1.1:5555 shell 'echo -e "AT^RESET\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0

  return 1
}

post_webui_recover() {
  local iface=""

  stage "post_flash"
  log "Waiting for modem to return to HiLink after WebUI"
  wait_post_flash_state 60 || true
  sleep 5

  log "Bringing up temporary network for ADB/API access"
  bring_usbnet_up
  sleep 5

  adb_at_reset || log "ADB reset did not work, continuing"

  log "Waiting for a live modem network interface"
  if iface="$(wait_live_modem_iface 60)"; then
    log "Live modem interface: $iface"
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip route replace 192.168.8.0/24 dev "$iface" 2>/dev/null || true
    sudo ip route replace 192.168.1.0/24 dev "$iface" 2>/dev/null || true
    return 0
  fi

  return 1
}

main() {
  need_cmd lsusb
  need_cmd adb
  need_cmd usb_modeswitch
  need_cmd sudo

  need_file "$FLASHBIN"
  need_file "$MAIN_FW"
  need_file "$WEBUI_FW"
  need_file "$USBLOAD"
  need_file "$USBLSAFE"
  need_file "$PTABLE"

  stop_services

  stage "detect_modem"
  log "Step 1. Waiting for modem in a working state"
  wait_huawei_state 40 || die "modem is not visible as HiLink or ttyUSB"
  lsusb
  ls /dev/ttyUSB* 2>/dev/null || true

  log "Step 2. Entering flash mode without needle"
  enter_flash_mode || die "failed to send AT^GODLOAD; for stock HiLink you may need debug mode"
  sleep 4

  stage "wait_serial"
  log "Step 3. Waiting for ttyUSB after GODLOAD"
  wait_dev_any 30 || die "ttyUSB did not appear after AT^GODLOAD"
  ls /dev/ttyUSB*

  local port
  port="$(choose_flash_port_hilink)" || die "failed to choose flash port"
  log "Flash port: $port"

  if [[ -n "${FULL_FW:-}" ]]; then
    stage "flash_main"
    log "Step 4. Flashing full firmware bundle"
    sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$port" "$FULL_FW"
  else
    log "Step 4. Flashing main"
    flash_main_no_needle || die "main firmware failed without needle"

    port="$(choose_flash_port_hilink)" || true
    log "Step 5. Flashing WebUI with retries"
    flash_webui_no_needle "$port" || die "webui failed without needle"
  fi

  stage "rebooting"
  log "Step 6. Waiting for post-flash modem state"
  wait_post_flash_state 60 || true
  lsusb
  ls /dev/ttyUSB* 2>/dev/null || true

  log "Step 7. Post-processing after WebUI"
  post_webui_recover || log "post-WebUI recovery did not produce a live interface"

  log "Step 8. If the modem is still in flash mode, trying -r"
  port="$(cat /tmp/e3372_last_flash_port 2>/dev/null || true)"
  if [[ -n "${port:-}" && -e "${port:-/dev/null}" ]]; then
    printf 'AT^RESET\r' | sudo tee "$port" >/dev/null || true
    sleep 2
    sudo "$FLASHBIN" -p "$port" -r || true
  fi

  stage "recover_network"
  log "Step 9. Restoring services before network check"
  start_services
  sleep 8

  log "Step 10. Attempting to bring modem network up"
  if recover_network; then
    local live_iface=""
    live_iface="$(get_live_modem_iface 2>/dev/null || true)"
    [[ -n "$live_iface" ]] && log "Working interface: $live_iface"
    stage "verify"
    log "Network is up. Try http://192.168.8.1 and http://192.168.1.1"
  else
    log "Flashing completed, but network did not come up automatically"
    log "Check enx/usb/eth interface manually"
    die "modem network did not come back after flashing"
  fi

  stage "completed"
  if [[ -n "$ORDINAL" ]]; then
    log "Completed. Label this modem as #$ORDINAL for this node"
  else
    log "Completed"
  fi
}

main "$@"
