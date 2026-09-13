#!/usr/bin/env bash
# ensure-websocat.sh
# Installs websocat (used for Home Assistant WebSocket API calls) if missing.
# Used only by setup.sh -- runtime commands just check for websocat and tell
# the user to re-run setup.sh if it's missing.

set -euo pipefail

ensure_websocat() {
  if command -v websocat &>/dev/null; then
    return 0
  fi

  echo "[INFO] Installing websocat..." >&2

  local install_dir="${HOME}/.local/bin"
  mkdir -p "$install_dir"

  # Try cargo first (most reliable)
  if command -v cargo &>/dev/null; then
    echo "[INFO] Installing websocat via cargo..." >&2
    if cargo install websocat --root "$install_dir" 2>&1 | grep -q "Installed"; then
      export PATH="$install_dir/bin:$PATH"
      echo "[OK] websocat installed via cargo to $install_dir/bin" >&2
      return 0
    fi
  fi

  # Try apt
  if command -v apt &>/dev/null; then
    echo "[INFO] Trying apt..." >&2
    if sudo apt update -qq && sudo apt install -y websocat >/dev/null 2>&1; then
      echo "[OK] websocat installed via apt" >&2
      return 0
    fi
  fi

  # Download latest prebuilt binary from GitHub
  echo "[INFO] Downloading websocat from GitHub releases..." >&2
  local arch
  arch=$(uname -m)

  # Map architecture to GitHub release naming
  local binary_name=""
  case "$arch" in
    x86_64)
      binary_name="websocat.x86_64-unknown-linux-musl"
      ;;
    aarch64)
      binary_name="websocat.aarch64-unknown-linux-musl"
      ;;
    *)
      echo "ERROR: Unsupported architecture: $arch. Install websocat manually from https://github.com/vi/websocat/releases" >&2
      return 1
      ;;
  esac

  # Download from latest release
  local download_url="https://github.com/vi/websocat/releases/download/v1.14.1/${binary_name}"

  if curl -sL "$download_url" -o "$install_dir/websocat" 2>/dev/null && [[ -s "$install_dir/websocat" ]]; then
    if file "$install_dir/websocat" | grep -q "ELF"; then
      chmod +x "$install_dir/websocat"
      export PATH="$install_dir:$PATH"
      echo "[OK] websocat installed to $install_dir" >&2
      return 0
    else
      echo "ERROR: Downloaded file is not a valid ELF binary" >&2
      return 1
    fi
  else
    echo "ERROR: Failed to download websocat from $download_url" >&2
    return 1
  fi
}
