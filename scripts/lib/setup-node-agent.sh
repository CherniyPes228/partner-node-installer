#!/usr/bin/env bash
###############################################################################
# Setup node-agent binary
# Downloads and installs node-agent executable
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
BINARY_URL="${BINARY_URL:-}"

setup_node_agent() {
  require_root

  if [[ -z "$BINARY_URL" ]]; then
    log_err "BINARY_URL is required"
    return 1
  fi

  log_info "Setting up node-agent..."
  log_info "Binary URL: $BINARY_URL"

  # Create install directory
  mkdir -p "$INSTALL_PREFIX"

  # Download binary
  local temp_binary="/tmp/node-agent-download"
  log_info "Downloading node-agent binary..."
  download_file "$BINARY_URL" "$temp_binary" || {
    log_err "Failed to download node-agent"
    return 1
  }

  # Verify binary is executable
  if ! file "$temp_binary" | grep -q "ELF 64-bit"; then
    log_err "Downloaded file is not a valid Linux binary"
    return 1
  fi

  # Install binary
  log_info "Installing node-agent to $INSTALL_PREFIX/node-agent"
  cp "$temp_binary" "$INSTALL_PREFIX/node-agent"
  chmod +x "$INSTALL_PREFIX/node-agent"
  chown root:root "$INSTALL_PREFIX/node-agent"

  # Verify installation
  if ! "$INSTALL_PREFIX/node-agent" -version >/dev/null 2>&1; then
    log_warn "Could not verify node-agent version (might fail at runtime)"
  else
    local version
    version=$("$INSTALL_PREFIX/node-agent" -version 2>&1 || echo "unknown")
    log_info "Installed node-agent version: $version"
  fi

  # Cleanup
  rm -f "$temp_binary"

  log_info "✅ node-agent setup complete"
}

# Run if sourced directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_node_agent "$@"
fi
