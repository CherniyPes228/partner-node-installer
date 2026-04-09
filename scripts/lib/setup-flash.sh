#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Setup safe modem flashing assets for E3372h-153
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MODEM_FLASH_ENABLED="${MODEM_FLASH_ENABLED:-true}"
FLASH_ASSETS_BASE_URL="${FLASH_ASSETS_BASE_URL:-https://chatmod.warforgalaxy.com/downloads/partner-node/flash}"
FLASH_ASSETS_FALLBACK_BASE_URL="${FLASH_ASSETS_FALLBACK_BASE_URL:-https://raw.githubusercontent.com/CherniyPes228/moderation_chat/main/public/downloads/partner-node/flash}"
FLASH_ROOT="${FLASH_ROOT:-/opt/partner-node-flash}"
FLASH_SCRIPT_PATH="${MODEM_FLASH_SCRIPT_PATH:-/usr/local/sbin/partner-node-flash-e3372h.sh}"
MANUAL_RECOVERY_PATH="${MODEM_NEEDLE_RECOVERY_PATH:-/usr/local/sbin/recover-e3372h-needle}"
INSTALLER_RAW_BASE_URL="${INSTALLER_RAW_BASE_URL:-https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main}"
FLASH_SCRIPT_SOURCE_BASE_URL="${FLASH_SCRIPT_SOURCE_BASE_URL:-${INSTALLER_RAW_BASE_URL}}"

write_flash_script() {
  download_asset "${FLASH_SCRIPT_SOURCE_BASE_URL}/scripts/flash/linux_flash_e3372h.sh" "${FLASH_SCRIPT_PATH}"
  chmod 0755 "${FLASH_SCRIPT_PATH}"
}

write_manual_recovery_wrapper() {
  download_asset "${FLASH_SCRIPT_SOURCE_BASE_URL}/scripts/recovery/recover_e3372h_needle_manual.sh" "${MANUAL_RECOVERY_PATH}"
  chmod 0755 "${MANUAL_RECOVERY_PATH}"
  ln -sf "${MANUAL_RECOVERY_PATH}" /usr/local/sbin/recover-e3372h-clean
}

install_manual_recovery() {
  local recovery_dir tools_dir
  recovery_dir="${FLASH_ROOT}/recovery"
  tools_dir="${FLASH_ROOT}/tools"
  mkdir -p "${recovery_dir}" "${tools_dir}" "$(dirname "${MANUAL_RECOVERY_PATH}")"

  log_info "Installing manual needle recovery helper"
  download_asset "${INSTALLER_RAW_BASE_URL}/scripts/assets/ptable-hilink.bin" "${tools_dir}/ptable-hilink.bin"
  download_asset "${INSTALLER_RAW_BASE_URL}/scripts/assets/balong_flash_recover_linux_amd64" "${tools_dir}/balong_flash_recover"

  chmod 0644 "${tools_dir}/ptable-hilink.bin" || true
  chmod 0755 "${tools_dir}/balong_flash_recover" || true
  write_manual_recovery_wrapper
  log_info "Manual needle recovery command installed: ${MANUAL_RECOVERY_PATH}"
}

download_asset() {
  local url="$1"
  local out="$2"
  curl -fsSL "${url}" -o "${out}"
}

download_asset_with_fallback() {
  local asset="$1"
  local out="$2"
  local primary_base="${FLASH_ASSETS_BASE_URL%/}"
  local fallback_base="${FLASH_ASSETS_FALLBACK_BASE_URL%/}"

  if download_asset "${primary_base}/${asset}" "${out}"; then
    return 0
  fi

  if [[ -n "${fallback_base}" && "${fallback_base}" != "${primary_base}" ]]; then
    log_warn "Primary flash asset URL failed for ${asset}, trying fallback ${fallback_base}"
    download_asset "${fallback_base}/${asset}" "${out}"
    return $?
  fi

  return 1
}

setup_flash() {
  require_root

  if [[ "${MODEM_FLASH_ENABLED}" != "true" ]]; then
    log_warn "Modem flash support is disabled"
    return 0
  fi

  if [[ -z "${FLASH_ASSETS_BASE_URL}" ]]; then
    log_warn "FLASH_ASSETS_BASE_URL is empty, skipping flash setup"
    return 0
  fi

  local tools_dir images_dir
  tools_dir="${FLASH_ROOT}/tools"
  images_dir="${FLASH_ROOT}/images"
  mkdir -p "${tools_dir}" "${images_dir}" "$(dirname "${FLASH_SCRIPT_PATH}")"

  log_info "Downloading safe flash assets from ${FLASH_ASSETS_BASE_URL}"
  download_asset_with_fallback "balong-usbload" "${tools_dir}/balong-usbload"
  download_asset_with_fallback "balong_flash" "${tools_dir}/balong_flash"
  download_asset "${INSTALLER_RAW_BASE_URL}/scripts/assets/balong_flash_recover_linux_amd64" "${tools_dir}/balong_flash_recover"
  download_asset_with_fallback "usbloader-3372h.bin" "${tools_dir}/usbloader-3372h.bin"
  download_asset_with_fallback "usblsafe-3372h.bin" "${tools_dir}/usblsafe-3372h.bin"
  download_asset_with_fallback "E3372h-153_Update_21.329.62.00.209.bin" "${images_dir}/E3372h-153_Update_21.329.62.00.209.bin"
  download_asset_with_fallback "E3372h-153_Update_21.329.05.00.00_M_01.10_for_.143.bin" "${images_dir}/E3372h-153_Update_21.329.05.00.00_M_01.10_for_.143.bin"
  download_asset_with_fallback "E3372h-153_Update_22.200.15.00.00_M_AT_05.10.bin" "${images_dir}/E3372h-153_Update_22.200.15.00.00_M_AT_05.10.bin"
  download_asset_with_fallback "Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin" "${images_dir}/Update_WEBUI_17.100.13.01.03_HILINK_Mod1.13.bin"
  download_asset_with_fallback "E3372h-153_Update_22.333.63.00.209_to_00.raw.bin" "${images_dir}/E3372h-153_Update_22.333.63.00.209_to_00.raw.bin"
  download_asset_with_fallback "WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin" "${images_dir}/WEBUI_17.100.18.03.143_HILINK_Mod1.21_BV7R11HS_CPIO.bin"

  chmod 0755 "${tools_dir}/balong-usbload" "${tools_dir}/balong_flash" "${tools_dir}/balong_flash_recover" || true
  chmod 0644 "${tools_dir}/usbloader-3372h.bin" "${tools_dir}/usblsafe-3372h.bin" || true
  chmod 0644 "${images_dir}/"*.bin || true
  write_flash_script
  install_manual_recovery
  log_info "Safe flash assets are installed into ${FLASH_ROOT}"
  log_info "✅ Flash setup complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_flash "$@"
fi
