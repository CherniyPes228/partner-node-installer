#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="/opt/partner-node-flash/tools"
IMAGES_DIR="/opt/partner-node-flash/images"

FLASHBIN="$TOOLS_DIR/balong_flash_recover"

FULL_FW=""

# Вариант 2: раздельно main + webui
MAIN_FW="$IMAGES_DIR/E3372h-153_Update_22.200.15.00.00_M_AT_05.10.bin"
WEBUI_FW="$IMAGES_DIR/WEBUI_17.100.05.06.965_Mod1.16_V7R11_CPIO.bin"

USBLOAD="$TOOLS_DIR/balong-usbload"
USBLSAFE="$TOOLS_DIR/usblsafe-3372h.bin"
PTABLE="$TOOLS_DIR/ptable-hilink.bin"
NM_ONLY_UDEV_RULE="/run/udev/rules.d/99-partner-node-nm-only.rules"
NM_ONLY_USB_PORT=""
NM_ONLY_NET_IFACE=""
ADB_STATE_DIR="${ADB_STATE_DIR:-/var/lib/partner-node/adb-home}"
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

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

init_adb_env() {
  mkdir -p "${ADB_STATE_DIR}/.android"
  chmod 700 "${ADB_STATE_DIR}" "${ADB_STATE_DIR}/.android" 2>/dev/null || true
  export HOME="${ADB_STATE_DIR}"
  export ANDROID_SDK_HOME="${ADB_STATE_DIR}"
  export ADB_VENDOR_KEYS="${ADB_STATE_DIR}/.android"
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

  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" =~ ^(enx|usb|eth) ]] || continue

    if udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'; then
      "${SUDO[@]}" ip addr flush dev "$iface" 2>/dev/null || true
      "${SUDO[@]}" ip link set "$iface" up 2>/dev/null || true
      #sudo ip addr add 192.168.8.100/24 dev "$iface" 2>/dev/null || true
      #sudo ip addr add 192.168.1.100/24 dev "$iface" 2>/dev/null || true
    fi
  done
}

recover_network() {
  local iface
  local ok=1

  # иногда после прошивки модем приходит в 1f01, сразу толкнём его в 14dc
  ensure_hilink_mode 20 || true

  bring_usbnet_up
  sleep 3

  for iface in $(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' | grep -E '^(enx|usb|eth)' || true); do
    "${SUDO[@]}" ip link set "$iface" up 2>/dev/null || true
    #sudo ip addr add 192.168.8.100/24 dev "$iface" 2>/dev/null || true
    #sudo ip addr add 192.168.1.100/24 dev "$iface" 2>/dev/null || true
    #sudo ip route replace 192.168.8.0/24 dev "$iface" 2>/dev/null || true
    #sudo ip route replace 192.168.1.0/24 dev "$iface" 2>/dev/null || true
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
      log "Вижу 12d1:1f01, переключаю в 14dc через usb_modeswitch"
      "${SUDO[@]}" usb_modeswitch -J -v 0x12d1 -p 0x1f01 || true
    fi

    sleep 2
    ((i+=1))
  done

  lsusb | grep -q '12d1:14dc'
}

wait_adb_on_hilink() {
  local timeout="${1:-40}"
  local i=0

  init_adb_env
  while (( i < timeout )); do
    bring_usbnet_up
    timeout 5 adb connect 192.168.8.1:5555 >/dev/null 2>&1 || true
    timeout 5 adb connect 192.168.1.1:5555 >/dev/null 2>&1 || true

    if timeout 5 adb devices | grep -qE '192\.168\.(8|1)\.1:5555'; then
      return 0
    fi

    sleep 2
    ((i+=2))
  done

  return 1
}

flush_non_huawei_usbnet() {
  local iface

  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" =~ ^(enx|usb|eth) ]] || continue

    if ! udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'; then
      "${SUDO[@]}" ip addr flush dev "$iface" 2>/dev/null || true
    fi
  done
}

extract_tag() {
  local tag="$1"
  sed -n "s:.*<${tag}>\\(.*\\)</${tag}>.*:\\1:p" | head -n 1
}

find_hilink_base() {
  local base=""
  local iface=""
  local addr=""
  local seen=""

  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" =~ ^(enx|usb|eth) ]] || continue
    if udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'; then
      while IFS= read -r addr; do
        [[ -n "$addr" ]] || continue
        base="http://${addr%.*}.1"
        if [[ " $seen " != *" $base "* ]]; then
          if curl -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
            printf '%s' "$base"
            return 0
          fi
          seen="$seen $base"
        fi
      done < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    fi
  done

  for base in "http://192.168.8.1" "http://192.168.1.1"; do
    if [[ " $seen " != *" $base "* ]]; then
      if curl -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
        printf '%s' "$base"
        return 0
      fi
    fi
  done

  return 1
}

get_hilink_token() {
  local base="$1"
  local cookiejar="$2"
  curl -fsS --max-time 10 -c "${cookiejar}" "${base}/api/webserver/SesTokInfo" 2>/dev/null | extract_tag "TokInfo"
}

get_hilink_home_token() {
  local base="$1"
  local cookiejar="$2"
  curl -fsS --max-time 10 -c "${cookiejar}" "${base}/html/home.html" 2>/dev/null | sed -n 's:.*<meta name="csrf_token" content="\([^"]*\)".*:\1:p' | head -n 1
}

hilink_post_xml() {
  local base="$1"
  local path="$2"
  local body="$3"
  local cookiejar=""
  local token=""
  local resp=""

  cookiejar="$(mktemp)"
  token="$(get_hilink_home_token "$base" "$cookiejar")"
  [[ -n "$token" ]] || token="$(get_hilink_token "$base" "$cookiejar")"
  [[ -n "$token" ]] || {
    rm -f "$cookiejar"
    return 1
  }

  resp="$(curl -fsS --max-time 15 \
    -b "$cookiejar" -c "$cookiejar" \
    -H "Accept: */*" \
    -H "Origin: ${base}" \
    -H "Referer: ${base}/html/home.html" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "__RequestVerificationToken: ${token}" \
    -H "Content-Type: text/xml; charset=UTF-8" \
    -X POST \
    -d "$body" \
    "${base}${path}" 2>/dev/null || true)"

  rm -f "$cookiejar"
  [[ "$resp" == *"<response>OK</response>"* ]]
}

enable_debug_mode() {
  local base="$1"
  [[ -n "$base" ]] || return 1
  log "Включаю debug mode через ${base}/api/device/mode"
  hilink_post_xml "$base" "/api/device/mode" '<?xml version="1.0" encoding="UTF-8"?><request><mode>1</mode></request>'
}

godload_via_adb() {
  local attempt
  init_adb_env
  for attempt in 1 2 3 4 5; do
    log "ADB/GODLOAD попытка #$attempt"
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
    log "Отправляю AT^GODLOAD в $p"
    echo -e "AT^GODLOAD\r" | "${SUDO[@]}" tee "$p" >/dev/null || true
    sleep 2
    return 0
  done
  return 1
}

enter_flash_mode() {
  log "Пробую войти в режим прошивки без иглы"

  # Если уже есть ttyUSB, пробуем AT-порт
  if ls /dev/ttyUSB* >/dev/null 2>&1; then
    send_godload_any && return 0
  fi

  # Если устройство в 1f01, переводим в 14dc
  if lsusb | grep -q '12d1:1f01'; then
    ensure_hilink_mode 30 || true
  fi

  # Если уже HiLink, пробуем ADB
  if lsusb | grep -q '12d1:14dc'; then
    godload_via_adb && return 0
  fi

  # Повторная попытка через ttyUSB, если порт появился
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

  "${SUDO[@]}" mkdir -p /run/udev/rules.d
  cat <<EOF | "${SUDO[@]}" tee "$NM_ONLY_UDEV_RULE" >/dev/null
ACTION=="add|change", SUBSYSTEM=="net", KERNELS=="${usb_port}", ENV{NM_UNMANAGED}="1"
EOF

  "${SUDO[@]}" udevadm control --reload-rules || true
  if [[ -e "/sys/bus/usb/devices/${usb_port}" ]]; then
    "${SUDO[@]}" udevadm trigger --action=change "/sys/bus/usb/devices/${usb_port}" || true
  fi

  if [[ -n "$iface" ]] && command -v nmcli >/dev/null 2>&1; then
    "${SUDO[@]}" nmcli device set "$iface" managed no 2>/dev/null || true
  fi
}

enable_network_manager_for_modem() {
  if [[ -f "$NM_ONLY_UDEV_RULE" ]]; then
    "${SUDO[@]}" rm -f "$NM_ONLY_UDEV_RULE" || true
    "${SUDO[@]}" udevadm control --reload-rules || true
  fi

  if [[ -n "${NM_ONLY_NET_IFACE:-}" ]] && command -v nmcli >/dev/null 2>&1; then
    "${SUDO[@]}" nmcli device set "$NM_ONLY_NET_IFACE" managed yes 2>/dev/null || true
  fi
}

stop_services() {
  log "Останавливаю ModemManager и отключаю NetworkManager только для модема"
  "${SUDO[@]}" systemctl stop ModemManager 2>/dev/null || true
  disable_network_manager_for_modem
}

start_services() {
  log "Возвращаю NetworkManager для модема и запускаю ModemManager"
  enable_network_manager_for_modem
  "${SUDO[@]}" systemctl start ModemManager 2>/dev/null || true
}

cleanup() {
  start_services
}
trap cleanup EXIT

flash_main_no_needle() {
  local p
  local attempt

  for attempt in 1 2 3 4 5; do
    log "Попытка main #$attempt"

    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      log "Пробую main через $p"
      if "${SUDO[@]}" env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$MAIN_FW"; then
        echo "$p" > /tmp/e3372_last_flash_port
        sleep 2
        return 0
      fi
      sleep 2
    done

    log "Main не зашла, повторяю GODLOAD"
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

  for ((try=1; try<=7; try++)); do
    log "Попытка WebUI #$try"

    # 1. Сначала пробуем тем же портом, которым зашла main
    if [[ -n "$flash_port" && -e "$flash_port" ]]; then
      log "Пробую WebUI через основной порт $flash_port"
      if "${SUDO[@]}" env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$flash_port" "$WEBUI_FW"; then
        log "WebUI прошилась через $flash_port"
        sleep 3
        return 0
      fi
      sleep 2
    fi

    # 2. Потом быстрый перебор живых портов
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      [[ "$p" == "$flash_port" ]] && continue
      log "Пробую WebUI через $p"
      if "${SUDO[@]}" env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
        log "WebUI прошилась через $p"
        echo "$p" > /tmp/e3372_last_flash_port
        sleep 3
        return 0
      fi
      sleep 2
    done

    # 3. Если не вышло, снова дёргаем GODLOAD и ждём порты
    log "WebUI не зашла, повторяю GODLOAD"
    enter_flash_mode || true
    sleep 4
    wait_dev_any 25 || true
    ls /dev/ttyUSB* 2>/dev/null || true

    # после повторного входа обновим основной порт
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

  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" =~ ^(enx|usb|eth) ]] || continue

    if udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'; then
      if ip link show "$iface" 2>/dev/null | grep -q "LOWER_UP"; then
        echo "$iface"
        return 0
      fi
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
  init_adb_env
  log "Пробую сделать AT^RESET через ADB"

  bring_usbnet_up
  wait_adb_on_hilink 20 || return 1

  adb shell 'echo -e "AT^RESET\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
  adb -s 192.168.8.1:5555 shell 'echo -e "AT^RESET\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
  adb -s 192.168.1.1:5555 shell 'echo -e "AT^RESET\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0

  return 1
}

post_webui_recover() {
  local iface=""

  log "Жду возврат модема в HiLink после WebUI"
  wait_post_flash_state 60 || true
  sleep 5

  log "Поднимаю временную сеть для доступа к ADB/API"
  bring_usbnet_up
  sleep 5

  adb_at_reset || log "ADB reset не сработал, продолжаю без него"

  log "Жду живой сетевой интерфейс модема"
  if iface="$(wait_live_modem_iface 60)"; then
    log "Живой интерфейс модема: $iface"
    "${SUDO[@]}" ip link set "$iface" up 2>/dev/null || true
    "${SUDO[@]}" ip route replace 192.168.8.0/24 dev "$iface" 2>/dev/null || true
    "${SUDO[@]}" ip route replace 192.168.1.0/24 dev "$iface" 2>/dev/null || true
    return 0
  fi

  return 1
}

main() {
  need_cmd lsusb
  need_cmd adb
  need_cmd usb_modeswitch
  if (( ${#SUDO[@]} )); then
    need_cmd sudo
  fi

  need_file "$FLASHBIN"
  need_file "$MAIN_FW"
  need_file "$WEBUI_FW"
  need_file "$USBLOAD"
  need_file "$USBLSAFE"
  need_file "$PTABLE"

  stop_services
  flush_non_huawei_usbnet

  log "Шаг 1. Жду рабочее состояние модема"
  wait_huawei_state 40 || die "Модем не виден ни как HiLink, ни как ttyUSB"
  lsusb
  ls /dev/ttyUSB* 2>/dev/null || true

  local base=""
  base="$(find_hilink_base 2>/dev/null || true)"
  if [[ -n "$base" ]] && ! ls /dev/ttyUSB* >/dev/null 2>&1; then
    enable_debug_mode "$base" || true
    sleep 2
  fi

  log "Шаг 2. Вхожу в режим прошивки без иглы"
  enter_flash_mode || die "Не удалось отправить AT^GODLOAD. Для немодифицированного HiLink может понадобиться debug mode."
  sleep 4

  log "Шаг 3. Жду ttyUSB после GODLOAD"
  wait_dev_any 30 || die "После AT^GODLOAD не появился ttyUSB"
  ls /dev/ttyUSB*

  local port
port="$(choose_flash_port_hilink)" || die "Не удалось выбрать порт прошивки"
log "Порт прошивки: $port"

if [[ -n "${FULL_FW:-}" ]]; then
  echo "STAGE:flash_main"
  log "Шаг 4. Шью полную прошивку одним файлом"
  "${SUDO[@]}" env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$port" "$FULL_FW"
else
  log "Шаг 4. Шью main"
  flash_main_no_needle || die "Main firmware не прошилась без иглы"

  # после retry main берём актуальный порт ещё раз
  port="$(choose_flash_port_hilink)" || true
  echo "STAGE:flash_webui"
  log "Шаг 5. Шью WebUI с ретраями"
  flash_webui_no_needle "$port" || die "WebUI не прошилась без иглы"
fi

  log "Шаг 6. Жду пост-прошивочное состояние модема"
  echo "STAGE:verify"
  wait_post_flash_state 60 || true
  lsusb
  ls /dev/ttyUSB* 2>/dev/null || true

  log "Шаг 7. Возвращаю сервисы после прошивки"
  start_services
  sleep 8

  log "Шаг 8. Коротко жду живой сетевой интерфейс модема"
  local live_iface=""
  live_iface="$(wait_live_modem_iface 30 2>/dev/null || true)"
  if [[ -n "$live_iface" ]]; then
    log "Живой интерфейс модема: $live_iface"
  else
    log "Модем прошит; сетевой интерфейс не поднялся автоматически за отведённое время"
  fi

  flush_non_huawei_usbnet
  log "Готово"
}

main "$@"
