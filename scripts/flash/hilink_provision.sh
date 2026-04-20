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

FLASH_SCRIPT="${FLASH_SCRIPT:-/usr/local/sbin/partner-node-flash-hilink.sh}"
SET_IP_SCRIPT="${SET_IP_SCRIPT:-/usr/local/sbin/partner-node-set-modem-ip.sh}"

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
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

main() {
  local base=""

  [[ -x "$FLASH_SCRIPT" ]] || die "missing flash script: $FLASH_SCRIPT"
  [[ -x "$SET_IP_SCRIPT" ]] || die "missing set-ip script: $SET_IP_SCRIPT"
  [[ -n "${ORDINAL:-}" ]] || die "missing --ordinal"

  base="$(find_hilink_base 2>/dev/null || true)"
  [[ -n "$base" ]] || die "no live HiLink modem found"

  log "Provisioning modem from ${base}"

  if [[ "$base" == "http://192.168.8.1" ]]; then
    echo "STAGE:flash"
    log "Stock HiLink detected on 192.168.8.1, running full flash"
    "$FLASH_SCRIPT" --modem-id "${MODEM_ID}" --ordinal "${ORDINAL}"

    echo "STAGE:set_ip"
    log "Flash completed, switching modem LAN IP for ordinal ${ORDINAL}"
    "$SET_IP_SCRIPT" --ordinal "${ORDINAL}"
    echo "STAGE:completed"
    return 0
  fi

  echo "STAGE:set_ip"
  log "Non-stock HiLink detected on ${base}, skipping flash and changing only LAN IP"
  "$SET_IP_SCRIPT" --ordinal "${ORDINAL}"
  echo "STAGE:completed"
}

main "$@"
