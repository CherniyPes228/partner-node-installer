#!/usr/bin/env bash
set -euo pipefail

MODEM_ID=""
ORDINAL=""
BASE_URL=""
IFACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modem-id) MODEM_ID="${2:-}"; shift 2 ;;
    --ordinal) ORDINAL="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --iface) IFACE="${2:-}"; shift 2 ;;
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

curl_hilink() {
  if [[ -n "${IFACE:-}" ]]; then
    curl --interface "${IFACE}" "$@"
  else
    curl "$@"
  fi
}

get_live_modem_iface() {
  if [[ -n "${IFACE:-}" ]]; then
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

current_hilink_bases() {
  local iface=""
  local addr=""
  local base=""
  local seen=""

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

wait_for_hilink_base() {
  local timeout="${1:-120}"
  local i=0
  local base=""

  while (( i < timeout )); do
    base="$(find_hilink_base 2>/dev/null || true)"
    if [[ -n "$base" ]]; then
      printf '%s' "$base"
      return 0
    fi
    sleep 2
    ((i+=2))
  done

  return 1
}

main() {
  local base=""
  local flash_args=()
  local set_ip_args=()

  [[ -x "$FLASH_SCRIPT" ]] || die "missing flash script: $FLASH_SCRIPT"
  [[ -x "$SET_IP_SCRIPT" ]] || die "missing set-ip script: $SET_IP_SCRIPT"
  [[ -n "${ORDINAL:-}" ]] || die "missing --ordinal"

  base="$(find_hilink_base 2>/dev/null || true)"
  [[ -n "$base" ]] || die "no live HiLink modem found"
  flash_args=(--modem-id "${MODEM_ID}" --ordinal "${ORDINAL}" --base-url "${base}")
  set_ip_args=(--ordinal "${ORDINAL}" --base-url "${base}")
  if [[ -n "${IFACE:-}" ]]; then
    flash_args+=(--iface "${IFACE}")
    set_ip_args+=(--iface "${IFACE}")
  fi

  log "Provisioning modem from ${base}"

  if [[ "$base" == "http://192.168.8.1" ]]; then
    echo "STAGE:flash"
    log "Stock HiLink detected on 192.168.8.1, running full flash"
    "$FLASH_SCRIPT" "${flash_args[@]}"

    log "Waiting for flashed modem to come back as live HiLink before LAN IP switch"
    BASE_URL=""
    base="$(wait_for_hilink_base 120 2>/dev/null || true)"
    [[ -n "$base" ]] || die "flashed modem did not come back as live HiLink"
    set_ip_args=(--ordinal "${ORDINAL}" --base-url "${base}")
    if [[ -n "${IFACE:-}" ]]; then
      set_ip_args+=(--iface "${IFACE}")
    fi

    echo "STAGE:set_ip"
    log "Flash completed on ${base}, switching modem LAN IP for ordinal ${ORDINAL}"
    "$SET_IP_SCRIPT" "${set_ip_args[@]}"
    echo "STAGE:completed"
    return 0
  fi

  echo "STAGE:set_ip"
  log "Non-stock HiLink detected on ${base}, skipping flash and changing only LAN IP"
  "$SET_IP_SCRIPT" "${set_ip_args[@]}"
  echo "STAGE:completed"
}

main "$@"
