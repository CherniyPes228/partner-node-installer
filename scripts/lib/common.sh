#!/usr/bin/env bash
###############################################################################
# Common utilities for all setup scripts
###############################################################################

set -euo pipefail

# Colors
readonly RED="\033[0;31m"
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly BLUE="\033[0;34m"
readonly NC="\033[0m"

# Logging functions
log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_err() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $*"
  fi
}

# Check if running as root
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_err "This script must be run as root"
    exit 1
  fi
}

# Check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Run command with logging
run_cmd() {
  log_debug "Executing: $*"
  "$@"
}

# Download file with retry
download_file() {
  local url=$1
  local dest=$2
  local max_attempts=3
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    log_info "Downloading $url (attempt $attempt/$max_attempts)"
    # Use wget with 5-minute timeout for large files
    if wget -q --timeout=300 -O "$dest" "$url"; then
      log_info "Downloaded successfully"
      return 0
    fi
    attempt=$((attempt + 1))
    if [[ $attempt -le $max_attempts ]]; then
      sleep 2
    fi
  done

  log_err "Failed to download $url after $max_attempts attempts"
  return 1
}

# Check if file/directory exists
file_exists() {
  [[ -f "$1" ]]
}

dir_exists() {
  [[ -d "$1" ]]
}

# Get OS info
get_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

# Check if running in container
is_container() {
  [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]]
}

# Export functions for use in sourced scripts
export -f log_info log_warn log_err log_debug
export -f require_root command_exists run_cmd
export -f download_file file_exists dir_exists
export -f get_distro is_container
