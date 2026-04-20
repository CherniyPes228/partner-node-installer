#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="/opt/partner-node-flash/tools"
IMAGES_DIR="/opt/partner-node-flash/images"

USBLOAD="$TOOLS_DIR/balong-usbload"
FLASHBIN="$TOOLS_DIR/balong_flash_recover"
PTABLE="$TOOLS_DIR/ptable-hilink.bin"
USBLSAFE="$TOOLS_DIR/usblsafe-3372h.bin"
NM_ONLY_UDEV_RULE="/run/udev/rules.d/99-partner-node-nm-only.rules"
NM_ONLY_USB_PORT=""
NM_ONLY_NET_IFACE=""

MAIN_FW="${2:-${MAIN_FW:-$IMAGES_DIR/E3372h-153_Update_22.333.01.00.00_M_AT_05.10.bin}}"
WEBUI_FW="${3:-${WEBUI_FW:-$IMAGES_DIR/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13_E3372h_local-upd.bin}}"

# f = без стирания псевдо бэд-блоков
# b = со стиранием псевдо бэд-блоков
MODE="${1:-f}"

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

need_file() {
  [[ -f "$1" ]] || die "Не найден файл: $1"
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

find_huawei_net_iface() {
  local iface
  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" =~ ^(enx|usb|eth) ]] || continue
    if udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'; then
      printf '%s' "$iface"
      return 0
    fi
  done
  return 1
}

disable_network_manager_for_modem() {
  local usb_port=""
  local iface=""

  usb_port="$(find_huawei_usbdev 2>/dev/null || true)"
  [[ -n "$usb_port" ]] || return 0
  NM_ONLY_USB_PORT="$usb_port"

  iface="$(find_huawei_net_iface 2>/dev/null || true)"
  NM_ONLY_NET_IFACE="$iface"

  sudo mkdir -p /run/udev/rules.d
  cat <<EOF | sudo tee "$NM_ONLY_UDEV_RULE" >/dev/null
ACTION=="add|change", SUBSYSTEM=="net", KERNELS=="${usb_port}", ENV{NM_UNMANAGED}="1"
EOF

  sudo udevadm control --reload-rules || true
  if [[ -e "/sys/bus/usb/devices/${usb_port}" ]]; then
    sudo udevadm trigger --action=change "/sys/bus/usb/devices/${usb_port}" || true
  fi

  if [[ -n "$iface" ]] && command -v nmcli >/dev/null 2>&1; then
    sudo nmcli device set "$iface" managed no 2>/dev/null || true
  fi
}

enable_network_manager_for_modem() {
  if [[ -f "$NM_ONLY_UDEV_RULE" ]]; then
    sudo rm -f "$NM_ONLY_UDEV_RULE" || true
    sudo udevadm control --reload-rules || true
  fi

  if [[ -n "${NM_ONLY_NET_IFACE:-}" ]] && command -v nmcli >/dev/null 2>&1; then
    sudo nmcli device set "$NM_ONLY_NET_IFACE" managed yes 2>/dev/null || true
  fi
}

stop_services() {
  log "Останавливаю ModemManager и отключаю NetworkManager только для модема"
  sudo systemctl stop ModemManager 2>/dev/null || true
  disable_network_manager_for_modem
}

start_services() {
  log "Возвращаю NetworkManager для модема и запускаю ModemManager"
  enable_network_manager_for_modem
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
    log "Отправляю AT^GODLOAD в $p"
    echo -e "AT^GODLOAD\r" | sudo tee "$p" >/dev/null || true
    sleep 1
    return 0
  done
  return 1
}

flash_main_strict() {
  log "Строгий 4PDA-вариант: main через /dev/ttyUSB2"
  sudo "$FLASHBIN" -p /dev/ttyUSB2 "$MAIN_FW"
}

flash_main_fallback() {
  local p
  log "Fallback: GODLOAD + перебор ttyUSB2/1/0"
  send_godload_any || true
  for p in /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB0; do
    [[ -e "$p" ]] || continue
    log "Пробую main через $p"
    if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$MAIN_FW"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

flash_webui_any() {
  local p
  send_godload_any || die "Не удалось отправить AT^GODLOAD перед WebUI"
  for p in /dev/ttyUSB0 /dev/ttyUSB1; do
    [[ -e "$p" ]] || continue
    log "Пробую WebUI через $p"
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

flush_non_huawei_usbnet() {
  local iface

  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" =~ ^(enx|usb|eth) ]] || continue

    if ! udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'; then
      sudo ip addr flush dev "$iface" 2>/dev/null || true
    fi
  done
}

bring_usbnet_up() {
  local iface
  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" =~ ^(enx|usb|eth) ]] || continue

    if udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'; then
      sudo ip link set "$iface" up 2>/dev/null || true
      #sudo ip addr add 192.168.1.100/24 dev "$iface" 2>/dev/null || true
      #sudo ip addr add 192.168.8.100/24 dev "$iface" 2>/dev/null || true
    fi
  done
}

godload_via_adb() {
  local attempt

  for attempt in 1 2 3 4 5; do
    log "ADB/GODLOAD попытка #$attempt"
    bring_usbnet_up

    #adb connect 192.168.1.1:5555 >/dev/null 2>&1 || true
    #adb connect 192.168.8.1:5555 >/dev/null 2>&1 || true

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
    log "Попытка прошить WebUI #$attempt"

    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      log "Пробую WebUI напрямую через $p"
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
      log "Пробую WebUI после tty-GODLOAD через $p"
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
      log "Пробую WebUI после ADB-GODLOAD через $p"
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
      log "Вижу 12d1:1f01, переключаю в HiLink через usb_modeswitch"
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
  log "Делаю USB power-cycle для устройства $dev"

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
  [[ "$MODE" == "f" || "$MODE" == "b" ]] || die "Использование: ./123_test.sh [f|b] [MAIN_FW] [WEBUI_FW]"

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
  
  log "MODE: $MODE"
  log "MAIN_FW: $MAIN_FW"
  log "WEBUI_FW: $WEBUI_FW"

  stop_services
  flush_non_huawei_usbnet

  log "Шаг 1. Проверка needle mode, ожидаю 12d1:1443"
  lsusb
  wait_lsusb_pid "1443" 5 || die "Модем не в needle mode (12d1:1443)"

  log "Шаг 2. usbdload -> fastboot (-$MODE) + ptable"
  wait_dev /dev/ttyUSB0 10 || die "Нет /dev/ttyUSB0 в needle mode"
  sudo "$USBLOAD" -p /dev/ttyUSB0 "-$MODE" -c -t "$PTABLE" -s4 -s14 -s16 "$USBLSAFE"

  log "Шаг 3. Проверка fastboot, ожидаю 12d1:36dd"
  wait_lsusb_pid "36dd" 25 || die "Не появился 12d1:36dd"
  lsusb
  sudo fastboot getvar product 2>&1 | tee /tmp/e3372_fastboot_product.txt
  grep -qi 'balongv7r2' /tmp/e3372_fastboot_product.txt || die "product не balongv7r2"

  log "Шаг 4. Erase разделов"
  for part in m3boot fastboot nvimg nvdload oeminfo kernel kernelbk m3image dsp vxworks wbdata om app webui system userdata online cdromiso; do
    fastboot_cmd erase "$part"
  done

  log "Шаг 5. fastboot reboot"
  fastboot_cmd reboot

  log "Шаг 6. Жду возврат в 12d1:1443"
  wait_lsusb_pid "1443" 30 || die "После fastboot reboot не вернулся 12d1:1443"
  lsusb

  log "Шаг 7. Перевод в режим прошивки обычным usblsafe"
  wait_dev /dev/ttyUSB0 10 || die "Нет /dev/ttyUSB0 после возврата в 1443"
  sudo "$USBLOAD" -p /dev/ttyUSB0 "$USBLSAFE"

  log "Шаг 8. Жду /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2"
  sleep 4
  wait_three_ttys 25 || die "Не появились три ttyUSB порта"
  ls /dev/ttyUSB*

  log "Шаг 9. Main firmware"
  if ! flash_main_strict; then
    log "Строгий 4PDA main не прошёл, включаю fallback"
    flash_main_fallback || die "Main firmware не прошилась ни в strict, ни в fallback"
  fi

  log "Шаг 10. Автоматический USB power-cycle вместо ручного переподключения"
  if ! usb_power_cycle_huawei; then
    log "USB power-cycle не подтвердился через sysfs, но модем мог перезапуститься сам"
  fi
  sleep 6

  log "Шаг 11. Жду любое пост-main состояние модема"
  wait_post_main_state 60 || die "После main не появилось ни 1f01/14dc/1442/1506, ни ttyUSB"
  lsusb
  ls /dev/ttyUSB* 2>/dev/null || true

  log "Шаг 12. Определяю дальнейший путь"
  if [[ -e /dev/ttyUSB0 || -e /dev/ttyUSB1 || -e /dev/ttyUSB2 ]]; then
    log "После main уже есть ttyUSB, пропускаю usb_modeswitch и ADB"
  else
    log "ttyUSB нет, перевожу 1f01 -> 14dc (HiLink)"
    ensure_hilink_mode 40 || die "Не удалось перевести модем из 1f01 в 14dc через usb_modeswitch"
    sleep 5
    lsusb

    log "Шаг 13. Даю AT^GODLOAD через ADB/appvcom1"
    godload_via_adb || die "Не удалось дать AT^GODLOAD через ADB"

    sleep 3
    lsusb || true

    log "Жду ttyUSB после ADB-GODLOAD"
    wait_dev /dev/ttyUSB0 25 || wait_dev /dev/ttyUSB1 25 || wait_dev /dev/ttyUSB2 25 || die "После GODLOAD не появился ttyUSB"
    ls /dev/ttyUSB* 2>/dev/null || true
  fi

  log "Шаг 14. WebUI"
  flash_webui_fallback || die "WebUI не прошилась даже после повторных GODLOAD/ретраев"

  log "Шаг 15. Если WebUI прошилась, пробую вывести из прошивочного режима"
  if [[ -e /dev/ttyUSB0 ]]; then
    sudo "$FLASHBIN" -p /dev/ttyUSB0 -r || true
  elif [[ -e /dev/ttyUSB1 ]]; then
    sudo "$FLASHBIN" -p /dev/ttyUSB1 -r || true
  fi

  log "Шаг 16. Восстановление NVRAM status"
  if [[ -e /dev/ttyUSB0 ]]; then
    echo -e "AT^NVRSTSTTS\r" | sudo tee /dev/ttyUSB0 >/dev/null || true
  elif [[ -e /dev/ttyUSB1 ]]; then
    echo -e "AT^NVRSTSTTS\r" | sudo tee /dev/ttyUSB1 >/dev/null || true
  fi

  flush_non_huawei_usbnet
  log "Готово. Проверяй http://192.168.8.1 и http://192.168.1.1"
}

main "$@"
