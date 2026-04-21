#!/usr/bin/env bash
set -euo pipefail

ORDINAL=""
BASE_URL=""
IFACE=""
NM_ONLY_UDEV_RULE="/run/udev/rules.d/99-partner-node-nm-only.rules"
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ordinal) ORDINAL="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --iface) IFACE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

extract_tag() {
  local tag="$1"
  sed -n "s:.*<${tag}>\\(.*\\)</${tag}>.*:\\1:p" | head -n 1
}

curl_hilink() {
  if interface_usable "${IFACE:-}"; then
    curl --interface "${IFACE}" "$@"
  else
    curl "$@"
  fi
}

interface_usable() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 1
  [[ -d "/sys/class/net/$iface" ]] || return 1
  return 0
}

interface_is_huawei() {
  local iface="${1:-}"
  interface_usable "$iface" || return 1
  udevadm info -q property -p "/sys/class/net/$iface" 2>/dev/null | grep -q '^ID_VENDOR_ID=12d1$'
}

ordinal_octet() {
  local ordinal="${1:-0}"
  [[ "$ordinal" =~ ^[0-9]+$ ]] || return 1
  (( ordinal > 0 && ordinal <= 154 )) || return 1
  printf '%s' "$((100 + ordinal))"
}

get_live_modem_iface() {
  if interface_is_huawei "${IFACE:-}"; then
    printf '%s' "${IFACE}"
    return 0
  fi
  local iface=""
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

find_huawei_usbdev() {
  local iface=""
  local resolved=""

  iface="$(get_live_modem_iface 2>/dev/null || true)"
  if [[ -n "$iface" && -e "/sys/class/net/${iface}/device" ]]; then
    resolved="$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)"
    while [[ -n "$resolved" && "$resolved" != "/" && "$resolved" != "." ]]; do
      if [[ -f "$resolved/idVendor" && "$(cat "$resolved/idVendor" 2>/dev/null)" == "12d1" ]]; then
        basename "$resolved"
        return 0
      fi
      local parent=""
      parent="$(dirname "$resolved")"
      [[ "$parent" == "$resolved" ]] && break
      resolved="$parent"
    done
  fi

  local devpath=""
  for devpath in /sys/bus/usb/devices/*; do
    [[ -f "$devpath/idVendor" && -f "$devpath/idProduct" ]] || continue
    if [[ "$(cat "$devpath/idVendor" 2>/dev/null)" == "12d1" ]]; then
      basename "$devpath"
      return 0
    fi
  done
  return 1
}

current_hilink_bases() {
  local iface=""
  local addr=""
  local base=""
  local seen=""
  local octet=""

  if [[ -n "${BASE_URL:-}" ]]; then
    printf '%s\n' "${BASE_URL%/}"
    return 0
  fi

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

  while IFS= read -r addr; do
    [[ "$addr" =~ ^192\.168\.[0-9]+\.[0-9]+$ ]] || continue
    base="http://${addr%.*}.1"
    if [[ " $seen " != *" $base "* ]]; then
      printf '%s\n' "$base"
      seen="$seen $base"
    fi
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

  octet="$(ordinal_octet "${ORDINAL:-}" 2>/dev/null || true)"
  if [[ -n "$octet" ]]; then
    base="http://192.168.${octet}.1"
    if [[ " $seen " != *" $base "* ]]; then
      printf '%s\n' "$base"
      seen="$seen $base"
    fi
  fi

  for base in "http://192.168.8.1" "http://192.168.1.1"; do
    if [[ " $seen " != *" $base "* ]]; then
      printf '%s\n' "$base"
      seen="$seen $base"
    fi
  done
}

live_hilink_bases() {
  local base=""
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    if curl_hilink -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
      printf '%s\n' "$base"
    fi
  done < <(current_hilink_bases)
}

find_hilink_base() {
  local bases=()
  mapfile -t bases < <(live_hilink_bases)
  case "${#bases[@]}" in
    0) return 1 ;;
    1)
      printf '%s' "${bases[0]}"
      return 0
      ;;
    *)
      printf 'ERROR: multiple live HiLink modems detected: %s\n' "${bases[*]}" >&2
      return 2
      ;;
  esac
}

get_hilink_token() {
  local base="$1"
  local cookiejar="$2"
  curl_hilink -fsS --max-time 10 -c "${cookiejar}" "${base}/api/webserver/SesTokInfo" 2>/dev/null | extract_tag "TokInfo"
}

get_hilink_page_token() {
  local base="$1"
  local page="$2"
  local cookiejar="$3"
  curl_hilink -fsS --max-time 10 -c "${cookiejar}" "${base}${page}" 2>/dev/null | sed -n 's:.*<meta name="csrf_token" content="\([^"]*\)".*:\1:p' | head -n 1
}

hilink_post_dhcp_settings() {
  local base="$1"
  local body="$2"
  local cookiejar=""
  local token=""
  local resp=""

  cookiejar="$(mktemp)"
  token="$(get_hilink_page_token "$base" "/html/dhcp.html" "$cookiejar")"
  [[ -n "$token" ]] || token="$(get_hilink_token "$base" "$cookiejar")"
  [[ -n "$token" ]] || {
    rm -f "$cookiejar"
    return 1
  }

  resp="$(curl_hilink -fsS --max-time 20 \
    -b "$cookiejar" -c "$cookiejar" \
    -H "Accept: */*" \
    -H "Origin: ${base}" \
    -H "Referer: ${base}/html/dhcp.html" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "__RequestVerificationToken: ${token}" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -X POST \
    -d "$body" \
    "${base}/api/dhcp/settings" 2>/dev/null || true)"

  rm -f "$cookiejar"
  [[ "$resp" == *"<response>OK</response>"* ]]
}

wait_for_base() {
  local base="$1"
  local timeout="${2:-180}"
  local i=0
  while (( i < timeout )); do
    if curl_hilink -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
      return 0
    fi
    sleep 2
    ((i+=2))
  done
  return 1
}

apply_dhcp_mode() {
  local iface="$1"
  [[ -n "$iface" ]] || return 1
  clear_stale_nm_unmanaged_for_modem "$iface"
  "${SUDO[@]}" ip link set "$iface" up 2>/dev/null || true
  "${SUDO[@]}" ip addr flush dev "$iface" 2>/dev/null || true
  if command -v nmcli >/dev/null 2>&1; then
    "${SUDO[@]}" nmcli device set "$iface" managed yes 2>/dev/null || true
    "${SUDO[@]}" nmcli connection modify "$iface" \
      ipv4.method auto \
      ipv4.addresses "" \
      ipv4.gateway "" \
      ipv4.routes "" \
      ipv4.route-metric 1000 \
      ipv4.ignore-auto-routes no \
      ipv4.ignore-auto-dns no \
      ipv4.never-default yes \
      ipv6.method link-local 2>/dev/null || true
    "${SUDO[@]}" nmcli device reapply "$iface" 2>/dev/null || true
    "${SUDO[@]}" nmcli connection up "$iface" 2>/dev/null || true
  fi
  return 0
}

clear_stale_nm_unmanaged_for_modem() {
  local iface="${1:-}"
  local usb_port=""

  usb_port="$(find_huawei_usbdev 2>/dev/null || true)"
  if [[ -f "$NM_ONLY_UDEV_RULE" ]]; then
    "${SUDO[@]}" rm -f "$NM_ONLY_UDEV_RULE" 2>/dev/null || true
    "${SUDO[@]}" udevadm control --reload-rules || true
  fi

  if [[ -n "$usb_port" && -e "/sys/bus/usb/devices/${usb_port}" ]]; then
    "${SUDO[@]}" udevadm trigger --action=change "/sys/bus/usb/devices/${usb_port}" || true
  fi

  if [[ -n "$iface" ]] && command -v nmcli >/dev/null 2>&1; then
    "${SUDO[@]}" nmcli device set "$iface" managed yes 2>/dev/null || true
  fi
}

main() {
  local octet=""
  local target_base=""
  local base=""
  local modem_ip=""
  local start_ip=""
  local end_ip=""
  local payload=""
  local iface=""

  need_cmd curl
  need_cmd ip
  need_cmd udevadm

  octet="$(ordinal_octet "${ORDINAL:-}")" || die "use --ordinal N, where N is modem ordinal"
  target_base="http://192.168.${octet}.1"

  base="$(find_hilink_base 2>/dev/null || true)"
  [[ -n "$base" ]] || die "no live HiLink modem found"
  if [[ "$base" == "$target_base" ]]; then
    log "Modem already on target base ${target_base}"
    exit 0
  fi

  modem_ip="192.168.${octet}.1"
  start_ip="192.168.${octet}.100"
  end_ip="192.168.${octet}.200"
  payload="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><DhcpIPAddress>${modem_ip}</DhcpIPAddress><DhcpLanNetmask>255.255.255.0</DhcpLanNetmask><DhcpStatus>1</DhcpStatus><DhcpStartIPAddress>${start_ip}</DhcpStartIPAddress><DhcpEndIPAddress>${end_ip}</DhcpEndIPAddress><DhcpLeaseTime>86400</DhcpLeaseTime><DnsStatus>1</DnsStatus><PrimaryDns>0.0.0.0</PrimaryDns><SecondaryDns>0.0.0.0</SecondaryDns></request>"

  log "Changing modem LAN IP from ${base} to ${target_base}"
  hilink_post_dhcp_settings "$base" "$payload" || die "dhcp/settings request failed"

  iface="$(get_live_modem_iface 2>/dev/null || true)"
  if [[ -n "$iface" ]]; then
    log "Switching host iface ${iface} back to DHCP mode"
    apply_dhcp_mode "$iface"
  else
    clear_stale_nm_unmanaged_for_modem
  fi

  log "Waiting for modem reboot and ${target_base}"
  wait_for_base "$target_base" 180 || die "modem did not come back on ${target_base}"
  log "Modem is live on ${target_base}"
}

main "$@"
