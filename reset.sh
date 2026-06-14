#!/bin/bash
# reset.sh - Reset iotstack to clean state
# Backs up the existing iotstack home (renamed with a timestamp) and reruns setup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source centralized configuration (resolves IOTSTACK_HOME and loads ~/.iotstack/.env)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

echo "════════════════════════════════════════════════════════"
echo "iotstack Reset"
echo "════════════════════════════════════════════════════════"
echo

# Back up the existing iotstack home instead of deleting it. config.sh ensures
# IOTSTACK_HOME exists, so always preserve whatever is there under a timestamp.
if [[ -d "$IOTSTACK_HOME" ]]; then
  backup_dir="${IOTSTACK_HOME}.bak-$(date +%Y%m%d-%H%M%S)"
  echo "[INFO] Backing up ${IOTSTACK_HOME} -> ${backup_dir}"
  mv "$IOTSTACK_HOME" "$backup_dir"
fi

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
echo "Previous data preserved at: ${backup_dir:-<none>}"
echo "Next: iotstack rotate-secrets <role>"
