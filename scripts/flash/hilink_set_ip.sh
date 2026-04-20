#!/usr/bin/env bash
set -euo pipefail

ORDINAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ordinal) ORDINAL="${2:-}"; shift 2 ;;
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

ordinal_octet() {
  local ordinal="${1:-0}"
  [[ "$ordinal" =~ ^[0-9]+$ ]] || return 1
  (( ordinal > 0 && ordinal <= 154 )) || return 1
  printf '%s' "$((100 + ordinal))"
}

get_live_modem_iface() {
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
  local base=""
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

get_hilink_page_token() {
  local base="$1"
  local page="$2"
  local cookiejar="$3"
  curl -fsS --max-time 10 -c "${cookiejar}" "${base}${page}" 2>/dev/null | sed -n 's:.*<meta name="csrf_token" content="\([^"]*\)".*:\1:p' | head -n 1
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

  resp="$(curl -fsS --max-time 20 \
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
    if curl -fsS --max-time 5 "${base}/api/webserver/SesTokInfo" 2>/dev/null | grep -q "<TokInfo>"; then
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
  sudo ip link set "$iface" up 2>/dev/null || true
  sudo ip addr flush dev "$iface" 2>/dev/null || true
  if command -v nmcli >/dev/null 2>&1; then
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
    sudo nmcli device reapply "$iface" 2>/dev/null || true
    sudo nmcli connection up "$iface" 2>/dev/null || true
  fi
  return 0
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
  fi

  log "Waiting for modem reboot and ${target_base}"
  wait_for_base "$target_base" 180 || die "modem did not come back on ${target_base}"
  log "Modem is live on ${target_base}"
}

main "$@"
