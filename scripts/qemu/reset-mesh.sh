#!/usr/bin/env bash
# Reset test bed to clean state (new qcow2 overlays from base image)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "Resetting test bed to clean state..."

# Stop running test bed
bash "${REPO_ROOT}/scripts/qemu/stop-mesh.sh" 2>/dev/null || true

# Remove old overlays
rm -f "${REPO_ROOT}/run/"*.qcow2
rm -f "${REPO_ROOT}/run/"*.pid
rm -f "${REPO_ROOT}/run/logs/"*.log

echo "Clean state ready. Start with:"
echo "  sudo bash scripts/qemu/start-mesh.sh"
