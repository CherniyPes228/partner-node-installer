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
WEBUI_FW="${WEBUI_FW:-$IMAGES_DIR/WEBUI_17.100.05.06.965_Mod1.16_V7R11_CPIO.bin}"

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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

need_file() {
  [[ -f "$1" ]] || die "Не найден файл: $1"
}

extract_tag() {
  local tag="$1"
  sed -n "s:.*<${tag}>\\(.*\\)</${tag}>.*:\\1:p" | head -n 1
}

current_hilink_bases() {
  local iface=""
  local addr=""
  local base=""
  local seen=""

  iface="$(get_live_modem_iface 2>/dev/null || true)"
  if [[ -n "$iface" ]]; then
    while IFS= read -r addr; do
      [[ -n "$addr" ]] || continue
      base="http://${addr%.*}.1"
      if [[ " $seen " != *" $base "* ]]; then
        printf '%s\n' "$base"
        seen="$seen $base"
      fi
    done < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  fi

  for base in "http://192.168.8.1" "http://192.168.1.1"; do
    if [[ " $seen " != *" $base "* ]]; then
      printf '%s\n' "$base"
      seen="$seen $base"
    fi
  done
}

find_hilink_base() {
  local base
  while IFS= read -r base; do
    if curl -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
      printf '%s' "$base"
      return 0
    fi
  done < <(current_hilink_bases)
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

get_hilink_page_token() {
  local base="$1"
  local page="$2"
  local cookiejar="$3"
  curl -fsS --max-time 10 -c "${cookiejar}" "${base}${page}" 2>/dev/null | sed -n 's:.*<meta name="csrf_token" content="\([^"]*\)".*:\1:p' | head -n 1
}

get_hilink_session_info() {
  local base="$1"
  local cookiejar="$2"
  curl -fsS --max-time 10 -c "${cookiejar}" "${base}/api/webserver/SesTokInfo" 2>/dev/null | extract_tag "SesInfo"
}

hilink_sha256_b64() {
  printf '%s' "$1" | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null
}

hilink_login_cookiejar() {
  local base="$1"
  local cookiejar="$2"
  local user="${MODEM_ADMIN_USER:-admin}"
  local password="${MODEM_ADMIN_PASSWORD:-}"
  local token=""
  local session=""
  local first_hash=""
  local login_hash=""
  local payload=""
  local resp=""

  [[ -n "$password" ]] || return 1

  token="$(get_hilink_token "$base" "$cookiejar")"
  session="$(get_hilink_session_info "$base" "$cookiejar")"
  [[ -n "$token" && -n "$session" ]] || return 1

  first_hash="$(hilink_sha256_b64 "$password")"
  [[ -n "$first_hash" ]] || return 1
  login_hash="$(hilink_sha256_b64 "${user}${first_hash}${token}")"
  [[ -n "$login_hash" ]] || return 1

  payload="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Username>${user}</Username><Password>${login_hash}</Password><password_type>4</password_type></request>"
  resp="$(curl -fsS --max-time 15 \
    -b "$cookiejar" -c "$cookiejar" \
    -H "Cookie: ${session}" \
    -H "__RequestVerificationToken: ${token}" \
    -H "Content-Type: text/xml; charset=UTF-8" \
    -X POST \
    -d "$payload" \
    "${base}/api/user/login" 2>/dev/null || true)"

  [[ "$resp" == *"<response>OK</response>"* ]]
}

hilink_post_xml() {
  local base="$1"
  local path="$2"
  local body="$3"
  local cookiejar
  local token
  local resp=""
  local token_page="/html/home.html"
  local referer="${base}/html/home.html"
  local content_type="text/xml; charset=UTF-8"

  cookiejar="$(mktemp)"
  if [[ "$path" == "/api/dhcp/settings" ]]; then
    token_page="/html/dhcp.html"
    referer="${base}/html/dhcp.html"
    content_type="application/x-www-form-urlencoded; charset=UTF-8"
  fi

  token="$(get_hilink_page_token "$base" "$token_page" "$cookiejar")"
  if [[ -z "$token" ]]; then
    token="$(get_hilink_token "$base" "$cookiejar")"
  fi
  [[ -n "$token" ]] || {
    rm -f "$cookiejar"
    return 1
  }

  resp="$(curl -fsS --max-time 15 \
    -b "$cookiejar" -c "$cookiejar" \
    -H "Accept: */*" \
    -H "Origin: ${base}" \
    -H "Referer: ${referer}" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "__RequestVerificationToken: ${token}" \
    -H "Content-Type: ${content_type}" \
    -X POST \
    -d "$body" \
    "${base}${path}" 2>/dev/null || true)"

  if [[ "$resp" == *"<response>OK</response>"* ]]; then
    rm -f "$cookiejar"
    return 0
  fi

  if [[ "$resp" == *"<code>125002</code>"* || "$resp" == *"<code>125003</code>"* ]]; then
    if hilink_login_cookiejar "$base" "$cookiejar"; then
      token="$(get_hilink_page_token "$base" "$token_page" "$cookiejar")"
      [[ -n "$token" ]] || token="$(get_hilink_token "$base" "$cookiejar")"
      if [[ -n "$token" ]]; then
        resp="$(curl -fsS --max-time 15 \
          -b "$cookiejar" -c "$cookiejar" \
          -H "Accept: */*" \
          -H "Origin: ${base}" \
          -H "Referer: ${referer}" \
          -H "X-Requested-With: XMLHttpRequest" \
          -H "__RequestVerificationToken: ${token}" \
          -H "Content-Type: ${content_type}" \
          -X POST \
          -d "$body" \
          "${base}${path}" 2>/dev/null || true)"
        if [[ "$resp" == *"<response>OK</response>"* ]]; then
          rm -f "$cookiejar"
          return 0
        fi
      fi
    fi
  fi

  rm -f "$cookiejar"
  return 1
}

ordinal_octet() {
  local ordinal="${1:-0}"
  if [[ ! "$ordinal" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( ordinal <= 0 || ordinal > 254 )); then
    return 1
  fi
  printf '%s' "$ordinal"
}

modem_target_octet() {
  local ordinal=""
  ordinal="$(ordinal_octet "${ORDINAL:-0}" 2>/dev/null || true)"
  [[ -n "$ordinal" ]] || return 1
  printf '%s' "$((100 + ordinal))"
}

modem_target_base() {
  local octet=""
  octet="$(modem_target_octet 2>/dev/null || true)"
  [[ -n "$octet" ]] || return 1
  printf 'http://192.168.%s.1' "$octet"
}

modem_target_host_ip() {
  local octet=""
  octet="$(modem_target_octet 2>/dev/null || true)"
  [[ -n "$octet" ]] || return 1
  printf '192.168.%s.100/24' "$octet"
}

modem_target_subnet() {
  local octet=""
  octet="$(modem_target_octet 2>/dev/null || true)"
  [[ -n "$octet" ]] || return 1
  printf '192.168.%s.0/24' "$octet"
}

enable_debug_mode() {
  local base="$1"
  log "Включаю debug mode через ${base}/api/device/mode"
  hilink_post_xml "$base" "/api/device/mode" '<?xml version="1.0" encoding="UTF-8"?><request><mode>1</mode></request>' || return 1
  return 0
}

wait_debug_mode_ready() {
  local timeout="${1:-30}"
  local i=0
  local base=""

  while (( i < timeout )); do
    bring_usbnet_up
    base="$(find_hilink_base 2>/dev/null || true)"
    if [[ -n "$base" ]] && wait_adb_on_hilink 8; then
      log "Debug mode подтверждён, HiLink и ADB доступны"
      return 0
    fi
    sleep 2
    ((i+=2))
  done

  return 1
}

debug_mode_settle_delay() {
  local delay="${DEBUG_MODE_SETTLE_DELAY:-8}"
  if (( delay > 0 )); then
    log "Жду ${delay}s после debug mode перед AT^GODLOAD"
    sleep "$delay"
  fi
}

set_modem_dhcp_settings() {
  local base="$1"
  local octet=""
  local modem_ip=""
  local start_ip=""
  local end_ip=""
  local payload=""
  local attempt=1

  octet="$(modem_target_octet 2>/dev/null || true)"
  [[ -n "$octet" ]] || return 1
  modem_ip="192.168.${octet}.1"
  start_ip="192.168.${octet}.100"
  end_ip="192.168.${octet}.200"
  payload="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><DhcpIPAddress>${modem_ip}</DhcpIPAddress><DhcpLanNetmask>255.255.255.0</DhcpLanNetmask><DhcpStatus>1</DhcpStatus><DhcpStartIPAddress>${start_ip}</DhcpStartIPAddress><DhcpEndIPAddress>${end_ip}</DhcpEndIPAddress><DhcpLeaseTime>86400</DhcpLeaseTime><DnsStatus>1</DnsStatus><PrimaryDns>0.0.0.0</PrimaryDns><SecondaryDns>0.0.0.0</SecondaryDns></request>"
  log "Меняю LAN IP модема на ${modem_ip}"
  while (( attempt <= 3 )); do
    if hilink_post_xml "$base" "/api/dhcp/settings" "$payload"; then
      return 0
    fi
    log "DHCP settings РЅРµ РїСЂРёРЅСЏР»РёСЃСЊ, РїРѕРІС‚РѕСЂСЏСЋ РїРѕРїС‹С‚РєСѓ ${attempt}/3"
    sleep 10
    ((attempt+=1))
  done
  return 1
}

configure_target_subnet_on_iface() {
  local iface="$1"
  [[ -n "$iface" ]] || return 1

  sudo ip link set "$iface" up 2>/dev/null || true
  sudo ip addr flush dev "$iface" 2>/dev/null || true
  return 0
}

clear_target_loopback_ips() {
  :
}

persist_target_subnet_with_nm() {
  local iface="$1"
  [[ -n "$iface" ]] || return 1
  command -v nmcli >/dev/null 2>&1 || return 0

  sudo nmcli connection modify "$iface" \
    ipv4.method auto \
    ipv4.addresses "" \
    ipv4.gateway "" \
    ipv4.routes "" \
    ipv4.route-metric 1000 \
    ipv4.ignore-auto-routes no \
    ipv4.ignore-auto-dns no \
    ipv4.never-default yes \
    ipv6.method link-local 2>/dev/null || true
  return 0
}

wait_for_hilink_at_base() {
  local base="$1"
  local timeout="${2:-60}"
  local i=0
  while (( i < timeout )); do
    if curl -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
      return 0
    fi
    sleep 2
    ((i+=2))
  done
  return 1
}

wait_for_hilink_page_token() {
  local base="$1"
  local page="$2"
  local timeout="${3:-60}"
  local cookiejar=""
  local token=""
  local i=0

  cookiejar="$(mktemp)"
  while (( i < timeout )); do
    token="$(get_hilink_page_token "$base" "$page" "$cookiejar" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      rm -f "$cookiejar"
      return 0
    fi
    sleep 2
    ((i+=2))
  done
  rm -f "$cookiejar"
  return 1
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

wait_flash_port_quiet() {
  local port="$1"
  local timeout="${2:-15}"
  local i=0
  local users=""

  [[ -e "$port" ]] || return 1

  while (( i < timeout )); do
    users=""
    if command -v fuser >/dev/null 2>&1; then
      users="$(fuser "$port" 2>/dev/null || true)"
    elif command -v lsof >/dev/null 2>&1; then
      users="$(lsof -t "$port" 2>/dev/null || true)"
    fi

    if [[ -z "$users" ]]; then
      return 0
    fi

    log "Жду освобождения $port: $users"
    sleep 1
    ((i+=1))
  done

  return 1
}

stabilize_flash_port() {
  local port="$1"
  [[ -e "$port" ]] || return 1
  udevadm settle 2>/dev/null || true
  sleep 3
  wait_flash_port_quiet "$port" 12 || true
  stty -F "$port" 9600 raw -echo 2>/dev/null || true
  sleep 1
  return 0
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
      sudo ip addr flush dev "$iface" 2>/dev/null || true
      sudo ip link set "$iface" up 2>/dev/null || true
    fi
  done
}

recover_network() {
  local iface
  local ok=1
  local base=""

  ensure_hilink_mode 20 || true

  bring_usbnet_up
  sleep 3

  for iface in $(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' | grep -E '^(enx|usb|eth)' || true); do
    sudo ip link set "$iface" up 2>/dev/null || true
  done

  sleep 3
  ip -br addr || true
  ip route || true

  while IFS= read -r base; do
    ping -c 2 "${base#http://}" >/dev/null 2>&1 && ok=0
  done < <(current_hilink_bases)

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
  local base=""
  local host=""

  while (( i < timeout )); do
    bring_usbnet_up
    while IFS= read -r base; do
      curl -fsS --max-time 4 "${base}/api/webserver/SesTokInfo" >/dev/null 2>&1 || continue
      host="${base#http://}"
      timeout 6 adb connect "${host}:5555" >/dev/null 2>&1 || true
    done < <(current_hilink_bases)

    if adb devices | grep -qE '192\.168\.[0-9]{1,3}\.1:5555'; then
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
      sudo ip addr flush dev "$iface" 2>/dev/null || true
    fi
  done
}

godload_via_adb() {
  local attempt
  for attempt in 1 2 3 4 5; do
    log "ADB/GODLOAD попытка #$attempt"
    bring_usbnet_up

    if wait_adb_on_hilink 20; then
      adb shell 'echo -e "AT^GODLOAD\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
      while IFS= read -r base; do
        local host="${base#http://}"
        adb -s "${host}:5555" shell 'echo -e "AT^GODLOAD\r" >/dev/appvcom1' >/dev/null 2>&1 && return 0
      done < <(current_hilink_bases)
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
    echo -e "AT^GODLOAD\r" | sudo tee "$p" >/dev/null || true
    sleep 2
    return 0
  done
  return 1
}

enter_flash_mode() {
  log "Пробую войти в режим прошивки без иглы"

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
  log "Оставляю ModemManager и NetworkManager запущенными"
}

start_services() {
  log "ModemManager и NetworkManager не трогаю"
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
      stabilize_flash_port "$p" || true
      log "Пробую main через $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$MAIN_FW"; then
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
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      stabilize_flash_port "$p" || true
    done
    :
  done

  return 1
}

flash_webui_no_needle() {
  local p
  local try
  local flash_port="${1:-}"

  for ((try=1; try<=7; try++)); do
    log "Попытка WebUI #$try"

    if [[ -n "$flash_port" && -e "$flash_port" ]]; then
      log "Пробую WebUI через основной порт $flash_port"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$flash_port" "$WEBUI_FW"; then
        log "WebUI прошилась через $flash_port"
        sleep 3
        return 0
      fi
      sleep 2
    fi

    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2; do
      [[ -e "$p" ]] || continue
      [[ "$p" == "$flash_port" ]] && continue
      log "Пробую WebUI через $p"
      if sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$p" "$WEBUI_FW"; then
        log "WebUI прошилась через $p"
        echo "$p" > /tmp/e3372_last_flash_port
        sleep 3
        return 0
      fi
      sleep 2
    done

    log "WebUI не зашла, повторяю GODLOAD"
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

prepare_webui_phase() {
  local base=""

  log "Стабилизирую состояние модема перед WebUI"
  wait_post_flash_state 90 || true
  sleep 8

  if ls /dev/ttyUSB* >/dev/null 2>&1; then
    log "После main модем уже в serial state"
    sleep 4
    ls /dev/ttyUSB* 2>/dev/null || true
    return 0
  fi

  base="$(find_hilink_base 2>/dev/null || true)"
  if [[ -n "$base" ]]; then
    log "После main модем вернулся в HiLink, заново вхожу в режим прошивки для WebUI"
    enter_flash_mode || true
    sleep 6
    wait_dev_any 30 || true
    ls /dev/ttyUSB* 2>/dev/null || true
    return 0
  fi

  log "После main не удалось уверенно определить состояние модема, продолжаю как есть"
  return 0
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

huawei_net_ifaces() {
  local iface

  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [[ "$iface" =~ ^(enx|usb|eth) ]] || continue

    if udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'; then
      echo "$iface"
    fi
  done
}

nm_unmanage_huawei_ifaces() {
  local iface

  command -v nmcli >/dev/null 2>&1 || return 0
  for iface in $(huawei_net_ifaces); do
    log "Временно отключаю управление NetworkManager для $iface"
    sudo nmcli device set "$iface" managed no 2>/dev/null || true
  done
}

nm_manage_huawei_ifaces() {
  local iface

  command -v nmcli >/dev/null 2>&1 || return 0
  for iface in $(huawei_net_ifaces); do
    log "Возвращаю управление NetworkManager для $iface"
    sudo nmcli device set "$iface" managed yes 2>/dev/null || true
  done
}

nm_unmanage_iface() {
  local iface="$1"
  [[ -n "$iface" ]] || return 0
  command -v nmcli >/dev/null 2>&1 || return 0
  log "Временно отключаю управление NetworkManager для $iface"
  sudo nmcli device set "$iface" managed no 2>/dev/null || true
}

nm_manage_iface() {
  local iface="$1"
  [[ -n "$iface" ]] || return 0
  command -v nmcli >/dev/null 2>&1 || return 0
  log "Возвращаю управление NetworkManager для $iface"
  sudo nmcli device set "$iface" managed yes 2>/dev/null || true
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

post_webui_recover() {
  local iface=""
  local base=""
  local target_base=""

  log "Жду возврат модема в HiLink после WebUI"
  wait_post_flash_state 60 || true
  sleep 5

  log "Поднимаю временную сеть для доступа к ADB/API"
  bring_usbnet_up
  sleep 5

  log "Жду живой сетевой интерфейс модема"
  if iface="$(wait_live_modem_iface 60)"; then
    log "Живой интерфейс модема: $iface"
    sudo ip link set "$iface" up 2>/dev/null || true
    sudo ip route replace 192.168.8.0/24 dev "$iface" 2>/dev/null || true
    sudo ip route replace 192.168.1.0/24 dev "$iface" 2>/dev/null || true

    if [[ -n "${ORDINAL:-}" ]]; then
      base="$(find_hilink_base 2>/dev/null || true)"
      if [[ -n "$base" ]]; then
        log "Жду полной готовности HiLink admin API перед сменой LAN IP"
      fi
      if [[ -n "$base" ]] && wait_for_hilink_at_base "$base" 90 && wait_for_hilink_page_token "$base" "/html/dhcp.html" 120 && set_modem_dhcp_settings "$base"; then
        nm_unmanage_iface "$iface"
        sleep 2
        clear_target_loopback_ips
        configure_target_subnet_on_iface "$iface" || true
        target_base="$(modem_target_base 2>/dev/null || true)"
        if [[ -n "$target_base" ]]; then
          log "Жду WebUI модема на ${target_base}"
          sleep 125
          if wait_for_hilink_at_base "$target_base" 30; then
            persist_target_subnet_with_nm "$iface" || true
            nm_manage_iface "$iface"
            sudo nmcli connection up "$iface" ifname "$iface" 2>/dev/null || true
          else
            log "Новый LAN IP модема пока не поднялся на ${target_base}"
            nm_manage_iface "$iface"
          fi
        fi
      else
        log "Не удалось изменить LAN IP модема, остаётся штатная подсеть"
      fi
    fi

    return 0
  fi

  return 1
}

main() {
  need_cmd lsusb
  need_cmd adb
  need_cmd usb_modeswitch
  need_cmd sudo
  need_cmd curl

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
  local skip_debug_mode=0
  if ls /dev/ttyUSB* >/dev/null 2>&1 || lsusb | grep -Eq '12d1:(1566|1442)'; then
    skip_debug_mode=1
    log "РњРѕРґРµРј СѓР¶Рµ РІ debug/serial state, РїСЂРѕРїСѓСЃРєР°СЋ РІРєР»СЋС‡РµРЅРёРµ debug mode"
  fi
  base="$(find_hilink_base 2>/dev/null || true)"
  if (( skip_debug_mode == 0 )) && [[ -n "$base" ]]; then
    enable_debug_mode "$base" || log "Не удалось включить debug mode, продолжаю как есть"
    wait_debug_mode_ready 30 || log "Debug mode не подтвердился полностью, продолжаю как есть"
    debug_mode_settle_delay
  fi

  log "Шаг 2. Вхожу в режим прошивки без иглы"
  enter_flash_mode || die "Не удалось отправить AT^GODLOAD. Для немодифицированного HiLink может понадобиться debug mode."
  sleep 4

  log "Шаг 3. Жду ttyUSB после GODLOAD"
  wait_dev_any 30 || die "После AT^GODLOAD не появился ttyUSB"
  ls /dev/ttyUSB*

  local port
  port="$(choose_flash_port_hilink)" || die "Не удалось выбрать порт прошивки"
  stabilize_flash_port "$port" || true
  log "Порт прошивки: $port"

  if [[ -n "${FULL_FW:-}" ]]; then
    log "Шаг 4. Шью полную прошивку одним файлом"
    sudo env BALONG_RELAX_DATAMODE=1 "$FLASHBIN" -p "$port" "$FULL_FW"
  else
    log "Шаг 4. Шью main"
    flash_main_no_needle || die "Main firmware не прошилась без иглы"

    log "Шаг 5. Готовлю модем к WebUI после main"
    prepare_webui_phase

    port="$(choose_flash_port_hilink)" || true
    log "Шаг 6. Шью WebUI с ретраями"
    flash_webui_no_needle "$port" || die "WebUI не прошилась без иглы"
  fi

  log "Шаг 7. Жду пост-прошивочное состояние модема"
  wait_post_flash_state 60 || true
  lsusb
  ls /dev/ttyUSB* 2>/dev/null || true

  log "Шаг 8. Пост-обработка после WebUI"
  post_webui_recover || log "Пост-обработка после WebUI не дала живой интерфейс"

  log "Шаг 9. Если модем завис в прошивочном режиме, пробую -r"
  port="$(cat /tmp/e3372_last_flash_port 2>/dev/null || true)"
  if [[ -n "${port:-}" && -e "${port:-/dev/null}" ]]; then
    sudo "$FLASHBIN" -p "$port" -r || true
  fi

  log "Шаг 10. Возвращаю сервисы перед проверкой сети"
  start_services
  sleep 8

  log "Шаг 11. Пытаюсь поднять сеть модема"
  if recover_network; then
    local live_iface=""
    local live_base=""
    live_iface="$(get_live_modem_iface 2>/dev/null || true)"
    live_base="$(find_hilink_base 2>/dev/null || true)"
    [[ -n "$live_iface" ]] && log "Рабочий интерфейс: $live_iface"
    [[ -n "$live_base" ]] && log "Сеть поднялась. Пробуй ${live_base}"
    if [[ -n "${ORDINAL:-}" ]]; then
      local target_base=""
      target_base="$(modem_target_base 2>/dev/null || true)"
      [[ -n "$target_base" ]] && log "После смены IP модем должен отвечать на ${target_base}"
    fi
  else
    log "Прошивка завершена, но сеть автоматически не поднялась"
    log "Проверь интерфейс enx/usb/eth вручную"
  fi

  flush_non_huawei_usbnet
  log "Готово"
}

main "$@"
