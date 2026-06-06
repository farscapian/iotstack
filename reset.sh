#!/bin/bash
# reset.sh - Reset iotstack to clean state
# Unmounts tmpfs, removes all iotstack data, and reruns setup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOTSTACK_HOME="${HOME}/.iotstack"

echo "════════════════════════════════════════════════════════"
echo "iotstack Reset"
echo "════════════════════════════════════════════════════════"
echo

# Unmount tmpfs if mounted
if mount | grep -q "tmpfs.*${IOTSTACK_HOME}/secrets"; then
  echo "[INFO] Unmounting secrets tmpfs..."
  sudo umount "${IOTSTACK_HOME}/secrets" || {
    echo "[WARN] Failed to unmount tmpfs. Continuing..."
  }
fi

# Remove all iotstack data
echo "[INFO] Removing ~/.iotstack..."
rm -rf "$IOTSTACK_HOME"

echo "[INFO] Removing ~/.iotstack symlink from yamls..."
rm -f "${SCRIPT_DIR}/yamls/.iotstack"

echo

# Run setup
echo "[INFO] Running setup.sh..."
echo
"${SCRIPT_DIR}/setup.sh"

echo
echo "════════════════════════════════════════════════════════"
echo "Reset complete!"
echo "════════════════════════════════════════════════════════"
echo
echo "Next: iotstack rotate-secrets <role>"
