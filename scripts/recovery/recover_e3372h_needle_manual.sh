#!/usr/bin/env bash
set -euo pipefail

# Manual support-only E3372h needle recovery. This follows the Linux bad-block
# erase flow and then flashes main + WebUI. It is not called by the web UI.

TOOLS_DIR="${TOOLS_DIR:-/opt/partner-node-flash/tools}"
IMAGES_DIR="${IMAGES_DIR:-/opt/partner-node-flash/images}"

USBLOAD="${USBLOAD:-${TOOLS_DIR}/balong-usbload}"
FLASHBIN="${FLASHBIN:-${TOOLS_DIR}/balong_flash_recover}"
PTABLE="${PTABLE:-${TOOLS_DIR}/ptable-hilink.bin}"
USBLSAFE="${USBLSAFE:-${TOOLS_DIR}/usblsafe-3372h.bin}"
MAIN_FW="${MAIN_FW:-${IMAGES_DIR}/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin}"
WEBUI_FW="${WEBUI_FW:-${IMAGES_DIR}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin}"
MODE="${1:-f}"

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_file() { [[ -f "$1" ]] || die "missing file: $1"; }

wait_lsusb_pid() {
  local pid="$1" timeout="${2:-30}" i=0
  while (( i < timeout )); do
    lsusb | grep -qi "12d1:${pid}" && return 0
    sleep 1
    ((i+=1))
  done
  return 1
}

wait_dev() {
  local dev="$1" timeout="${2:-25}" i=0
  while (( i < timeout )); do
    [[ -e "$dev" ]] && return 0
    sleep 1
    ((i+=1))
  done
  return 1
}

wait_three_ttys() {
  local timeout="${1:-45}" i=0
  while (( i < timeout )); do
    [[ -e /dev/ttyUSB0 && -e /dev/ttyUSB1 && -e /dev/ttyUSB2 ]] && return 0
    sleep 1
    ((i+=1))
  done
  return 1
}

stop_services() {
  sudo systemctl stop ModemManager 2>/dev/null || true
  sudo systemctl stop NetworkManager 2>/dev/null || true
}

start_services() {
  sudo systemctl start NetworkManager 2>/dev/null || true
  sudo systemctl start ModemManager 2>/dev/null || true
}
trap start_services EXIT

fastboot_cmd() {
  sudo fastboot -i0x12d1 "$@"
}

send_at() {
  local port="$1" cmd="$2"
  printf '%s\r' "$cmd" | sudo tee "$port" >/dev/null
}

send_godload_any() {
  local p
  for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
    [[ -e "$p" ]] || continue
    log "sending AT^GODLOAD to ${p}"
    send_at "$p" "AT^GODLOAD" || true
    sleep 2
    return 0
  done
  return 1
}

flash_main() {
  log "flashing main through /dev/ttyUSB2"
  sudo "$FLASHBIN" -p /dev/ttyUSB2 "$MAIN_FW" && return 0

  log "main strict path failed, retrying with relaxed DATAMODE"
  send_godload_any || true
  for p in /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB0; do
    [[ -e "$p" ]] || continue
    sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$MAIN_FW" && return 0
    sleep 1
  done
  return 1
}

flash_webui() {
  local p attempt
  for attempt in 1 2 3; do
    log "WebUI attempt ${attempt}"
    send_godload_any || true
    sleep 3
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW" && return 0
      sleep 1
    done
  done
  return 1
}

find_huawei_usbdev() {
  local devpath
  for devpath in /sys/bus/usb/devices/*; do
    [[ -f "$devpath/idVendor" ]] || continue
    [[ "$(cat "$devpath/idVendor" 2>/dev/null)" == "12d1" ]] || continue
    basename "$devpath"
    return 0
  done
  return 1
}

usb_power_cycle_huawei() {
  local dev
  dev="$(find_huawei_usbdev)" || return 1
  log "USB power-cycle for ${dev}"
  if [[ -w "/sys/bus/usb/devices/${dev}/authorized" ]]; then
    echo 0 | sudo tee "/sys/bus/usb/devices/${dev}/authorized" >/dev/null
    sleep 2
    echo 1 | sudo tee "/sys/bus/usb/devices/${dev}/authorized" >/dev/null
    sleep 5
    return 0
  fi
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

wait_post_main_state() {
  local timeout="${1:-90}" i=0
  while (( i < timeout )); do
    if lsusb | grep -Eq '12d1:(1f01|14dc|1506|1442)'; then
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

godload_via_adb() {
  local attempt
  for attempt in 1 2 3 4 5; do
    bring_usbnet_up
    adb connect 192.168.1.1:5555 >/dev/null 2>&1 || true
    adb connect 192.168.8.1:5555 >/dev/null 2>&1 || true
    adb shell 'echo -e "AT^GODLOAD\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
    adb -s 192.168.1.1:5555 shell 'echo -e "AT^GODLOAD\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
    adb -s 192.168.8.1:5555 shell 'echo -e "AT^GODLOAD\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

main() {
  [[ "$MODE" == "f" || "$MODE" == "b" ]] || die "usage: recover-e3372h-needle [f|b]"
  need_cmd lsusb
  need_cmd fastboot
  need_cmd sudo
  need_cmd adb
  need_file "$USBLOAD"
  need_file "$FLASHBIN"
  need_file "$PTABLE"
  need_file "$USBLSAFE"
  need_file "$MAIN_FW"
  need_file "$WEBUI_FW"

  stop_services

  log "step 1: waiting for needle mode 12d1:1443"
  wait_lsusb_pid "1443" 10 || die "modem is not in needle mode (12d1:1443)"
  wait_dev /dev/ttyUSB0 10 || die "missing /dev/ttyUSB0 in needle mode"

  log "step 2: anti-badblock loader (-${MODE}) + ptable"
  sudo "$USBLOAD" -p /dev/ttyUSB0 "-$MODE" -c -t "$PTABLE" -s4 -s14 -s16 "$USBLSAFE"

  log "step 3: checking fastboot 12d1:36dd"
  wait_lsusb_pid "36dd" 30 || die "modem did not enter 12d1:36dd fastboot"
  fastboot_cmd getvar product 2>&1 | tee /tmp/e3372_fastboot_product.txt
  grep -qi 'balongv7r2' /tmp/e3372_fastboot_product.txt || die "fastboot product is not balongv7r2"

  log "step 4: erase partitions"
  for part in m3boot fastboot nvimg nvdload oeminfo kernel kernelbk m3image dsp vxworks wbdata om app webui system userdata online cdromiso; do
    fastboot_cmd erase "$part"
  done

  log "step 5: fastboot reboot"
  fastboot_cmd reboot

  log "step 6: waiting for emergency USB loader again"
  wait_lsusb_pid "1443" 45 || die "modem did not return to 12d1:1443 after fastboot reboot"
  wait_dev /dev/ttyUSB0 15 || die "missing /dev/ttyUSB0 after fastboot reboot"

  log "step 7: plain usblsafe loader"
  sudo "$USBLOAD" -p /dev/ttyUSB0 "$USBLSAFE"

  log "step 8: waiting for three-port firmware mode"
  wait_three_ttys 60 || die "three ttyUSB ports did not appear"
  ls /dev/ttyUSB* 2>/dev/null || true

  log "step 9: main firmware"
  flash_main || die "main firmware flash failed"

  log "step 10: USB power-cycle after main"
  usb_power_cycle_huawei || log "automatic USB power-cycle unavailable; replug may be required"
  sleep 8

  log "step 11: waiting for post-main state"
  wait_post_main_state 90 || die "modem did not appear after main firmware"
  lsusb || true
  ls /dev/ttyUSB* 2>/dev/null || true

  if ! compgen -G "/dev/ttyUSB*" >/dev/null; then
    log "step 12: GODLOAD through ADB/appvcom1"
    godload_via_adb || die "failed to send AT^GODLOAD through ADB"
    sleep 3
    wait_dev /dev/ttyUSB0 30 || wait_dev /dev/ttyUSB1 30 || wait_dev /dev/ttyUSB2 30 || die "ttyUSB did not appear after GODLOAD"
  fi

  log "step 13: WebUI"
  flash_webui || die "WebUI flash failed"

  log "step 14: exit flash mode"
  if [[ -e /dev/ttyUSB0 ]]; then
    sudo "$FLASHBIN" -p /dev/ttyUSB0 -r || true
  elif [[ -e /dev/ttyUSB1 ]]; then
    sudo "$FLASHBIN" -p /dev/ttyUSB1 -r || true
  fi

  log "step 15: restore NVRAM status"
  if [[ -e /dev/ttyUSB0 ]]; then
    send_at /dev/ttyUSB0 "AT^NVRSTSTTS" || true
  elif [[ -e /dev/ttyUSB1 ]]; then
    send_at /dev/ttyUSB1 "AT^NVRSTSTTS" || true
  fi

  log "done; check http://192.168.8.1 and http://192.168.1.1"
}

main "$@"
