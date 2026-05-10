#!/usr/bin/env bash
# Run multi-topology tests (separate from main suite — slow, ~6min)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "LibreMesh Lab Multi-Topology Test Suite"
echo "=========================================="
echo ""
echo "WARNING: This test stops and restarts the testbed 3 times."
echo "Estimated duration: ~6 minutes."
echo ""

bash "${SCRIPT_DIR}/test-topologies.sh"
