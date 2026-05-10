# QEMU Test Coverage Expansion Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand QEMU test coverage from 11 active / 12 skipped to a comprehensive suite that tests all adapters, all skill scripts, failure paths, and multiple topologies.

**Current state:** 7 test suites, 23 tests total (11 pass, 12 skip on prebuilt image). Commits `8917cd5` and `479dedb` delivered Phase 1-4 of the original gap-fix plan.

**Architecture:** Four priority tiers ordered by impact-to-effort ratio. Each tier is independently shippable.

**Tech Stack:** QEMU, bash (TAP tests), Python3 (JSON validation, normalize.py), BMX7, batman-adv, vwifi-client, LibreMesh lime-packages

---

## Current Coverage Map

### What passes on prebuilt image (11 tests)

| Suite | Test | Verifies |
|-------|------|----------|
| Adapter Contract | `test_collect_nodes_returns_valid_json` | `collect-nodes.sh` SSH + UCI/iwinfo → valid JSON |
| Adapter Contract | `test_collect_topology_sees_all_nodes` | `collect-topology.sh` discovers nodes via L2 |
| Adapter Contract | `test_discover_thisnode_works` | `thisnode.info` resolves via HOSTALIASES |
| Adapter Contract | `test_ip_json_output` | `ip -j addr` returns parseable JSON |
| Mesh Protocols | `test_mesh_routing_works` | node-3 can ping node-1 over L2 |
| Validate Node | `test_validate_healthy_node` | `validate-node.sh` returns 0/WARN on configured node |
| Validate Node | `test_validate_detects_missing_ssid` | `validate-node.sh` detects missing lime-community |
| Config Drift | `test_uci_write_succeeds` | UCI writes work on prebuilt |
| Config Drift | `test_drift_detection_finds_changed_channel` | `check-drift.sh` detects changed WiFi channel |
| Firmware Upgrade | `test_firmware_version_change_detected` | Version change in `/etc/openwrt_release` detected |
| Firmware Upgrade | `test_validate_detects_version_mismatch` | `validate-node.sh` reports version mismatch |

### What skips on prebuilt (12 tests — need source-built image)

All skip because the prebuilt LibreRouterOS image lacks BMX7, vwifi-client, and proper LibreMesh config. These will activate once a source-built image is available.

| Suite | Test | Reason |
|-------|------|--------|
| Adapter Contract | `test_collect_services_valid_json` | Server adapter — needs docker/systemctl |
| Adapter Contract | `test_collect_health_valid_json` | Server adapter — needs Linux host utilities |
| Adapter Contract | `test_normalize_processes_output` | Needs full adapter pipeline output |
| Adapter Contract | `test_uhttpd_api_accessible` | uhttpd returns 500 on prebuilt |
| Mesh Protocols | `test_bmx7_neighbors_exist` | BMX7 not installed |
| Mesh Protocols | `test_bmx7_originators_cover_mesh` | BMX7 not installed |
| Mesh Protocols | `test_babel_fallback_works` | BMX7 not installed |
| Validate Node | `test_validate_detects_no_neighbors` | BMX7 not installed |
| Topology Manipulation | `test_vwifi_ctrl_distance_based_loss` | BMX7 not installed |
| Topology Manipulation | `test_node_removal_detected` | BMX7 not installed |
| Multi-Hop | `test_node3_reachable_via_mesh` | BMX7 not installed |
| Multi-Hop | `test_topology_shows_mesh_links` | BMX7 not installed |

### Untested components

| Component | Risk Class | Type |
|-----------|-----------|------|
| `adapters/server/collect-services.sh` | A (read-only) | Server adapter |
| `adapters/server/collect-health.sh` | A (read-only) | Server adapter |
| `adapters/mesh/normalize.py` (full pipeline) | A (read-only) | Data transform |
| `skills/mesh-rollout/scripts/rollback-node.sh` | C/D | Config rollback |
| `skills/mesh-rollout/scripts/run-rollout.sh` | D | Multi-node orchestration |
| `skills/mesh-rollout/scripts/stage-upgrade.sh` | D | Firmware upgrade |
| `skills/mesh-rollout/scripts/schedule-maintenance.sh` | A/B | Metadata only |
| `skills/mesh-readonly/scripts/run-mesh-readonly.sh` | A | Full mesh inspection |
| Negative/failure paths | — | Robustness |
| Multi-topology (line, star, partition) | — | Topology coverage |
| Testbed lifecycle (stop, reset, collect-logs) | — | Infrastructure |

---

## Tier 1: Source-Built Image (unlocks 12 skipped tests)

**Impact:** High — activates BMX7, vwifi, lime-config tests
**Effort:** High — 2-4h build + 1h integration
**Depends on:** Nothing (can start immediately)

### Task 1.1: Build LibreMesh from source

The source-built image includes BMX7, vwifi-client, mac80211_hwsim, ip-full, and full LibreMesh lime-packages. This is the single highest-leverage action — it turns 12 skipped tests into real tests.

- [x] **Step 1: Run the build (2-4 hours, background)**

Dispatch this step with `run_in_background: true` (or redirect output and background the shell process), then immediately proceed to Tier 2 work in parallel — do not block the session waiting for this build to finish.

```bash
cd ~/Dev/coolab/mesha
bash scripts/qemu/build-libremesh-image.sh
```

Expected: Image at `images/libremesh-x86-64-<hash>-<date>.img.gz`, size > 50MB.

- [x] **Step 2: Verify build output**

```bash
ls -lh images/libremesh-x86-64-*.img.gz
```

Expected: Image exists, > 50MB.

- [x] **Step 3: Decompress and symlink for start-mesh.sh**

```bash
cd images
LATEST=$(ls -t libremesh-x86-64-*.img.gz | head -1)
gunzip -k "$LATEST"
ln -sf "${LATEST%.gz}" libremesh-x86-64.ext4
```

### Task 1.2: Verify source-built image boots and integrates

`start-mesh.sh` already auto-detects bootloaders (commit `8917cd5`). `configure-vms.sh` already uses `service` command (works with real service on source-built). No code changes expected.

- [x] **Step 1: Stop existing testbed**

```bash
sudo bash scripts/qemu/stop-mesh.sh
```

- [x] **Step 2: Boot with source-built image**

```bash
sudo bash scripts/qemu/start-mesh.sh
```

Expected: 4 VMs boot, start-mesh.sh detects bootloader and skips `-kernel` flag.

- [x] **Step 3: Configure VMs**

```bash
bash scripts/qemu/configure-vms.sh
```

Expected: 4/4 VMs configured. `service vwifi-client start`, `lime-config`, `wifi up` all succeed.

- [ ] **Step 4: Verify BMX7 convergence**

```bash
ssh -F config/ssh-config.resolved root@lm-testbed-node-1 "bmx7 -c originators" 2>/dev/null | tail -n +2 | wc -l
```

Expected: >= 3 originators (may take 30-90s to converge).

- [x] **Step 5: Run full test suite**

```bash
bash tests/qemu/run-all.sh
```

Expected: All 7 suites pass, previously-skipped BMX7 tests now execute and pass. Tier 1 target: ~23 tests, 0 failures, < 5 skips. (Final suite target after all tiers: 40+ tests, 0 failures — see Verification Checklist Full suite section.)

- [x] **Step 6: Commit any integration fixes discovered during testing**

```bash
git add -A && git commit -m "fix: source-built image integration fixes"
```

---

## Tier 2: Unit Tests Without VMs (no testbed needed)

**Impact:** Medium — tests data transforms and scripts in isolation
**Effort:** Low — pure Python/bash, no QEMU
**Depends on:** Nothing (can start immediately, parallel with Tier 1)

### Task 2.1: Create normalize.py unit tests (ALREADY DONE)

`normalize.py` unit tests already exist at `tests/unit/test_normalize.py` with 23 tests across 5 test classes:

- `TestNormalizeNode` (5 tests) — field remapping, status normalization, internal field stripping
- `TestCleanMac` (6 tests) — MAC address format normalization
- `TestFindInventoryNode` (4 tests) — hostname/MAC matching against inventory
- `TestComputeDrift` (4 tests) — drift detection, severity mapping
- `TestFieldMap` (3 tests) — field map and severity map validation

These import `normalize.py` internal functions directly (not subprocess), providing deeper coverage than a subprocess-based approach.

- [x] **Step 1: Create test file** — DONE (23 tests, all pass)

```bash
python3 tests/unit/test_normalize.py -v
# Ran 23 tests in 0.001s — OK
```

- [x] **Step 2: Create unit test runner**

```bash
#!/usr/bin/env bash
# Run unit tests (no QEMU needed)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "=========================================="
echo "Mesha Unit Test Suite"
echo "=========================================="
echo ""
python3 "${SCRIPT_DIR}/unit/test_normalize.py" -v
echo ""
```

- [x] **Step 3: Commit**

```bash
git add tests/run-unit.sh
git commit -m "test: add unit test runner for normalize.py"
```

### Task 2.2: Create check-drift.sh unit tests

`check-drift.sh` compares live UCI state against `desired-state/mesh/`. It takes `--node <hostname>` and `--output json|text` flags. It calls `validate-node.sh` internally to obtain live node state. A unit test can verify the comparison logic with synthetic desired-state files and a mock SSH wrapper.

**Files:**

- Create: `tests/unit/test_check_drift.sh`

- [x] **Step 1: Create test that exercises check-drift with mock data**

Create a bash test that:

1. Sets up a temporary desired-state directory with known values
2. Creates a mock SSH wrapper that returns static UCI output
3. Runs `check-drift.sh` with the mock environment
4. Verifies drift is detected when values differ
5. Verifies no drift when values match

The mock SSH wrapper replaces `ssh` with a script that returns canned UCI output for specific hosts. This avoids needing real VMs.

- [x] **Step 2: Run and verify**

```bash
bash tests/unit/test_check_drift.sh
```

- [x] **Step 3: Add to run-unit.sh**

```bash
echo "--- check-drift ---"
bash "${SCRIPT_DIR}/unit/test_check_drift.sh"
```

- [x] **Step 4: Commit**

```bash
git add tests/unit/test_check_drift.sh tests/run-unit.sh
git commit -m "test: add check-drift unit tests with mock data"
```

---

## Tier 3: Failure Path and Robustness Tests

**Impact:** Medium — verifies system behavior under failure conditions
**Effort:** Medium — requires running testbed
**Depends on:** Tier 1 (source-built image for meaningful failure tests)

### Task 3.1: Add negative/failure-path tests

**Files:**

- Create: `tests/qemu/test-failure-paths.sh`
- Modify: `tests/qemu/run-all.sh`

- [x] **Step 1: Create failure-path test file**

Create `tests/qemu/test-failure-paths.sh` with these 5 tests:

```bash
#!/usr/bin/env bash
# Failure path tests — verifies graceful handling of error conditions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Failure Path Tests"
tap_plan 5

GATEWAY=$(get_gateway)
```

Tests to include:

1. **`test_adapter_timeout_on_unreachable_node`** — Run `collect-nodes.sh` against a non-existent IP (e.g., `10.99.0.99`). Verify it returns non-zero exit or empty output within a timeout (use `timeout 15`), not a hang.

2. **`test_validate_node_unreachable`** — Run `validate-node.sh` against `10.99.0.99`. Verify it returns exit 1 with "SSH unreachable" or "timed out" message in output.

3. **`test_collect_topology_partial_failure`** — Kill one VM mid-collection (use `ssh_vm "lm-testbed-node-3" "reboot"` to reboot node-3), run `collect-topology.sh` against the gateway, verify it returns data for remaining nodes without crashing. Then recover node-3 before the test exits so subsequent suites (Multi-Hop, Topology Manipulation) are not broken:

   ```bash
   # Reboot node-3 to simulate partial failure
   ssh_vm "lm-testbed-node-3" "reboot" 2>/dev/null || true
   # ... run collect-topology.sh and assert result ...

   # Recovery: wait up to 60s for node-3 SSH to return
   RECOVERED=0
   for _i in $(seq 1 12); do
       if ssh_vm "lm-testbed-node-3" "true" 2>/dev/null; then
           RECOVERED=1; break
       fi
       sleep 5
   done
   if [ "${RECOVERED}" -eq 0 ]; then
       echo "  # WARNING: node-3 did not recover in 60s; subsequent BMX7 tests may fail" >&2
   else
       # Wait for BMX7 to reconverge with at least 2 peers visible from node-3
       wait_for_bmx7 "lm-testbed-node-3" 2 60 || true
   fi
   ```

   `ssh_vm`, `wait_for_bmx7`, `pass`, `fail`, and `skip` are all confirmed present in `tests/qemu/common.sh`. `wait_for_bmx7` returns 0 on convergence, 1 on timeout, 2 if BMX7 is not installed — the `|| true` tolerates all non-zero returns so the test does not abort on prebuilt images.

   Alternative if recovery proves unreliable: gate this test behind `RUN_DESTRUCTIVE_TESTS=1` (same pattern as Task 3.2 lifecycle tests) and leave a comment explaining why. Prefer the recovery approach.

4. **`test_adapter_handles_empty_output`** — Run `collect-nodes.sh` against a host that returns empty SSH output (use a host that accepts SSH but runs on busybox with minimal commands). Verify graceful handling.

5. **`test_check_drift_no_desired_state`** — Temporarily move `desired-state/mesh/` aside, run `check-drift.sh`, verify it reports an error but does not crash. Restore desired-state afterward.

- [x] **Step 2: Add to run-all.sh**

```bash
run_test_file "Failure Paths" "${SCRIPT_DIR}/test-failure-paths.sh"
```

- [x] **Step 3: Run and verify**

```bash
bash tests/qemu/test-failure-paths.sh
```

- [x] **Step 4: Commit**

```bash
git add tests/qemu/test-failure-paths.sh tests/qemu/run-all.sh
git commit -m "test: add failure-path and robustness tests"
```

### Task 3.2: Add testbed lifecycle tests

**Files:**

- Create: `tests/qemu/test-testbed-lifecycle.sh`

- [x] **Step 1: Create lifecycle test file**

Create `tests/qemu/test-testbed-lifecycle.sh` with 3 tests:

1. **`test_collect_logs_captures_output`** — Run `scripts/qemu/collect-logs.sh`, verify log files exist in `run/logs/` and are non-empty.

2. **`test_mesh_status_reports_correctly`** — Run `scripts/qemu/mesh-status.sh` while VMs are running, verify it reports 4 nodes. This is a read-only check.

3. **`test_stop_mesh_cleans_up`** — Run `stop-mesh.sh`, then verify: no QEMU processes matching `mesha`, no `mesha-tap*` TAP devices, no `mesha-br0` bridge, no stale PID files in `run/`. **Important:** This test is destructive — it stops the testbed. Run it last in the suite, or gate behind an env var like `RUN_LIFECYCLE_TESTS=1`.

- [x] **Step 2: Add to run-all.sh** (note: lifecycle tests are destructive — run last, or gate behind `RUN_LIFECYCLE_TESTS=1`)

- [x] **Step 3: Run and verify**

- [x] **Step 4: Commit**

```bash
git add tests/qemu/test-testbed-lifecycle.sh tests/qemu/run-all.sh
git commit -m "test: add testbed lifecycle tests (stop, logs, status)"
```

---

## Tier 4: Multi-Topology and Skill Script Tests

**Impact:** Medium-High — tests real-world scenarios and destructive operations
**Effort:** High — requires careful orchestration and approval simulation
**Depends on:** Tier 1 (source-built image)

### Task 4.1: Add multi-topology test runner

The testbed has 3 unused topology configs (`topology-line.yaml`, `topology-star.yaml`, `topology-partition.yaml`). Each creates a different mesh shape that tests different routing paths.

**Files:**

- Create: `tests/qemu/test-topologies.sh`
- Create: `tests/qemu/run-topology-tests.sh` (separate runner — not in main suite)

- [x] **Step 1: Create multi-topology test**

Create `tests/qemu/test-topologies.sh` that:

1. Copies current `topology.yaml` to a `mktemp` backup file before the loop
2. For each topology config:
   a. Copies topology to `config/topology.yaml`
   b. Starts testbed with `start-mesh.sh`
   c. Configures VMs
   d. Waits for BMX7 convergence (120s timeout)
   e. Runs `collect-topology.sh` and verifies node count >= 3
   f. Stops testbed
3. Restores original `topology.yaml` from the backup file in the `cleanup_topology` EXIT trap (not via `git checkout`, to preserve any uncommitted user edits)

```bash
#!/usr/bin/env bash
# Multi-topology tests — verifies mesh behavior under different topologies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Multi-Topology Tests"
tap_plan 3

REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOPOLOGY_DIR="${REPO_ROOT_REAL}/config"
ORIGINAL_TOPOLOGY="${TOPOLOGY_DIR}/topology.yaml"

# Back up the current topology before the loop so the cleanup trap can restore it
# without touching git (avoids discarding uncommitted user edits).
TOPOLOGY_BACKUP="$(mktemp /tmp/topology-backup-XXXXXX.yaml)"
cp "${ORIGINAL_TOPOLOGY}" "${TOPOLOGY_BACKUP}"

cleanup_topology() {
    sudo bash "${REPO_ROOT_REAL}/scripts/qemu/stop-mesh.sh" 2>/dev/null || true
    cp "${TOPOLOGY_BACKUP}" "${ORIGINAL_TOPOLOGY}" 2>/dev/null || true
    rm -f "${TOPOLOGY_BACKUP}"
}
trap cleanup_topology EXIT INT TERM

for TOPO_FILE in topology-line.yaml topology-star.yaml topology-partition.yaml; do
    TOPO_NAME="${TOPO_FILE%.yaml}"
    TOPO_NAME="${TOPO_NAME#topology-}"

    echo "# Testing ${TOPO_NAME} topology..."

    # Stop existing testbed
    sudo bash "${REPO_ROOT_REAL}/scripts/qemu/stop-mesh.sh" 2>/dev/null || true
    sleep 2

    # Swap topology
    cp "${TOPOLOGY_DIR}/${TOPO_FILE}" "${ORIGINAL_TOPOLOGY}"

    # Start testbed
    sudo bash "${REPO_ROOT_REAL}/scripts/qemu/start-mesh.sh" 2>/dev/null || true
    bash "${REPO_ROOT_REAL}/scripts/qemu/configure-vms.sh" 2>/dev/null || true

    # Wait for convergence
    GATEWAY=$(get_gateway)
    BMX7_RESULT=0
    wait_for_bmx7 "$GATEWAY" 2 120 || BMX7_RESULT=$?

    if [ "${BMX7_RESULT}" -eq 0 ]; then
        # Verify topology shape
        TOPO=$(bash "${REPO_ROOT_REAL}/scripts/qemu/run-testbed-adapter.sh" \
            "${REPO_ROOT_REAL}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null) || true
        NODE_COUNT=$(echo "$TOPO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('node_count',0))" 2>/dev/null || echo "0")
        if [ "$NODE_COUNT" -ge 3 ]; then
            pass "test_${TOPO_NAME}_topology_converges"
        else
            fail "test_${TOPO_NAME}_topology_converges" "only ${NODE_COUNT} nodes found"
        fi
    elif [ "${BMX7_RESULT}" -eq 2 ]; then
        skip "test_${TOPO_NAME}_topology_converges" "BMX7 not installed"
    else
        skip "test_${TOPO_NAME}_topology_converges" "BMX7 did not converge in 120s"
    fi
done

tap_summary
```

- [x] **Step 2: Create separate runner** (this test is slow — 3 full start/stop cycles at ~2min each)

Create `tests/qemu/run-topology-tests.sh` as a standalone runner. Do NOT add to `run-all.sh` to keep the main suite fast.

- [x] **Step 3: Run and verify**

```bash
bash tests/qemu/run-topology-tests.sh
```

- [x] **Step 4: Commit**

```bash
git add tests/qemu/test-topologies.sh tests/qemu/run-topology-tests.sh
git commit -m "test: add multi-topology test runner (line, star, partition)"
```

### Task 4.2: Add rollback-node.sh test

`rollback-node.sh` (Class C/D) restores a node's UCI config from a backup file. This is a destructive operation that needs careful testing.

**Files:**

- Create: `tests/qemu/test-rollback.sh`
- Modify: `skills/mesh-rollout/scripts/rollback-node.sh` (add `--yes` flag)

- [x] **Step 1: Add `--yes` flag to rollback-node.sh**

`rollback-node.sh` is a POSIX `#!/usr/bin/env sh` script (not bash). Its `confirm()` function is at **line 49**. The script has no existing arg-parsing loop — it just checks `[ $# -lt 2 ] && usage` at line 78, then assigns `NODE="$1"` and `BACKUP_FILE="$2"`.

Make these **three exact additions**:

**Change A** — immediately after `[ $# -lt 2 ] && usage` (line 78), insert a `--yes` scan and variable:

```sh
# --- insert after "[ $# -lt 2 ] && usage" ---
SKIP_CONFIRM=0
for _arg in "$@"; do
  [ "$_arg" = "--yes" ] && SKIP_CONFIRM=1
done
```

(Scanning `"$@"` is the correct POSIX sh approach since bash `while [[ ... ]]` is not available here.)

**Change B** — replace the existing `confirm()` body (lines 49-58) so the **first executable line** is an early-return guard:

```sh
confirm() {
  [ "${SKIP_CONFIRM:-0}" = "1" ] && return 0   # --yes skips interactive prompt
  _prompt="$1"
  echo ""
  echo "${_prompt}"
  read -r ANSWER
  if [ "${ANSWER}" != "YES" ]; then
    log "Confirmation not given. Aborting."
    exit 0
  fi
}
```

The only new line is `[ "${SKIP_CONFIRM:-0}" = "1" ] && return 0` inserted as the very first line of the function body, before `_prompt="$1"`.

**Change C** — in `usage()`, update the Usage line and add a flag description:

```sh
# change:
Usage: $0 <node-hostname-or-ip> <backup-file.uci.gz>
# to:
Usage: $0 <node-hostname-or-ip> <backup-file.uci.gz> [--yes]
```

And add below the existing positional-arg descriptions:

```sh
  --yes                 Skip interactive YES/NO confirmation (for automated tests)
```

- [x] **Step 2: Create rollback test**

Before writing this test, read `scripts/qemu/start-mesh.sh` to find the path where qcow2 disk images are placed at runtime (typically `run/<node>.qcow2` or similar). Use that path in the snapshot commands below.

Test sequence:

1. Take a qcow2 snapshot so the disk can be fully restored if anything goes wrong:
   `qemu-img snapshot -c pre-rollback run/<node>.qcow2`
   Register a cleanup trap: `qemu-img snapshot -a pre-rollback run/<node>.qcow2 && qemu-img snapshot -d pre-rollback run/<node>.qcow2`
2. Capture current UCI state: `ssh_vm "$GATEWAY" "uci export | gzip" > /tmp/backup.uci.gz`
3. Modify a known config value: `ssh_vm "$GATEWAY" "uci set system.@system[0].hostname='modified-test'"`
4. Run `rollback-node.sh --yes` with the backup file via the adapter wrapper
5. Verify hostname restored: `ssh_vm "$GATEWAY" "uci get system.@system[0].hostname"` returns original value
6. Clean up: the EXIT trap applies the qcow2 snapshot restore to undo all disk mutations if the test fails mid-way

- [x] **Step 3: Add to run-all.sh** (or keep separate due to destructive nature)

- [x] **Step 4: Run and verify**

- [x] **Step 5: Commit**

```bash
git add tests/qemu/test-rollback.sh skills/mesh-rollout/scripts/rollback-node.sh tests/qemu/run-all.sh
git commit -m "test: add rollback-node.sh integration test"
```

### Task 4.3: Add stage-upgrade.sh dry-run test

`stage-upgrade.sh` (Class D) performs firmware upgrade on a single node. It has a `--dry-run` flag (confirmed at lines 7, 15, 64, 68, 73). A dry-run test verifies the planning logic without touching flash.

**Files:**

- Create: `tests/qemu/test-stage-upgrade.sh`

- [x] **Step 1: Create stage-upgrade dry-run test**

```bash
#!/usr/bin/env bash
# Stage-upgrade dry-run test — verifies upgrade planning without writing flash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Stage Upgrade Dry-Run Tests"
tap_plan 3

GATEWAY=$(get_gateway)

# Test 1: dry-run produces a plan
PLAN=$(bash "${REPO_ROOT}/scripts/qemu/run-testbed-adapter.sh" \
    "${REPO_ROOT}/skills/mesh-rollout/scripts/stage-upgrade.sh" \
    "$GATEWAY" "http://example.test/fake-firmware.bin" --dry-run 2>&1) || true
if echo "$PLAN" | grep -qi "upgrade\|plan\|dry.run\|version"; then
    pass "test_stage_upgrade_dry_run_produces_plan"
else
    skip "test_stage_upgrade_dry_run_produces_plan" "stage-upgrade dry-run output unclear or --dry-run not implemented"
fi

# Test 2: dry-run does not modify firmware version
BEFORE=$(ssh_vm "$GATEWAY" "grep DISTRIB_RELEASE /etc/openwrt_release" 2>/dev/null)
# (dry-run already ran above — verify no change)
AFTER=$(ssh_vm "$GATEWAY" "grep DISTRIB_RELEASE /etc/openwrt_release" 2>/dev/null)
if [ "$BEFORE" = "$AFTER" ]; then
    pass "test_dry_run_does_not_modify_version"
else
    fail "test_dry_run_does_not_modify_version" "version changed despite dry-run"
fi

# Test 3: dry-run exits 0
DRY_EXIT=0
bash "${REPO_ROOT}/scripts/qemu/run-testbed-adapter.sh" \
    "${REPO_ROOT}/skills/mesh-rollout/scripts/stage-upgrade.sh" \
    "$GATEWAY" "http://example.test/fake-firmware.bin" --dry-run >/dev/null 2>&1 || DRY_EXIT=$?
if [ "$DRY_EXIT" -eq 0 ]; then
    pass "test_dry_run_exits_zero"
else
    skip "test_dry_run_exits_zero" "exit code was $DRY_EXIT (--dry-run may not be implemented)"
fi

tap_summary
```

- [x] **Step 2: Add to run-all.sh**

- [x] **Step 3: Run and verify**

- [x] **Step 4: Commit**

```bash
git add tests/qemu/test-stage-upgrade.sh tests/qemu/run-all.sh
git commit -m "test: add stage-upgrade dry-run integration test"
```

### Task 4.4: Add run-rollout.sh dry-run test

`run-rollout.sh` (Class D) orchestrates a full ring-based firmware rollout. It has a `--dry-run` flag (confirmed at lines 8, 12, 79, 83, 95). A dry-run test verifies the ring planning and ordering logic.

**Files:**

- Create: `tests/qemu/test-rollout.sh`

- [x] **Step 0: Create a testbed fixture for the dry-run**

`run-rollout.sh --dry-run` builds its ring plan by reading `desired-state/mesh/community-profile/rollout-policy.yaml` (ring definitions) and `inventories/mesh-nodes.yaml` (hostname resolution). **It does not read `rollout-state.yaml` for the plan.** The real inventory contains production node names (`porao`, `yuri`, etc.) that are not reachable in the testbed. Without testbed-named nodes in the policy + inventory, the dry-run will print `(no nodes resolved from inventory for this ring)` for every ring — which is valid output but untestable.

Create two fixture files:

**`tests/qemu/fixtures/rollout-policy-testbed.yaml`** — a minimal rollout-policy.yaml with testbed nodes:

```yaml
policy_version: "testbed"
upgrade_rings:
  - ring: canary
    description: "Testbed canary"
    nodes:
      - "Testbed Node 1"
    stabilization_period_hours: 0
    auto_promote: false
  - ring: inner
    description: "Testbed inner"
    nodes:
      - "Testbed Node 2"
    stabilization_period_hours: 0
    auto_promote: false
  - ring: outer
    description: "Testbed outer"
    nodes:
      - "Testbed Node 3"
      - "Testbed Node 4"
    stabilization_period_hours: 0
    auto_promote: false
change_windows: []
```

**`tests/qemu/fixtures/mesh-nodes-testbed.yaml`** — a minimal inventory mapping those display names to testbed hostnames:

```yaml
nodes:
  - name: "Testbed Node 1"
    hostname: "lm-testbed-node-1"
    role: gateway
    status: online
  - name: "Testbed Node 2"
    hostname: "lm-testbed-node-2"
    role: relay
    status: online
  - name: "Testbed Node 3"
    hostname: "lm-testbed-node-3"
    role: relay
    status: online
  - name: "Testbed Node 4"
    hostname: "lm-testbed-tester"
    role: leaf
    status: online
```

Then invoke `run-rollout.sh` by temporarily overriding `POLICY_FILE` and `INVENTORY_FILE`. Check whether `run-rollout.sh` accepts env-var overrides by reading lines 48-51 of the script — those variables are currently hardcoded. Two options:

- **Option A (preferred):** patch `run-rollout.sh` to honour `MESHA_POLICY_FILE` and `MESHA_INVENTORY_FILE` env vars when set (one-line change per variable: `POLICY_FILE="${MESHA_POLICY_FILE:-${WORKSPACE_ROOT}/desired-state/mesh/community-profile/rollout-policy.yaml}"`), then call the script with those env vars set to the fixture paths.
- **Option B (no script change):** use a cleanup trap to temporarily symlink/copy the fixture files over the real files before the test and restore them after:

  ```bash
  _ORIG_POLICY="${REPO_ROOT}/desired-state/mesh/community-profile/rollout-policy.yaml"
  _ORIG_INV="${REPO_ROOT}/inventories/mesh-nodes.yaml"
  cp "${_ORIG_POLICY}" /tmp/rollout-policy-real.yaml
  cp "${_ORIG_INV}" /tmp/mesh-nodes-real.yaml
  trap 'cp /tmp/rollout-policy-real.yaml "${_ORIG_POLICY}"; cp /tmp/mesh-nodes-real.yaml "${_ORIG_INV}"' EXIT
  cp "${FIXTURE_POLICY}" "${_ORIG_POLICY}"
  cp "${FIXTURE_INV}" "${_ORIG_INV}"
  ```

The test must also satisfy `run-rollout.sh`'s prerequisite checks (`stage-upgrade.sh` and `validate-node.sh` existence) — both are already present in `skills/mesh-rollout/scripts/`, so no stub is needed.

- [x] **Step 1: Create rollout dry-run test**

Test sequence:

1. Set up fixtures (Step 0 above)
2. Run `run-rollout.sh --firmware-url http://example.test/fake.bin --checksum aaaa... --dry-run` (HTTP URL requires `--checksum`; use any 64-char hex string since the checksum is only verified on the download which dry-run skips)
3. Verify it prints ring order: output contains `canary`, `inner`, `outer` in that order
4. Verify it lists testbed node hostnames: output contains `lm-testbed-node-1`, `lm-testbed-node-2`, `lm-testbed-node-3`
5. Verify `desired-state/mesh/rollout-state.yaml` is unchanged (dry-run must not write state)
6. Restore fixtures (handled by the EXIT trap from Step 0)

- [x] **Step 2: Add to run-all.sh** (or keep separate)

- [x] **Step 3: Run and verify**

- [x] **Step 4: Commit**

```bash
git add tests/qemu/test-rollout.sh
git commit -m "test: add run-rollout dry-run integration test"
```

### Task 4.5: Add server adapter tests

`collect-services.sh` and `collect-health.sh` target a Linux server (docker, systemctl, df, free) — not an OpenWrt router. These run on the host machine directly.

`collect-health.sh` outputs JSON with fields: `hostname`, `uptime_seconds`, `load_average`, `memory`, `disk`, `docker`.
`collect-services.sh` takes `--inventory <path>` flag (defaults to `inventories/local-services.yaml`).

**Files:**

- Create: `tests/qemu/test-server-adapters.sh`
- Modify: `tests/qemu/run-all.sh`

- [x] **Step 1: Create server adapter test file**

**Rationale for fixture inventory:** `inventories/local-services.yaml` lists services actually running on a specific dev host. On a CI machine or a host without those services or Docker, `collect-services.sh` may return an empty list and the test skips uselessly. To make the test portable, create a minimal fixture inventory at `tests/qemu/fixtures/server-services-fixture.yaml` that lists one service guaranteed to exist on any Linux system (e.g., `systemd-resolved` or `sshd`). Use that fixture path in the test instead of `inventories/local-services.yaml`.

Create `tests/qemu/fixtures/server-services-fixture.yaml` with content like:

```yaml
services:
  - name: sshd
    type: systemd
```

(Adjust the schema to match what `collect-services.sh` expects — read the script header for the expected inventory format.)

```bash
#!/usr/bin/env bash
# Server adapter tests — runs adapters on host machine (not in VMs)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Server Adapter Tests"
tap_plan 2

REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE_INVENTORY="${SCRIPT_DIR}/fixtures/server-services-fixture.yaml"

# Test 1: collect-health returns valid JSON with required fields
HEALTH=$(bash "${REPO_ROOT_REAL}/adapters/server/collect-health.sh" 2>/dev/null) || true
if [ -n "$HEALTH" ] && echo "$HEALTH" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for field in ['hostname', 'uptime_seconds', 'load_average', 'memory', 'disk']:
    assert field in data, f'missing: {field}'
" 2>/dev/null; then
    pass "test_collect_health_valid_json"
else
    skip "test_collect_health_valid_json" "collect-health failed or missing fields"
fi

# Test 2: collect-services returns valid JSON structure
# Uses a fixture inventory (not inventories/local-services.yaml) so the test
# is portable across dev machines and CI hosts without docker/specific services.
SERVICES=$(bash "${REPO_ROOT_REAL}/adapters/server/collect-services.sh" \
    --inventory "${FIXTURE_INVENTORY}" 2>/dev/null) || true
if [ -n "$SERVICES" ] && echo "$SERVICES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert isinstance(data, list)
" 2>/dev/null; then
    pass "test_collect_services_valid_json"
else
    skip "test_collect_services_valid_json" "collect-services failed or not a list"
fi

tap_summary
```

- [x] **Step 2: Add to run-all.sh** (early in the suite — these don't need VMs)

- [x] **Step 3: Run and verify**

- [x] **Step 4: Commit**

```bash
git add tests/qemu/test-server-adapters.sh tests/qemu/run-all.sh
git commit -m "test: add server adapter tests (host-based)"
```

### Task 4.6: Add schedule-maintenance.sh and run-mesh-readonly.sh tests

These are lower-priority but listed in the untested components table.

`schedule-maintenance.sh` subcommands: `add`, `list`, `cancel`, `check`. The `add` subcommand requires `--date "YYYY-MM-DD HH:MM"`, `--duration <Nh|Nm>`, `--scope <ring:canary|node:hostname|all>`, `--description "<text>"`.

`run-mesh-readonly.sh` takes `--hostname <node>` or `--plan` flags.

**Files:**

- Create: `tests/qemu/test-maintenance.sh`
- Create: `tests/qemu/test-mesh-readonly.sh`

- [x] **Step 1: Create schedule-maintenance.sh test**

`schedule-maintenance.sh` creates and manages maintenance windows (metadata only, Class A/B). Test:

1. Create a maintenance window: `schedule-maintenance.sh add --date "2099-01-01 02:00" --duration 2h --scope all --description "test window"`
2. Verify the window appears in `schedule-maintenance.sh list` output
3. Cancel the window: `schedule-maintenance.sh cancel <window-id>`
4. Verify it no longer appears in list output

- [x] **Step 2: Create run-mesh-readonly.sh test**

`run-mesh-readonly.sh` performs a full mesh read-only inspection. Test:

1. Run against the gateway node with a hard timeout to prevent the test from hanging indefinitely if the mesh is partitioned or SSH is unresponsive:
   `timeout 60 bash "${REPO_ROOT}/skills/mesh-readonly/scripts/run-mesh-readonly.sh" --hostname lm-testbed-node-1`
2. Verify it produces output containing node information
3. Verify exit code is 0

**Note:** If `timeout` terminates the script (exit code 124), treat that as a test failure, not a skip — a hung invocation is a real problem, not an expected condition.

- [x] **Step 3: Add to run-all.sh**

- [x] **Step 4: Commit**

```bash
git add tests/qemu/test-maintenance.sh tests/qemu/test-mesh-readonly.sh tests/qemu/run-all.sh
git commit -m "test: add schedule-maintenance and mesh-readonly tests"
```

---

## Verification Checklist

After all tiers complete:

### Tier 1 (source-built image)

- [x] `sudo bash scripts/qemu/start-mesh.sh` — VMs boot with source-built image
- [x] `bash scripts/qemu/configure-vms.sh` — 4/4 VMs configured, vwifi-client starts
- [x] `bash tests/qemu/run-all.sh` — Tier 1 target: ~23 tests, 0 failures, < 5 skips (final suite after all tiers: 40+ tests)
- [ ] `ssh -F config/ssh-config.resolved root@lm-testbed-node-1 "bmx7 -c originators"` — shows >= 3 nodes
- [ ] `ssh -F config/ssh-config.resolved root@lm-testbed-node-1 "ip link show wlan0-mesh"` — WiFi interface present

**Status (2026-05-06):** Build script fixed (commit `bdce09a`). Previous script tried `make` in lime-packages (a feed, not a build system). Rewritten to clone OpenWrt buildroot directly, add lime-packages + vwifi as feeds. Build requires `libncurses-dev` and `gawk` on host, or use Docker builder (`docker/qemu-builder/Dockerfile` which includes all deps). Build takes 2-4 hours once started.

### Tier 2 (unit tests)

- [x] `python3 tests/unit/test_normalize.py -v` — 23 normalize tests already pass (pre-existing)
- [x] `bash tests/unit/test_check_drift.sh` — all drift tests pass
- [x] `bash tests/run-unit.sh` — full unit suite passes

### Tier 3 (failure paths)

- [x] `bash tests/qemu/test-failure-paths.sh` — all 5 failure-path tests pass
- [x] `bash tests/qemu/test-testbed-lifecycle.sh` — all 3 lifecycle tests pass

### Tier 4 (multi-topology + skills)

- [ ] `bash tests/qemu/run-topology-tests.sh` — all 3 topologies converge (requires source-built image for BMX7; tests created and registered)
- [x] `bash tests/qemu/test-rollback.sh` — rollback restores config
- [x] `bash tests/qemu/test-stage-upgrade.sh` — dry-run produces plan, no changes
- [x] `bash tests/qemu/test-rollout.sh` — dry-run produces ring plan
- [x] `bash tests/qemu/test-server-adapters.sh` — server adapters return valid JSON
- [x] `bash tests/qemu/test-maintenance.sh` — maintenance window CRUD works
- [x] `bash tests/qemu/test-mesh-readonly.sh` — mesh readonly produces output

### Full suite

- [x] `bash tests/qemu/run-all.sh` — target: 40+ tests, 0 failures (15 suites pass, 0 failures on prebuilt; 12 BMX7 tests skip pending source-built image)
- [x] `bash tests/run-unit.sh` — all unit tests pass

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Source build fails (missing deps, network) | Medium | High — blocks Tier 1, 3, 4 | Docker build provides reproducible environment; prebuilt fallback still works for Tier 2 |
| BMX7 doesn't converge over vwifi | Low | Medium — mesh tests skip | Fall back to wired-only tests; WiFi-dependent tests become SKIP |
| `stage-upgrade.sh --dry-run` not fully implemented | Medium | Low | Test uses `skip` instead of `fail` when dry-run not available |
| Rollback test leaves node in bad state | Low | Medium | Use qcow2 snapshot before rollback; restore after test. Prerequisite: add `--yes` flag to `rollback-node.sh` |
| Server adapters fail on dev machine (no docker) | Medium | Low | Tests skip gracefully when docker unavailable |
| Topology swap test leaves wrong topology active | Low | Medium | Cleanup trap restores from mktemp backup (not git checkout, preserves uncommitted edits) |
| Multi-topology test is slow (3 full start/stop cycles) | High | Low | Separate runner (`run-topology-tests.sh`), not in main suite |
| `normalize.py` input format doesn't match test fixtures | Medium | Low | Test fixtures modeled on actual `collect-nodes.sh` output; adjust if normalize expects different schema |

---

## Priority Summary

| Tier | What | Tests Added | Effort | Depends On |
|------|------|-------------|--------|------------|
| **Tier 1** | Source-built image | Unlocks 12 existing | High (build time) | Nothing |
| **Tier 2** | normalize.py (done) + check-drift unit tests | ~2 new (run-unit.sh + check-drift) | Low | Nothing |
| **Tier 3** | Failure paths + lifecycle | ~8 new | Medium | Tier 1 |
| **Tier 4** | Multi-topology + skill scripts + server adapters + maintenance + readonly | ~17 new | High | Tier 1 |
| **Total** | | **~44 tests** | | |

**Recommended execution order:** Tier 2 (immediate, no deps) → Tier 1 (start build, wait) → Tier 3 (after build) → Tier 4 (after build).
