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

# Р вЂ™Р В°РЎР‚Р С‘Р В°Р Р…РЎвЂљ 2: РЎР‚Р В°Р В·Р Т‘Р ВµР В»РЎРЉР Р…Р С• main + webui
MAIN_FW="${MAIN_FW:-$IMAGES_DIR/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin}"
WEBUI_FW="${WEBUI_FW:-}"
if [[ -z "$WEBUI_FW" ]]; then
  if [[ -f "$IMAGES_DIR/WEBUI_17.100.18.03.143_HILINK_Mod1.21_E3372h-153.bin" ]]; then
    WEBUI_FW="$IMAGES_DIR/WEBUI_17.100.18.03.143_HILINK_Mod1.21_E3372h-153.bin"
  elif [[ -f "$IMAGES_DIR/WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin" ]]; then
    WEBUI_FW="$IMAGES_DIR/WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin"
  else
    WEBUI_FW="$IMAGES_DIR/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin"
  fi
fi

USBLOAD="$TOOLS_DIR/balong-usbload"
USBLSAFE="$TOOLS_DIR/usblsafe-3372h.bin"
PTABLE="$TOOLS_DIR/ptable-hilink.bin"

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}


stage() {
  printf 'STAGE:%s\n' "$1"
}

sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    command "$@"
  else
    command sudo "$@"
  fi
}
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Р СњР Вµ Р Р…Р В°Р в„–Р Т‘Р ВµР Р…Р В° Р С”Р С•Р СР В°Р Р…Р Т‘Р В°: $1"
}

need_file() {
  [[ -f "$1" ]] || die "Р СњР Вµ Р Р…Р В°Р в„–Р Т‘Р ВµР Р… РЎвЂћР В°Р в„–Р В»: $1"
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

bring_usbnet_up() {
  local iface
  clean_non_huawei_net_addresses
  for iface in $(huawei_net_interfaces); do
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip addr add 192.168.8.100/24 dev "$iface" 2>/dev/null || true
    sudo ip addr add 192.168.1.100/24 dev "$iface" 2>/dev/null || true
  done
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

recover_network() {
  local iface
  local ok=1

  bring_usbnet_up
  sleep 2

  for iface in $(huawei_net_interfaces); do
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip route replace 192.168.8.0/24 dev "$iface" 2>/dev/null || true
    sudo ip route replace 192.168.1.0/24 dev "$iface" 2>/dev/null || true
  done

  ip -br addr || true
  ip route || true

  curl -fsS --max-time 5 http://192.168.8.1/api/webserver/SesTokInfo >/dev/null 2>&1 && ok=0
  curl -fsS --max-time 5 http://192.168.1.1/api/webserver/SesTokInfo >/dev/null 2>&1 && ok=0

  return $ok
}

wait_hilink_webui() {
  local timeout="${1:-120}"
  local i=0
  local iface
  local carrier
  local oper

  while (( i < timeout )); do
    bring_usbnet_up

    if lsusb | grep -q '12d1:14dc'; then
      for iface in $(huawei_net_interfaces); do
        carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)"
        oper="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo down)"
        log "HiLink check: $iface carrier=$carrier oper=$oper"
      done

      if ping -c 1 -W 2 192.168.8.1 >/dev/null 2>&1 &&
        curl -fsS --max-time 5 http://192.168.8.1/api/webserver/SesTokInfo >/dev/null 2>&1; then
        return 0
      fi

      if ping -c 1 -W 2 192.168.1.1 >/dev/null 2>&1 &&
        curl -fsS --max-time 5 http://192.168.1.1/api/webserver/SesTokInfo >/dev/null 2>&1; then
        return 0
      fi
    fi

    sleep 5
    ((i+=5))
  done

  return 1
}

ensure_hilink_mode() {
  local timeout="${1:-30}"
  local i=0

  while (( i < timeout )); do
    if lsusb | grep -q '12d1:14dc'; then
      return 0
    fi

    if lsusb | grep -q '12d1:1f01'; then
      log "Р вЂ™Р С‘Р В¶РЎС“ 12d1:1f01, Р С—Р ВµРЎР‚Р ВµР С”Р В»РЎР‹РЎвЂЎР В°РЎР‹ Р Р† 14dc РЎвЂЎР ВµРЎР‚Р ВµР В· usb_modeswitch"
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
    log "ADB/GODLOAD Р С—Р С•Р С—РЎвЂ№РЎвЂљР С”Р В° #$attempt"
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
    log "Р С›РЎвЂљР С—РЎР‚Р В°Р Р†Р В»РЎРЏРЎР‹ AT^GODLOAD Р Р† $p"
    echo -e "AT^GODLOAD\r" | sudo tee "$p" >/dev/null || true
    sleep 2
    return 0
  done
  return 1
}

enter_flash_mode() {
  log "Р СџРЎР‚Р С•Р В±РЎС“РЎР‹ Р Р†Р С•Р в„–РЎвЂљР С‘ Р Р† РЎР‚Р ВµР В¶Р С‘Р С Р С—РЎР‚Р С•РЎв‚¬Р С‘Р Р†Р С”Р С‘ Р В±Р ВµР В· Р С‘Р С–Р В»РЎвЂ№"

  # Р вЂўРЎРѓР В»Р С‘ РЎС“Р В¶Р Вµ Р ВµРЎРѓРЎвЂљРЎРЉ ttyUSB, Р С—РЎР‚Р С•Р В±РЎС“Р ВµР С AT-Р С—Р С•РЎР‚РЎвЂљ
  if ls /dev/ttyUSB* >/dev/null 2>&1; then
    send_godload_any && return 0
  fi

  # Р вЂўРЎРѓР В»Р С‘ РЎС“РЎРѓРЎвЂљРЎР‚Р С•Р в„–РЎРѓРЎвЂљР Р†Р С• Р Р† 1f01, Р С—Р ВµРЎР‚Р ВµР Р†Р С•Р Т‘Р С‘Р С Р Р† 14dc
  if lsusb | grep -q '12d1:1f01'; then
    ensure_hilink_mode 30 || true
  fi

  # Р вЂўРЎРѓР В»Р С‘ РЎС“Р В¶Р Вµ HiLink, Р С—РЎР‚Р С•Р В±РЎС“Р ВµР С ADB
  if lsusb | grep -q '12d1:14dc'; then
    godload_via_adb && return 0
  fi

  # Р СџР С•Р Р†РЎвЂљР С•РЎР‚Р Р…Р В°РЎРЏ Р С—Р С•Р С—РЎвЂ№РЎвЂљР С”Р В° РЎвЂЎР ВµРЎР‚Р ВµР В· ttyUSB, Р ВµРЎРѓР В»Р С‘ Р С—Р С•РЎР‚РЎвЂљ Р С—Р С•РЎРЏР Р†Р С‘Р В»РЎРѓРЎРЏ
  if ls /dev/ttyUSB* >/dev/null 2>&1; then
    send_godload_any && return 0
  fi

  return 1
}

choose_flash_port_hilink() {
  for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
    [[ -e "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

stop_services() {
  log "Р С›РЎРѓРЎвЂљР В°Р Р…Р В°Р Р†Р В»Р С‘Р Р†Р В°РЎР‹ ModemManager Р С‘ NetworkManager"
  sudo systemctl stop ModemManager 2>/dev/null || true
  sudo systemctl stop NetworkManager 2>/dev/null || true
}

start_services() {
  log "Р вЂ™Р С•Р В·Р Р†РЎР‚Р В°РЎвЂ°Р В°РЎР‹ NetworkManager Р С‘ ModemManager"
  sudo systemctl start NetworkManager 2>/dev/null || true
  sudo systemctl start ModemManager 2>/dev/null || true
}

cleanup() {
  start_services
}
trap cleanup EXIT

flash_main_no_needle() {
  local p
  local attempt

  for attempt in 1 2 3; do
    log "Р СџР С•Р С—РЎвЂ№РЎвЂљР С”Р В° main #$attempt"

    # 1. Р ВµРЎРѓР В»Р С‘ РЎС“Р В¶Р Вµ Р ВµРЎРѓРЎвЂљРЎРЉ ttyUSB, Р С—РЎР‚Р С•Р В±РЎС“Р ВµР С Р Р…Р В°Р С—РЎР‚РЎРЏР СРЎС“РЎР‹
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      log "Р СџРЎР‚Р С•Р В±РЎС“РЎР‹ main РЎРѓ -k РЎвЂЎР ВµРЎР‚Р ВµР В· $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -k -p "$p" "$MAIN_FW"; then
        echo "$p" > /tmp/e3372_last_flash_port
        return 0
      fi
      sleep 1
    done

    # 2. Р ВµРЎРѓР В»Р С‘ Р Р…Р Вµ Р Р†РЎвЂ№РЎв‚¬Р В»Р С•, Р ВµРЎвЂ°РЎвЂ РЎР‚Р В°Р В· Р Р† GODLOAD
    log "Main Р Р…Р Вµ Р В·Р В°РЎв‚¬Р В»Р В°, Р С—Р С•Р Р†РЎвЂљР С•РЎР‚РЎРЏРЎР‹ GODLOAD"
    enter_flash_mode || true
    sleep 2
    wait_dev_any 20 || true
    ls /dev/ttyUSB* 2>/dev/null || true
  done

  return 1
}

flash_webui_no_needle() {
  local p
  local try
  local flash_port="${1:-}"

  for ((try=1; try<=5; try++)); do
    log "Р СџР С•Р С—РЎвЂ№РЎвЂљР С”Р В° WebUI #$try"

    # 1. Р РЋР Р…Р В°РЎвЂЎР В°Р В»Р В° Р С—РЎР‚Р С•Р В±РЎС“Р ВµР С РЎвЂљР ВµР С Р В¶Р Вµ Р С—Р С•РЎР‚РЎвЂљР С•Р С, Р С”Р С•РЎвЂљР С•РЎР‚РЎвЂ№Р С Р В·Р В°РЎв‚¬Р В»Р В° main
    if [[ -n "$flash_port" && -e "$flash_port" ]]; then
      log "Р СџРЎР‚Р С•Р В±РЎС“РЎР‹ WebUI РЎвЂЎР ВµРЎР‚Р ВµР В· Р С•РЎРѓР Р…Р С•Р Р†Р Р…Р С•Р в„– Р С—Р С•РЎР‚РЎвЂљ $flash_port"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$flash_port" "$WEBUI_FW"; then
        log "WebUI Р С—РЎР‚Р С•РЎв‚¬Р С‘Р В»Р В°РЎРѓРЎРЉ РЎвЂЎР ВµРЎР‚Р ВµР В· $flash_port"
        return 0
      fi
      sleep 1
    fi

    # 2. Р СџР С•РЎвЂљР С•Р С Р В±РЎвЂ№РЎРѓРЎвЂљРЎР‚РЎвЂ№Р в„– Р С—Р ВµРЎР‚Р ВµР В±Р С•РЎР‚ Р В¶Р С‘Р Р†РЎвЂ№РЎвЂ¦ Р С—Р С•РЎР‚РЎвЂљР С•Р Р†
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      [[ "$p" == "$flash_port" ]] && continue
      log "Р СџРЎР‚Р С•Р В±РЎС“РЎР‹ WebUI РЎвЂЎР ВµРЎР‚Р ВµР В· $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
        log "WebUI Р С—РЎР‚Р С•РЎв‚¬Р С‘Р В»Р В°РЎРѓРЎРЉ РЎвЂЎР ВµРЎР‚Р ВµР В· $p"
        return 0
      fi
      sleep 1
    done

    # 3. Р вЂўРЎРѓР В»Р С‘ Р Р…Р Вµ Р Р†РЎвЂ№РЎв‚¬Р В»Р С•, РЎРѓР Р…Р С•Р Р†Р В° Р Т‘РЎвЂРЎР‚Р С–Р В°Р ВµР С GODLOAD Р С‘ Р В¶Р Т‘РЎвЂР С Р С—Р С•РЎР‚РЎвЂљРЎвЂ№
    log "WebUI Р Р…Р Вµ Р В·Р В°РЎв‚¬Р В»Р В°, Р С—Р С•Р Р†РЎвЂљР С•РЎР‚РЎРЏРЎР‹ GODLOAD"
    enter_flash_mode || true
    sleep 3
    wait_dev_any 20 || true
    ls /dev/ttyUSB* 2>/dev/null || true
  done

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

  log "Р РЃР В°Р С– 1. Р вЂ“Р Т‘РЎС“ РЎР‚Р В°Р В±Р С•РЎвЂЎР ВµР Вµ РЎРѓР С•РЎРѓРЎвЂљР С•РЎРЏР Р…Р С‘Р Вµ Р СР С•Р Т‘Р ВµР СР В°"
  wait_huawei_state 40 || die "Р СљР С•Р Т‘Р ВµР С Р Р…Р Вµ Р Р†Р С‘Р Т‘Р ВµР Р… Р Р…Р С‘ Р С”Р В°Р С” HiLink, Р Р…Р С‘ Р С”Р В°Р С” ttyUSB"
  lsusb
  ls /dev/ttyUSB* 2>/dev/null || true

  log "Р РЃР В°Р С– 2. Р вЂ™РЎвЂ¦Р С•Р В¶РЎС“ Р Р† РЎР‚Р ВµР В¶Р С‘Р С Р С—РЎР‚Р С•РЎв‚¬Р С‘Р Р†Р С”Р С‘ Р В±Р ВµР В· Р С‘Р С–Р В»РЎвЂ№"
  enter_flash_mode || die "Р СњР Вµ РЎС“Р Т‘Р В°Р В»Р С•РЎРѓРЎРЉ Р С•РЎвЂљР С—РЎР‚Р В°Р Р†Р С‘РЎвЂљРЎРЉ AT^GODLOAD. Р вЂќР В»РЎРЏ Р Р…Р ВµР СР С•Р Т‘Р С‘РЎвЂћР С‘РЎвЂ Р С‘РЎР‚Р С•Р Р†Р В°Р Р…Р Р…Р С•Р С–Р С• HiLink Р СР С•Р В¶Р ВµРЎвЂљ Р С—Р С•Р Р…Р В°Р Т‘Р С•Р В±Р С‘РЎвЂљРЎРЉРЎРѓРЎРЏ debug mode."
  sleep 4

  log "Р РЃР В°Р С– 3. Р вЂ“Р Т‘РЎС“ ttyUSB Р С—Р С•РЎРѓР В»Р Вµ GODLOAD"
  wait_dev_any 30 || die "Р СџР С•РЎРѓР В»Р Вµ AT^GODLOAD Р Р…Р Вµ Р С—Р С•РЎРЏР Р†Р С‘Р В»РЎРѓРЎРЏ ttyUSB"
  ls /dev/ttyUSB*

  local port
port="$(choose_flash_port_hilink)" || die "Р СњР Вµ РЎС“Р Т‘Р В°Р В»Р С•РЎРѓРЎРЉ Р Р†РЎвЂ№Р В±РЎР‚Р В°РЎвЂљРЎРЉ Р С—Р С•РЎР‚РЎвЂљ Р С—РЎР‚Р С•РЎв‚¬Р С‘Р Р†Р С”Р С‘"
log "Р СџР С•РЎР‚РЎвЂљ Р С—РЎР‚Р С•РЎв‚¬Р С‘Р Р†Р С”Р С‘: $port"

if [[ -n "${FULL_FW:-}" ]]; then
  log "Р РЃР В°Р С– 4. Р РЃРЎРЉРЎР‹ Р С—Р С•Р В»Р Р…РЎС“РЎР‹ Р С—РЎР‚Р С•РЎв‚¬Р С‘Р Р†Р С”РЎС“ Р С•Р Т‘Р Р…Р С‘Р С РЎвЂћР В°Р в„–Р В»Р С•Р С"
  sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$port" "$FULL_FW"
else
  log "Р РЃР В°Р С– 4. Р РЃРЎРЉРЎР‹ main РЎРѓ Р С”Р В»РЎР‹РЎвЂЎР С•Р С -k"
  flash_main_no_needle || die "Main firmware Р Р…Р Вµ Р С—РЎР‚Р С•РЎв‚¬Р С‘Р В»Р В°РЎРѓРЎРЉ Р В±Р ВµР В· Р С‘Р С–Р В»РЎвЂ№"

  # Р С—Р С•РЎРѓР В»Р Вµ retry main Р В±Р ВµРЎР‚РЎвЂР С Р В°Р С”РЎвЂљРЎС“Р В°Р В»РЎРЉР Р…РЎвЂ№Р в„– Р С—Р С•РЎР‚РЎвЂљ Р ВµРЎвЂ°РЎвЂ РЎР‚Р В°Р В·
  port="$(choose_flash_port_hilink)" || true
  log "Р РЃР В°Р С– 5. Р РЃРЎРЉРЎР‹ WebUI РЎРѓ РЎР‚Р ВµРЎвЂљРЎР‚Р В°РЎРЏР СР С‘"
  flash_webui_no_needle "$port" || die "WebUI Р Р…Р Вµ Р С—РЎР‚Р С•РЎв‚¬Р С‘Р В»Р В°РЎРѓРЎРЉ Р В±Р ВµР В· Р С‘Р С–Р В»РЎвЂ№"
fi

  log "Р РЃР В°Р С– 6. Р вЂўРЎРѓР В»Р С‘ Р СР С•Р Т‘Р ВµР С Р В·Р В°Р Р†Р С‘РЎРѓ Р Р† Р С—РЎР‚Р С•РЎв‚¬Р С‘Р Р†Р С•РЎвЂЎР Р…Р С•Р С РЎР‚Р ВµР В¶Р С‘Р СР Вµ, Р С—РЎР‚Р С•Р В±РЎС“РЎР‹ -r"
  if [[ -n "${port:-}" && -e "${port:-/dev/null}" ]]; then
    log "Clearing modem runtime config flags before reboot"
    printf 'ATINVMST\r' | sudo tee "$port" >/dev/null || true
    sleep 2
    sudo "$FLASHBIN" -p "$port" -r || true
    log "Modem is rebooting, waiting for USB re-enumeration"
    sleep 45
  fi

  log "Р РЃР В°Р С– 7. Р вЂ™Р С•Р В·Р Р†РЎР‚Р В°РЎвЂ°Р В°РЎР‹ РЎРѓР ВµРЎР‚Р Р†Р С‘РЎРѓРЎвЂ№ Р С—Р ВµРЎР‚Р ВµР Т‘ Р С—РЎР‚Р С•Р Р†Р ВµРЎР‚Р С”Р С•Р в„– РЎРѓР ВµРЎвЂљР С‘"
  start_services
  sleep 5

  log "Р РЃР В°Р С– 8. Р СџРЎвЂ№РЎвЂљР В°РЎР‹РЎРѓРЎРЉ Р С—Р С•Р Т‘Р Р…РЎРЏРЎвЂљРЎРЉ РЎРѓР ВµРЎвЂљРЎРЉ Р СР С•Р Т‘Р ВµР СР В°"
  if wait_hilink_webui 180; then
    log "Р РЋР ВµРЎвЂљРЎРЉ Р С—Р С•Р Т‘Р Р…РЎРЏР В»Р В°РЎРѓРЎРЉ. Р СџРЎР‚Р С•Р В±РЎС“Р в„– http://192.168.8.1 Р С‘ http://192.168.1.1"
  else
    log "Р СџРЎР‚Р С•РЎв‚¬Р С‘Р Р†Р С”Р В° Р В·Р В°Р Р†Р ВµРЎР‚РЎв‚¬Р ВµР Р…Р В°, Р Р…Р С• РЎРѓР ВµРЎвЂљРЎРЉ Р В°Р Р†РЎвЂљР С•Р СР В°РЎвЂљР С‘РЎвЂЎР ВµРЎРѓР С”Р С‘ Р Р…Р Вµ Р С—Р С•Р Т‘Р Р…РЎРЏР В»Р В°РЎРѓРЎРЉ"
    log "Р СџРЎР‚Р С•Р Р†Р ВµРЎР‚РЎРЉ Р С‘Р Р…РЎвЂљР ВµРЎР‚РЎвЂћР ВµР в„–РЎРѓ enx/usb/eth Р Р†РЎР‚РЎС“РЎвЂЎР Р…РЎС“РЎР‹"
    die "modem web interface did not come back after flashing"
  fi

  log "Р вЂњР С•РЎвЂљР С•Р Р†Р С•"
}

main "$@"
