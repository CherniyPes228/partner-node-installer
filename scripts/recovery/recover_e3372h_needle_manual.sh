#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="/opt/partner-node-flash/tools"
IMAGES_DIR="/opt/partner-node-flash/images"

USBLOAD="$TOOLS_DIR/balong-usbload"
FLASHBIN="$TOOLS_DIR/balong_flash_recover"
PTABLE="$TOOLS_DIR/ptable-hilink.bin"
USBLSAFE="$TOOLS_DIR/usblsafe-3372h.bin"

MAIN_FW="${MAIN_FW:-}"
if [[ -z "$MAIN_FW" ]]; then
  for candidate in \
    "$IMAGES_DIR/E3372h-153_Update_22.200.15.00.00_M_AT_05.10.bin" \
    "$IMAGES_DIR/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin"
  do
    if [[ -f "$candidate" ]]; then
      MAIN_FW="$candidate"
      break
    fi
  done
fi
WEBUI_FW="$IMAGES_DIR/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin"

# f = Р±РµР· СЃС‚РёСЂР°РЅРёСЏ РїСЃРµРІРґРѕ Р±СЌРґ-Р±Р»РѕРєРѕРІ
# b = СЃРѕ СЃС‚РёСЂР°РЅРёРµРј РїСЃРµРІРґРѕ Р±СЌРґ-Р±Р»РѕРєРѕРІ
MODE="${1:-f}"

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
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
  command -v "$1" >/dev/null 2>&1 || die "РќРµ РЅР°Р№РґРµРЅР° РєРѕРјР°РЅРґР°: $1"
}

need_file() {
  [[ -f "$1" ]] || die "РќРµ РЅР°Р№РґРµРЅ С„Р°Р№Р»: $1"
}

wait_lsusb_pid() {
  local pid="$1"
  local timeout="${2:-30}"
  local i=0
  while (( i < timeout )); do
    if lsusb | grep -qi "12d1:${pid}"; then
      return 0
    fi
    sleep 1
    ((i+=1))
  done
  return 1
}

wait_dev() {
  local dev="$1"
  local timeout="${2:-25}"
  local i=0
  while (( i < timeout )); do
    [[ -e "$dev" ]] && return 0
    sleep 1
    ((i+=1))
  done
  return 1
}

wait_three_ttys() {
  local timeout="${1:-25}"
  local i=0
  while (( i < timeout )); do
    if [[ -e /dev/ttyUSB0 && -e /dev/ttyUSB1 && -e /dev/ttyUSB2 ]]; then
      return 0
    fi
    sleep 1
    ((i+=1))
  done
  return 1
}

stop_services() {
  log "РћСЃС‚Р°РЅР°РІР»РёРІР°СЋ ModemManager Рё NetworkManager"
  sudo systemctl stop ModemManager 2>/dev/null || true
  sudo systemctl stop NetworkManager 2>/dev/null || true
}

start_services() {
  log "Р’РѕР·РІСЂР°С‰Р°СЋ NetworkManager Рё ModemManager"
  sudo systemctl start NetworkManager 2>/dev/null || true
  sudo systemctl start ModemManager 2>/dev/null || true
}

cleanup() {
  start_services
}
trap cleanup EXIT

fastboot_cmd() {
  sudo fastboot "$@"
}

send_godload_any() {
  local p
  for p in /dev/ttyUSB0 /dev/ttyUSB1; do
    [[ -e "$p" ]] || continue
    log "РћС‚РїСЂР°РІР»СЏСЋ AT^GODLOAD РІ $p"
    echo -e "AT^GODLOAD\r" | sudo tee "$p" >/dev/null || true
    sleep 1
    return 0
  done
  return 1
}

flash_main_strict() {
  log "РЎС‚СЂРѕРіРёР№ 4PDA-РІР°СЂРёР°РЅС‚: main С‡РµСЂРµР· /dev/ttyUSB2"
  sudo "$FLASHBIN" -p /dev/ttyUSB2 "$MAIN_FW"
}

flash_main_fallback() {
  local p
  log "Fallback: GODLOAD + РїРµСЂРµР±РѕСЂ ttyUSB2/1/0"
  send_godload_any || true
  for p in /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB0; do
    [[ -e "$p" ]] || continue
    log "РџСЂРѕР±СѓСЋ main С‡РµСЂРµР· $p"
    if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$MAIN_FW"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

flash_webui_any() {
  local p
  send_godload_any || die "РќРµ СѓРґР°Р»РѕСЃСЊ РѕС‚РїСЂР°РІРёС‚СЊ AT^GODLOAD РїРµСЂРµРґ WebUI"
  for p in /dev/ttyUSB0 /dev/ttyUSB1; do
    [[ -e "$p" ]] || continue
    log "РџСЂРѕР±СѓСЋ WebUI С‡РµСЂРµР· $p"
    if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_normal_hilink() {
  local timeout="${1:-40}"
  local i=0
  while (( i < timeout )); do
    if lsusb | grep -Eq '12d1:(14dc|1f01|1506|1442)'; then
      return 0
    fi
    sleep 1
    ((i+=1))
  done
  return 1
}

bring_usbnet_up() {
  local iface
  for iface in $(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' | grep -E '^(enx|usb|eth)'); do
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip addr add 192.168.1.100/24 dev "$iface" 2>/dev/null || true
    sudo ip addr add 192.168.8.100/24 dev "$iface" 2>/dev/null || true
  done
}

godload_via_adb() {
  local attempt

  for attempt in 1 2 3 4 5; do
    log "ADB/GODLOAD РїРѕРїС‹С‚РєР° #$attempt"
    bring_usbnet_up

    adb connect 192.168.1.1:5555 >/dev/null 2>&1 || true
    adb connect 192.168.8.1:5555 >/dev/null 2>&1 || true

    if adb devices | grep -qE '192\.168\.(1|8)\.1:5555'; then
      adb shell 'echo -e "AT^GODLOAD\r" > /dev/appvcom1' >/dev/null 2>&1 && return 0
      adb -s 192.168.1.1:5555 shell 'echo -e "AT^GODLOAD\r" > /dev/appvcom1' >/dev/null 2>&1 && return 0
      adb -s 192.168.8.1:5555 shell 'echo -e "AT^GODLOAD\r" > /dev/appvcom1' >/dev/null 2>&1 && return 0
    fi

    sleep 3
  done

  return 1
}

flash_webui_fallback() {
  local p
  local attempt

  for attempt in 1 2 3; do
    log "РџРѕРїС‹С‚РєР° РїСЂРѕС€РёС‚СЊ WebUI #$attempt"

    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      log "РџСЂРѕР±СѓСЋ WebUI РЅР°РїСЂСЏРјСѓСЋ С‡РµСЂРµР· $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
        return 0
      fi
      sleep 1
    done

    send_godload_any || true
    sleep 3
    lsusb || true
    wait_dev /dev/ttyUSB0 20 || wait_dev /dev/ttyUSB1 20 || wait_dev /dev/ttyUSB2 20 || true
    ls /dev/ttyUSB* 2>/dev/null || true

    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      log "РџСЂРѕР±СѓСЋ WebUI РїРѕСЃР»Рµ tty-GODLOAD С‡РµСЂРµР· $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
        return 0
      fi
      sleep 1
    done

    godload_via_adb || true
    sleep 4
    lsusb || true
    wait_dev /dev/ttyUSB0 25 || wait_dev /dev/ttyUSB1 25 || wait_dev /dev/ttyUSB2 25 || true
    ls /dev/ttyUSB* 2>/dev/null || true

    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      log "РџСЂРѕР±СѓСЋ WebUI РїРѕСЃР»Рµ ADB-GODLOAD С‡РµСЂРµР· $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
        return 0
      fi
      sleep 1
    done
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
      log "Р’РёР¶Сѓ 12d1:1f01, РїРµСЂРµРєР»СЋС‡Р°СЋ РІ HiLink С‡РµСЂРµР· usb_modeswitch"
      sudo usb_modeswitch -J -v 0x12d1 -p 0x1f01 || true
    fi

    sleep 2
    ((i+=1))
  done

  lsusb | grep -q '12d1:14dc'
}

find_huawei_usbdev() {
  local devpath
  for devpath in /sys/bus/usb/devices/*; do
    [[ -f "$devpath/idVendor" && -f "$devpath/idProduct" ]] || continue
    if [[ "$(cat "$devpath/idVendor" 2>/dev/null)" == "12d1" ]]; then
      basename "$devpath"
      return 0
    fi
  done
  return 1
}

usb_power_cycle_huawei() {
  local dev
  dev="$(find_huawei_usbdev)" || return 1
  log "Р”РµР»Р°СЋ USB power-cycle РґР»СЏ СѓСЃС‚СЂРѕР№СЃС‚РІР° $dev"

  if [[ -w "/sys/bus/usb/devices/$dev/authorized" ]]; then
    echo 0 | sudo tee "/sys/bus/usb/devices/$dev/authorized" >/dev/null
    sleep 2
    echo 1 | sudo tee "/sys/bus/usb/devices/$dev/authorized" >/dev/null
    sleep 4
    return 0
  fi

  if [[ -w /sys/bus/usb/drivers/usb/unbind && -w /sys/bus/usb/drivers/usb/bind ]]; then
    echo "$dev" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null
    sleep 2
    echo "$dev" | sudo tee /sys/bus/usb/drivers/usb/bind >/dev/null
    sleep 4
    return 0
  fi

  return 1
}

wait_adb_on_hilink() {
  local timeout="${1:-40}"
  local i=0

  while (( i < timeout )); do
    bring_usbnet_up
    adb connect 192.168.1.1:5555 >/dev/null 2>&1 || true
    adb connect 192.168.8.1:5555 >/dev/null 2>&1 || true

    if adb devices | grep -qE '192\.168\.(1|8)\.1:5555'; then
      return 0
    fi

    sleep 2
    ((i+=2))
  done

  return 1
}

wait_post_main_state() {
  local timeout="${1:-60}"
  local i=0

  while (( i < timeout )); do
    if lsusb | grep -Eq '12d1:(1f01|14dc|1506|1442)'; then
      return 0
    fi

    if [[ -e /dev/ttyUSB0 || -e /dev/ttyUSB1 || -e /dev/ttyUSB2 ]]; then
      return 0
    fi

    sleep 1
    ((i+=1))
  done

  return 1
}

main() {
  [[ "$MODE" == "f" || "$MODE" == "b" ]] || die "РСЃРїРѕР»СЊР·РѕРІР°РЅРёРµ: ./123.sh [f|b]"

  need_cmd lsusb
  need_cmd fastboot
  need_cmd sudo
  need_cmd adb
  need_cmd usb_modeswitch

  need_file "$USBLOAD"
  need_file "$FLASHBIN"
  need_file "$PTABLE"
  need_file "$USBLSAFE"
  need_file "$MAIN_FW"
  need_file "$WEBUI_FW"

  stop_services

  log "РЁР°Рі 1. РџСЂРѕРІРµСЂРєР° needle mode, РѕР¶РёРґР°СЋ 12d1:1443"
  lsusb
  wait_lsusb_pid "1443" 5 || die "РњРѕРґРµРј РЅРµ РІ needle mode (12d1:1443)"

  log "РЁР°Рі 2. usbdload -> fastboot (-$MODE) + ptable"
  wait_dev /dev/ttyUSB0 10 || die "РќРµС‚ /dev/ttyUSB0 РІ needle mode"
  sudo "$USBLOAD" -p /dev/ttyUSB0 "-$MODE" -c -t "$PTABLE" -s4 -s14 -s16 "$USBLSAFE"

  log "РЁР°Рі 3. РџСЂРѕРІРµСЂРєР° fastboot, РѕР¶РёРґР°СЋ 12d1:36dd"
  wait_lsusb_pid "36dd" 25 || die "РќРµ РїРѕСЏРІРёР»СЃСЏ 12d1:36dd"
  lsusb
  sudo fastboot getvar product 2>&1 | tee /tmp/e3372_fastboot_product.txt
  grep -qi 'balongv7r2' /tmp/e3372_fastboot_product.txt || die "product РЅРµ balongv7r2"

  log "РЁР°Рі 4. Erase СЂР°Р·РґРµР»РѕРІ"
  for part in m3boot fastboot nvimg nvdload oeminfo kernel kernelbk m3image dsp vxworks wbdata om app webui system userdata online cdromiso; do
    fastboot_cmd erase "$part"
  done

  log "РЁР°Рі 5. fastboot reboot"
  fastboot_cmd reboot

  log "РЁР°Рі 6. Р–РґСѓ РІРѕР·РІСЂР°С‚ РІ 12d1:1443"
  wait_lsusb_pid "1443" 30 || die "РџРѕСЃР»Рµ fastboot reboot РЅРµ РІРµСЂРЅСѓР»СЃСЏ 12d1:1443"
  lsusb

  log "РЁР°Рі 7. РџРµСЂРµРІРѕРґ РІ СЂРµР¶РёРј РїСЂРѕС€РёРІРєРё РѕР±С‹С‡РЅС‹Рј usblsafe"
  wait_dev /dev/ttyUSB0 10 || die "РќРµС‚ /dev/ttyUSB0 РїРѕСЃР»Рµ РІРѕР·РІСЂР°С‚Р° РІ 1443"
  sudo "$USBLOAD" -p /dev/ttyUSB0 "$USBLSAFE"

  log "РЁР°Рі 8. Р–РґСѓ /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2"
  sleep 4
  wait_three_ttys 25 || die "РќРµ РїРѕСЏРІРёР»РёСЃСЊ С‚СЂРё ttyUSB РїРѕСЂС‚Р°"
  ls /dev/ttyUSB*

  log "РЁР°Рі 9. Main firmware"
  if ! flash_main_strict; then
    log "РЎС‚СЂРѕРіРёР№ 4PDA main РЅРµ РїСЂРѕС€С‘Р», РІРєР»СЋС‡Р°СЋ fallback"
    flash_main_fallback || die "Main firmware РЅРµ РїСЂРѕС€РёР»Р°СЃСЊ РЅРё РІ strict, РЅРё РІ fallback"
  fi

  log "РЁР°Рі 10. РђРІС‚РѕРјР°С‚РёС‡РµСЃРєРёР№ USB power-cycle РІРјРµСЃС‚Рѕ СЂСѓС‡РЅРѕРіРѕ РїРµСЂРµРїРѕРґРєР»СЋС‡РµРЅРёСЏ"
  if ! usb_power_cycle_huawei; then
    log "USB power-cycle РЅРµ РїРѕРґС‚РІРµСЂРґРёР»СЃСЏ С‡РµСЂРµР· sysfs, РЅРѕ РјРѕРґРµРј РјРѕРі РїРµСЂРµР·Р°РїСѓСЃС‚РёС‚СЊСЃСЏ СЃР°Рј"
  fi
  sleep 6

  log "РЁР°Рі 11. Р–РґСѓ Р»СЋР±РѕРµ РїРѕСЃС‚-main СЃРѕСЃС‚РѕСЏРЅРёРµ РјРѕРґРµРјР°"
  wait_post_main_state 60 || die "РџРѕСЃР»Рµ main РЅРµ РїРѕСЏРІРёР»РѕСЃСЊ РЅРё 1f01/14dc/1442/1506, РЅРё ttyUSB"
  lsusb
  ls /dev/ttyUSB* 2>/dev/null || true

  log "РЁР°Рі 12. РћРїСЂРµРґРµР»СЏСЋ РґР°Р»СЊРЅРµР№С€РёР№ РїСѓС‚СЊ"
  if [[ -e /dev/ttyUSB0 || -e /dev/ttyUSB1 || -e /dev/ttyUSB2 ]]; then
    log "РџРѕСЃР»Рµ main СѓР¶Рµ РµСЃС‚СЊ ttyUSB, РїСЂРѕРїСѓСЃРєР°СЋ usb_modeswitch Рё ADB"
  else
    log "ttyUSB РЅРµС‚, РїРµСЂРµРІРѕР¶Сѓ 1f01 -> 14dc (HiLink)"
    ensure_hilink_mode 40 || die "РќРµ СѓРґР°Р»РѕСЃСЊ РїРµСЂРµРІРµСЃС‚Рё РјРѕРґРµРј РёР· 1f01 РІ 14dc С‡РµСЂРµР· usb_modeswitch"
    sleep 5
    lsusb

    log "РЁР°Рі 13. Р”Р°СЋ AT^GODLOAD С‡РµСЂРµР· ADB/appvcom1"
    godload_via_adb || die "РќРµ СѓРґР°Р»РѕСЃСЊ РґР°С‚СЊ AT^GODLOAD С‡РµСЂРµР· ADB"

    sleep 3
    lsusb || true

    log "Р–РґСѓ ttyUSB РїРѕСЃР»Рµ ADB-GODLOAD"
    wait_dev /dev/ttyUSB0 25 || wait_dev /dev/ttyUSB1 25 || wait_dev /dev/ttyUSB2 25 || die "РџРѕСЃР»Рµ GODLOAD РЅРµ РїРѕСЏРІРёР»СЃСЏ ttyUSB"
    ls /dev/ttyUSB* 2>/dev/null || true
  fi

  log "РЁР°Рі 14. WebUI"
  flash_webui_fallback || die "WebUI РЅРµ РїСЂРѕС€РёР»Р°СЃСЊ РґР°Р¶Рµ РїРѕСЃР»Рµ РїРѕРІС‚РѕСЂРЅС‹С… GODLOAD/СЂРµС‚СЂР°РµРІ"

  log "РЁР°Рі 15. Р•СЃР»Рё WebUI РїСЂРѕС€РёР»Р°СЃСЊ, РїСЂРѕР±СѓСЋ РІС‹РІРµСЃС‚Рё РёР· РїСЂРѕС€РёРІРѕС‡РЅРѕРіРѕ СЂРµР¶РёРјР°"
  if [[ -e /dev/ttyUSB0 ]]; then
    sudo "$FLASHBIN" -p /dev/ttyUSB0 -r || true
  elif [[ -e /dev/ttyUSB1 ]]; then
    sudo "$FLASHBIN" -p /dev/ttyUSB1 -r || true
  fi

  log "РЁР°Рі 16. Р’РѕСЃСЃС‚Р°РЅРѕРІР»РµРЅРёРµ NVRAM status"
  if [[ -e /dev/ttyUSB0 ]]; then
    echo -e "AT^NVRSTSTTS\r" | sudo tee /dev/ttyUSB0 >/dev/null || true
  elif [[ -e /dev/ttyUSB1 ]]; then
    echo -e "AT^NVRSTSTTS\r" | sudo tee /dev/ttyUSB1 >/dev/null || true
  fi

  log "Р“РѕС‚РѕРІРѕ. РџСЂРѕРІРµСЂСЏР№ http://192.168.8.1 Рё http://192.168.1.1"
}

main "$@"
