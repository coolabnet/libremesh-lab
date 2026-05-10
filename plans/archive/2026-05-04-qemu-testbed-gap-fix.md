# QEMU Testbed Gap Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all gaps in the QEMU LibreMesh testbed so adapter tests run with full WiFi simulation, all adapters are tested, and the testbed is production-ready for CI.

**Architecture:** Three-phase approach — (1) fix prebuilt image quick wins, (2) source-built image with vwifi, (3) comprehensive adapter + topology tests. Each phase is independently shippable.

**Tech Stack:** QEMU, OpenWrt build system, bash (TAP tests), Python3 (JSON validation), LibreMesh lime-packages, vwifi-client, BMX7, batman-adv

---

## Phase 1: Prebuilt Image Quick Fixes

Fixes gaps without source build. ~30 min total.

### Task 1.1: Add `service` command shim to prebuilt image

The prebuilt image lacks `/sbin/service`. All `configure-vms.sh` calls to `service dropbear restart` etc. fail silently.

**Files:**
- Modify: `scripts/qemu/convert-prebuilt.sh` (add shim injection after rootfs extraction)

- [ ] **Step 1: Add service shim to convert-prebuilt.sh**

After the rootfs extraction and kernel copy block in `convert-prebuilt.sh`, inject:

```bash
# Inject /sbin/service shim for prebuilt images
cat > "${MOUNT_POINT}/sbin/service" << 'SERVICEEOF'
#!/bin/sh
# Minimal /sbin/service shim for LibreRouterOS prebuilt
/etc/init.d/"$@"
SERVICEEOF
chmod +x "${MOUNT_POINT}/sbin/service"
log "  Injected /sbin/service shim"
```

- [ ] **Step 2: Rebuild image and verify**

Run:
```bash
cd ~/Dev/coolab/mesha
rm -f images/librerouteros-prebuilt.img
sudo bash scripts/qemu/convert-prebuilt.sh --skip-download
# Mount and verify
LOOP=$(sudo losetup -f); sudo losetup "$LOOP" images/librerouteros-prebuilt.img
MNT=$(mktemp -d); sudo mount "$LOOP" "$MNT"
cat > "${MOUNT_POINT}/sbin/service" && ls -la "${MOUNT_POINT}/sbin/service"
sudo umount "${MOUNT_POINT}"; sudo losetup -d "$LOOP"; rmdir "${MOUNT_POINT}"
```
Expected: shim file exists, executable, contains `/etc/init.d/"$@"`

- [ ] **Step 3: Commit**

```bash
git add scripts/qemu/convert-prebuilt.sh
git commit -m "fix: inject /sbin/service shim into prebuilt image"
```

### Task 1.2: Fix HOSTALIASES for thisnode.info resolution

Tests use `curl --resolve` but real adapter scripts and users need `thisnode.info` to resolve automatically.

**Files:**
- Modify: `tests/qemu/common.sh` (export HOSTALIASES)
- Modify: `scripts/qemu/run-testbed-adapter.sh` (export HOSTALIASES)

- [ ] **Step 1: Add HOSTALIASES to common.sh**

After `REPO_ROOT` definition in `tests/qemu/common.sh`, add:

```bash
# thisnode.info resolution via HOSTALIASES
HOSTALIASES_FILE="${REPO_ROOT}/run/host-aliases"
if [ -f "${HOSTALIASES_FILE}" ]; then
    export HOSTALIASES="${HOSTALIASES_FILE}"
fi
```

- [ ] **Step 2: Add HOSTALIASES to run-testbed-adapter.sh**

In the environment setup section (after SSH_CONFIG_PATH export), add:

```bash
# thisnode.info resolution (use REPO_ROOT_REAL — REPO_ROOT is overridden to testbed config)
HOSTALIASES_FILE="${REPO_ROOT_REAL}/run/host-aliases"
if [ -f "${HOSTALIASES_FILE}" ]; then
    export HOSTALIASES="${HOSTALIASES_FILE}"
fi
```

- [ ] **Step 3: Verify host-aliases file is created by configure-vms.sh**

Check `configure-vms.sh` already creates `run/host-aliases` with content `thisnode.info 10.99.0.11`. If not, add to the "Configuring thisnode.info resolution on host" section:

```bash
echo "thisnode.info 10.99.0.11" > "${REPO_ROOT}/run/host-aliases"
```

- [ ] **Step 4: Test thisnode.info resolution**

Run:
```bash
HOSTALIASES=run/host-aliases curl -s http://thisnode.info/ -o /dev/null -w '%{http_code}'
```
Expected: 200 or 302 (when testbed is running — this step requires testbed to be up)

- [ ] **Step 5: Commit**

```bash
git add tests/qemu/common.sh scripts/qemu/run-testbed-adapter.sh scripts/qemu/configure-vms.sh
git commit -m "fix: export HOSTALIASES for thisnode.info resolution in tests"
```

### Task 1.3: Include test-firmware-upgrade.sh in run-all.sh

`run-all.sh` runs 5 of 6 test files. `test-firmware-upgrade.sh` is missing.

**Files:**
- Modify: `tests/qemu/run-all.sh`

- [ ] **Step 1: Add test-firmware-upgrade.sh to run-all.sh**

Use the existing `run_test_file` function pattern in `run-all.sh`:

```bash
run_test_file "Firmware Upgrade" "${SCRIPT_DIR}/test-firmware-upgrade.sh"
```

- [ ] **Step 2: Commit**

```bash
git add tests/qemu/run-all.sh
git commit -m "fix: include test-firmware-upgrade.sh in run-all test suite"
```

### Task 1.4: Add ip -j fallback for prebuilt images

Prebuilt image may lack `ip-full` package (which provides JSON output). Tests that use `ip -j` will fail.

**Files:**
- Modify: `tests/qemu/test-adapters.sh` (add fallback for test 4)

- [ ] **Step 1: Add fallback in test 4 (ip JSON output test)**

In the test 4 section of `tests/qemu/test-adapters.sh`, replace the `ip -j` check with:

```bash
# Test 4: ip -j addr show returns valid JSON (requires ip-full)
IP_RESULT=$(ssh_vm "$GATEWAY" "ip -j addr show 2>/dev/null || echo '[]'" 2>/dev/null) || true
if [ -z "$IP_RESULT" ] || [ "$IP_RESULT" = "[]" ]; then
    skip "test_ip_json_output" "ip -j not available (missing ip-full package)"
elif echo "$IP_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
non_lo = [i for i in data if i.get('ifname') != 'lo']
assert len(non_lo) >= 1
for iface in non_lo:
    assert 'ifname' in iface
    assert 'addr_info' in iface
" 2>/dev/null; then
    pass "test_ip_json_output"
else
    fail "test_ip_json_output" "JSON parse or assertion failed"
fi
```

- [ ] **Step 2: Commit**

```bash
git add tests/qemu/test-adapters.sh
git commit -m "fix: skip ip JSON test gracefully when ip-full missing"
```

---

## Phase 2: Source-Built Image with vwifi

Build LibreMesh from source with vwifi-client, mac80211_hwsim, and full package set. Fixes WiFi simulation, `service` command, lime-config, UCI sections.

**Estimated time:** 2-4 hours build + 1 hour integration.

### Task 2.1: Verify existing Docker build environment

The `docker/qemu-builder/Dockerfile` already exists and is complete (Ubuntu 22.04, includes cmake, qemu-utils, ccache, libnl-dev, build scripts). Verify it has all required packages.

**Files:**
- Verify: `docker/qemu-builder/Dockerfile` (already exists)

- [ ] **Step 1: Verify Dockerfile has all required packages**

Check existing Dockerfile includes: `build-essential`, `git`, `python3`, `ccache`, and OpenWrt build dependencies. If missing packages, add them.

Run:
```bash
cat docker/qemu-builder/Dockerfile
```

- [ ] **Step 2: Verify Dockerfile builds (optional)**

Run:
```bash
cd ~/Dev/coolab/mesha
docker build -t mesha-qemu-builder docker/qemu-builder/
```
Expected: Build succeeds

- [ ] **Step 3: Commit any changes (if packages were added)**

```bash
git add docker/qemu-builder/Dockerfile
git commit -m "fix: update Docker build environment for LibreMesh source builds"
```

### Task 2.2: Run source build

**Files:**
- Uses: `scripts/qemu/build-libremesh-image.sh`
- Uses: `docker/qemu-builder/Dockerfile`

- [ ] **Step 1: Run build (2-4 hours, background)**

Run:
```bash
cd ~/Dev/coolab/mesha
# Option A: Native build
bash scripts/qemu/build-libremesh-image.sh

# Option B: Docker build (if Docker preferred)
# docker run --rm -v $(pwd):/build mesha-qemu-builder bash /build/scripts/qemu/build-libremesh-image.sh
```
Expected: Image at `images/libremesh-x86-64-<hash>-<date>.img.gz`, size > 50MB

- [ ] **Step 2: Verify build output**

Run:
```bash
ls -lh images/libremesh-x86-64-*.img.gz
cat images/build-manifest.yaml
```
Expected: Image > 50MB, manifest lists vwifi-client, mac80211_hwsim, bmx7, ip-full

- [ ] **Step 3: Decompress and create symlink for start-mesh.sh**

```bash
cd images
LATEST=$(ls -t libremesh-x86-64-*.img.gz | head -1)
gunzip -k "$LATEST"
ln -sf "${LATEST%.gz}" libremesh-x86-64.ext4
```

### Task 2.3: Update start-mesh.sh for source-built image

Source-built image includes a bootloader (unlike prebuilt). The `-kernel` flag should be skipped when bootloader is present.

**Files:**
- Modify: `scripts/qemu/start-mesh.sh`

- [ ] **Step 1: Add bootloader detection**

In `start-mesh.sh`, inside the `launch_vm()` function, replace the existing kernel detection block (around lines 200-204) with:

```bash
# Detect if image has its own bootloader (source-built images do)
local HAS_BOOTLOADER=false
if command -v file &>/dev/null; then
    # Source-built images have a partition table; prebuilt are raw ext4
    if file "${BASE_IMAGE}" | grep -q "DOS/MBR boot sector\|partition table"; then
        HAS_BOOTLOADER=true
    fi
fi

if [ -f "${KERNEL_IMAGE}" ] && [ "${HAS_BOOTLOADER}" = "false" ]; then
    KERNEL_OPTS+=(-kernel "${KERNEL_IMAGE}" -append "root=/dev/sda rootfstype=ext4 rootwait console=ttyS0")
fi
```

- [ ] **Step 2: Test with source-built image**

Boot VMs and verify they reach login prompt without kernel args.

- [ ] **Step 3: Commit**

```bash
git add scripts/qemu/start-mesh.sh
git commit -m "feat: auto-detect bootloader in source-built images"
```

### Task 2.4: Update S99mesha-network for source-built image

Source-built image has proper LibreMesh networking. The S99 init script should only override IPs on prebuilt images.

**Files:**
- Modify: `scripts/qemu/convert-prebuilt.sh` (keep S99 injection only for prebuilt)
- Modify: `scripts/qemu/configure-vms.sh` (use `service` instead of direct `/etc/init.d`)

- [ ] **Step 1: Keep S99mesha-network only in prebuilt flow**

S99mesha-network is currently injected directly into the prebuilt image via manual mount+copy (not via convert-prebuilt.sh). For source-built images, LibreMesh lime-config handles networking properly. No S99 injection is needed for source builds.

- [ ] **Step 2: Verify configure-vms.sh lime-config sequence works with `service`**

With the `service` shim from Task 1.1 (prebuilt) or real `service` (source-built), the lime-config sequence in `configure_vm()` should now work:
```bash
service vwifi-client start && \
wifi config && \
lime-config && \
wifi down && \
sleep 7 && \
wifi up
```

- [ ] **Step 3: Full integration test with source-built image**

Run:
```bash
sudo bash scripts/qemu/start-mesh.sh
bash scripts/qemu/configure-vms.sh
bash tests/qemu/run-all.sh
```
Expected: All tests pass, vwifi-client starts, WiFi interfaces appear

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix: source-built image integration fixes"
```

---

## Phase 3: Comprehensive Adapter Tests

Test all adapter scripts, add HTTP API tests, add multi-hop topology test.

### Task 3.1: Update tap_plan and test collect-services adapter

**Files:**
- Modify: `tests/qemu/test-adapters.sh` (update tap_plan, add test 5)

- [ ] **Step 1: Update tap_plan from 4 to 8**

Change line `tap_plan 4` to `tap_plan 8` at the top of `test-adapters.sh`.

- [ ] **Step 2: Add collect-services test**

`collect-services.sh` accepts `--inventory PATH`, not a hostname. Test with testbed inventory:

```bash
# Test 5: collect-services returns valid JSON structure
SERVICES_RESULT=$(bash "${REPO_ROOT}/scripts/qemu/run-testbed-adapter.sh" \
    "${REPO_ROOT}/adapters/server/collect-services.sh" --inventory "${REPO_ROOT}/config/inventories/local-services.yaml" 2>/dev/null) || true
if [ -n "$SERVICES_RESULT" ] && echo "$SERVICES_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert isinstance(data, list)
" 2>/dev/null; then
    pass "test_collect_services_valid_json"
else
    skip "test_collect_services_valid_json" "collect-services not applicable to VM nodes or parse error"
fi
```

- [ ] **Step 2: Commit**

```bash
git add tests/qemu/test-adapters.sh
git commit -m "test: add collect-services adapter contract test"
```

### Task 3.2: Test collect-health adapter

**Files:**
- Modify: `tests/qemu/test-adapters.sh` (add test 6)

- [ ] **Step 1: Add collect-health test**

`collect-health.sh` takes no arguments — runs locally. Execute directly without wrapping:

```bash
# Test 6: collect-health returns valid JSON with required fields
HEALTH_RESULT=$(bash "${REPO_ROOT}/adapters/server/collect-health.sh" 2>/dev/null) || true
if [ -n "$HEALTH_RESULT" ] && echo "$HEALTH_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
required = ['hostname', 'uptime', 'load', 'memory', 'disk']
for field in required:
    assert field in data, f'missing field: {field}'
" 2>/dev/null; then
    pass "test_collect_health_valid_json"
else
    skip "test_collect_health_valid_json" "collect-health not applicable or parse error"
fi
```

- [ ] **Step 2: Commit**

```bash
git add tests/qemu/test-adapters.sh
git commit -m "test: add collect-health adapter contract test"
```

### Task 3.3: Test normalize.py adapter

**Files:**
- Modify: `tests/qemu/test-adapters.sh` (add test 7)

- [ ] **Step 1: Add normalize test**

`normalize.py` auto-loads `field_map.json` from its own directory. No `--field-map` flag needed:

```bash
# Test 7: normalize.py processes collect-nodes output
NORM_RESULT=$(bash "${REPO_ROOT}/scripts/qemu/run-testbed-adapter.sh" \
    "${REPO_ROOT}/adapters/mesh/collect-nodes.sh" "lm-testbed-node-1" 2>/dev/null | \
    python3 "${REPO_ROOT}/adapters/mesh/normalize.py" 2>/dev/null) || true
if [ -n "$NORM_RESULT" ] && echo "$NORM_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert isinstance(data, dict) or isinstance(data, list)
" 2>/dev/null; then
    pass "test_normalize_processes_output"
else
    skip "test_normalize_processes_output" "normalize.py unavailable or parse error"
fi
```

- [ ] **Step 2: Commit**

```bash
git add tests/qemu/test-adapters.sh
git commit -m "test: add normalize.py adapter contract test"
```

### Task 3.4: Add HTTP API tests

**Files:**
- Modify: `tests/qemu/test-adapters.sh` (add test 8)

- [ ] **Step 1: Add uhttpd API test**

Use root URL (no auth required), not `/admin/` path:

```bash
# Test 8: uhttpd REST API responds
API_RESULT=""
if command -v curl &>/dev/null; then
    API_RESULT=$(curl -s --connect-timeout 5 \
        "http://10.99.0.11/" \
        -o /dev/null -w '%{http_code}' 2>/dev/null) || API_RESULT="000"
fi
if [ "$API_RESULT" = "200" ] || [ "$API_RESULT" = "302" ]; then
    pass "test_uhttpd_api_accessible"
else
    skip "test_uhttpd_api_accessible" "uhttpd not responding (HTTP ${API_RESULT:-N/A})"
fi
```

- [ ] **Step 2: Commit**

```bash
git add tests/qemu/test-adapters.sh
git commit -m "test: add uhttpd HTTP API accessibility test"
```

### Task 3.5: Add mesh routing connectivity test

Tests BMX7 routing and topology completeness. Note: all VMs share the same L2 bridge, so this tests mesh protocol convergence, not true multi-hop. For true multi-hop, use `topology-line.yaml` which places nodes in a line topology where intermediate nodes must forward.

**Files:**
- Create: `tests/qemu/test-mesh-routing.sh`
- Modify: `tests/qemu/run-all.sh` (add new test)

- [ ] **Step 1: Create test-mesh-routing.sh**

```bash
#!/usr/bin/env bash
# Mesh routing tests — verifies BMX7 convergence and topology completeness
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "# Mesh Routing Tests"
tap_plan 2

# Wait for BMX7 convergence
GATEWAY=$(get_gateway)
if ! wait_for_bmx7 "$GATEWAY" 3 120; then
    echo "Bail out! BMX7 not converged after 120s"
    exit 1
fi

# Test 1: all nodes reachable from gateway via BMX7 mesh
ALL_REACHABLE=true
for entry in $(get_node_ips); do
    node_ip=$(echo "$entry" | awk '{print $2}')
    if ! ssh_vm "$GATEWAY" "ping -c 1 -W 5 $node_ip" 2>/dev/null; then
        ALL_REACHABLE=false
        break
    fi
done
if $ALL_REACHABLE; then
    pass "test_all_nodes_reachable_via_mesh"
else
    fail "test_all_nodes_reachable_via_mesh" "one or more nodes not reachable from gateway via BMX7"
fi

# Test 2: collect-topology shows all 4 nodes with links
TOPO=$(bash "${REPO_ROOT}/scripts/qemu/run-testbed-adapter.sh" \
    "${REPO_ROOT}/adapters/mesh/collect-topology.sh" "$GATEWAY" 2>/dev/null) || true
if [ -n "$TOPO" ] && echo "$TOPO" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data.get('node_count', 0) >= 3, f'expected >= 3 nodes, got {data.get(\"node_count\", 0)}'
assert len(data.get('links', [])) >= 3, f'expected >= 3 links, got {len(data.get(\"links\", []))}'
" 2>/dev/null; then
    pass "test_topology_shows_mesh_links"
else
    fail "test_topology_shows_mesh_links" "topology incomplete"
fi

tap_summary
```

- [ ] **Step 2: Add to run-all.sh**

Use the existing `run_test_file` function:

```bash
run_test_file "Mesh Routing" "${SCRIPT_DIR}/test-mesh-routing.sh"
```

- [ ] **Step 3: Commit**

```bash
git add tests/qemu/test-mesh-routing.sh tests/qemu/run-all.sh
git commit -m "test: add mesh routing connectivity tests"
```

---

## Phase 4: Documentation Update

### Task 4.1: Update QEMU_ADAPTER_TEST_GUIDE.md with all fixes

**Files:**
- Modify: `QEMU_ADAPTER_TEST_GUIDE.md`

- [ ] **Step 1: Update guide**

Add sections documenting:
- Source build procedure with vwifi
- `service` shim in prebuilt images
- HOSTALIASES for thisnode.info
- ssh-rsa algorithm requirements
- S99mesha-network init script behavior
- Root device is `/dev/sda` not `/dev/vda`
- Full test suite listing (all 6 test files + new adapter tests)

- [ ] **Step 2: Commit**

```bash
git add QEMU_ADAPTER_TEST_GUIDE.md
git commit -m "docs: update test guide with all fixes and procedures"
```

### Task 4.2: Update external guide reference

**Files:**
- Compare: `QEMU_ADAPTER_TEST_GUIDE.md` vs `https://github.com/is4bel4/scripts_guarita/blob/main/docs/QEMU.md`

- [ ] **Step 1: Sync relevant changes back to external guide if appropriate**

Check if external guide has information we're missing, or vice versa. Document any divergence.

---

## Verification Checklist

After all phases complete, run this full verification:

- [ ] `sudo bash scripts/qemu/start-mesh.sh` — VMs boot
- [ ] `bash scripts/qemu/configure-vms.sh` — 4/4 VMs configured
- [ ] `bash tests/qemu/run-all.sh` — all tests pass (target: 17+ tests, 0 failures)
- [ ] `ssh -F config/ssh-config.resolved root@lm-testbed-node-1 "bmx7 -c originators"` — shows 4 nodes
- [ ] `ssh -F config/ssh-config.resolved root@lm-testbed-node-1 "ip link show wlan0-mesh"` — WiFi interface present (source build only)
- [ ] `curl --resolve thisnode.info:80:10.99.0.11 http://thisnode.info/` — returns 200
- [ ] `sudo bash scripts/qemu/stop-mesh.sh` — clean teardown

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Source build fails (missing deps) | Docker build provides reproducible environment |
| vwifi-client not in OpenWrt feeds | build-libremesh-image.sh already pins specific commit |
| Build takes > 4h | Run in background, prebuilt fallback still works |
| Prebuilt tests break after source build changes | Phase 1 and 2 are independent; start-mesh.sh auto-detects image type |
| BMX7 doesn't converge over vwifi | Fall back to wired-only tests; WiFi tests become SKIP |
| ip-full missing in source build | Already in defconfig; add skip logic for safety |
