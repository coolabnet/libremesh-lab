# QEMU Source-Built Mesh Integration Plan

**Date:** 2026-05-08
**Status:** In Progress (code complete, verification pending)
**Depends on:** `plans/2026-05-04-qemu-test-coverage-expansion-v3.md` (Tier 1 source-built image)

---

## Objective

Enable full LibreMesh mesh testing in QEMU by integrating the source-built rootfs (OpenWrt v24.10.6 + lime-packages + vwifi + bmx7) with the testbed infrastructure. This activates the 15 currently-skipped BMX7/vwifi/wireless tests, bringing the total from 58 passing to ~73 passing.

## Background

### What We Have

| Component | Status | Location |
|-----------|--------|----------|
| Source-built image | Built (121MB) | `images/libremesh-x86-64-source-built-flat.img` |
| Source-built kernel | Built (5.9MB) | `images/generic-kernel-source-built.bin` |
| Prebuilt image (fallback) | Working | `images/librerouteros-prebuilt.img` |
| Unit tests | 27/27 pass | `tests/run-unit.sh` |
| QEMU test suites (prebuilt) | 15/15 pass, 15 skip | `tests/qemu/run-all.sh` |
| Build script | Working | `scripts/qemu/build-libremesh-image.sh` |
| configure-vms.sh | Works with prebuilt only | `scripts/qemu/configure-vms.sh` |
| configure-source-vms.sh | Written, serial login broken | `scripts/qemu/configure-source-vms.sh` |

### The Problem

The source-built rootfs (OpenWrt v24.10.6) has dropbear that **rejects blank password SSH auth**, even with the `-B` flag. This blocks `configure-vms.sh` from connecting to VMs for initial setup (SSH key injection, IP configuration, hostname, bmx7 startup).

The serial console approach (`configure-source-vms.sh`) was attempted but the Python socket connection times out — the serial login sequence is unreliable.

### Why This Matters

The 15 skipped tests require packages only in the source-built rootfs:

| Package | Enables | Skipped Tests |
|---------|---------|---------------|
| `bmx7` | Mesh routing protocol | Mesh Protocols (3), Multi-Hop Mesh (2), Topology convergence (3) |
| `vwifi` | Virtual WiFi client | Topology Manipulation (2) |
| `wireless config` | radio0 interface | Config Drift (2) |
| `lime-packages` | LibreMesh integration | Adapter Contract (4), Testbed Lifecycle (1) |

These are the core mesh tests that mesha adapters need to validate against.

---

## Approach: Pre-bake Configuration into Image

Instead of relying on runtime SSH password auth or serial console, embed SSH keys and a base network config directly into the flat image before boot. This eliminates the auth problem entirely.

### Why This Approach

- **Eliminates dropbear auth issue**: SSH key auth works regardless of password policy
- **No serial console needed**: All configuration happens via SSH
- **Compatible with existing `configure-vms.sh`**: Minimal changes to working code
- **Fast**: Pre-bake takes seconds, not minutes of serial debugging
- **Reliable**: File-based configuration, no timing-sensitive socket interactions

---

## Implementation Plan

### Phase 1: Pre-bake SSH Keys and Network Config

- [x] **Task 1.1**: Create `scripts/qemu/prepare-source-image.sh`
  - Generates SSH key pair at `run/ssh-keys/` (if not exists)
  - Mounts the flat image (`libremesh-x86-64-source-built-flat.img`)
  - Writes SSH public key to `/root/.ssh/authorized_keys`
  - Writes SSH public key to `/etc/dropbear/authorized_keys`
  - Writes network config with static IP `10.99.0.11/16` (base IP, configure-vms.sh changes per node)
  - Sets root password to empty (shadow: `root::0:0:99999:7:::`)
  - Ensures dropbear `PasswordAuth 'on'` and `RootLogin '1'`
  - Creates `/sbin/service` shim (needed by adapters)
  - Unmounts

- [ ] **Task 1.2**: Run `prepare-source-image.sh` and verify the image boots with SSH key auth
  - Requires sudo (image mount). Run manually:
    ```
    sudo bash scripts/qemu/prepare-source-image.sh
    ```

### Phase 2: Update configure-vms.sh for Key Auth

- [x] **Task 2.1**: Modify `scripts/qemu/configure-vms.sh` to try key auth first
  - Change `ssh_vm()` to attempt key-based auth before password auth
  - Add `-i ${KEY_FILE}` to SSH command when key file exists
  - Keep `BatchMode=no` as fallback for prebuilt image (backward compatible)
  - The key injection step (`mkdir -p /root/.ssh && echo '...' >> authorized_keys`) becomes idempotent (key already present)

- [ ] **Task 2.2**: Verify `configure-vms.sh` works with source-built image
  - Requires running QEMU VMs. After Task 1.2:
    ```
    sudo bash scripts/qemu/start-mesh.sh
    bash scripts/qemu/configure-vms.sh
    ```

### Phase 3: Wireless and Mesh Configuration

- [x] **Task 3.1**: Add wireless/mesh setup to `configure-vms.sh` (source-built image section)
  - Added Phase 3 mesh convergence to configure-vms.sh
  - Detects bmx7 availability and waits for peer convergence (90s timeout)
  - Existing vwifi/lime-config/bmx7 setup already in configure_vm()

- [ ] **Task 3.2**: Verify mesh convergence between nodes
  - Requires running VMs. After Tasks 1.2 + 2.2:
    ```
    ssh -i run/ssh-keys/id_rsa root@10.99.0.11 "bmx7 -c peers"
    ssh -i run/ssh-keys/id_rsa root@10.99.0.11 "ping -c 3 10.99.0.12"
    ```

### Phase 4: Run Full Test Suite

- [ ] **Task 4.1**: Run `tests/qemu/run-all.sh` with source-built image
  - Requires running VMs with mesh converged. Run after Tasks 1-3:
    ```
    bash tests/qemu/run-all.sh
    ```

- [ ] **Task 4.2**: Run `tests/qemu/test-topologies.sh` (topology convergence)
  - Requires running VMs:
    ```
    bash tests/qemu/test-topologies.sh
    ```

- [ ] **Task 4.3**: Run mesha adapter tests against the mesh
  - Requires running VMs:
    ```
    bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-nodes.sh lm-testbed-node-1
    bash scripts/qemu/run-testbed-adapter.sh adapters/mesh/collect-topology.sh lm-testbed-node-1
    ```

### Phase 5: Commit and Document

- [x] **Task 5.1**: Commit all changes
  - Committed as `dab9785` on `feat/qemu-testbed`
  - `prepare-source-image.sh` — new file
  - `configure-vms.sh` — key auth + mesh convergence

- [ ] **Task 5.2**: Update plan verification checklist
  - Run after full test suite verification (Tasks 4.1-4.3)

- [ ] **Task 5.3**: Update `QEMU_ADAPTER_TEST_GUIDE.md` with source-built image instructions
  - Add prepare-source-image.sh usage
  - Document key auth workflow

---

## Verification Criteria

- [ ] `ssh -i run/ssh-keys/id_rsa root@10.99.0.11` works without password prompt
- [ ] `lsmod | grep hwsim` shows mac80211_hwsim loaded on all 4 VMs
- [ ] `bmx7 -c peers` shows at least 2 peers on each node
- [ ] `tests/qemu/run-all.sh` shows 15/15 suites, 0 skip, 0 fail
- [ ] `tests/qemu/test-topologies.sh` passes all 3 topology tests
- [ ] Mesha adapters return valid JSON from all mesh nodes

## Potential Risks and Mitigations

1. **vwifi module not available in kernel**
   - Mitigation: Already verified — `mac80211_hwsim` is in the source-built kernel (6.6.127)

2. **bmx7 doesn't converge over virtual WiFi**
   - Mitigation: BMX7 works over any interface. If vwifi provides wlan0, bmx7 should work. May need specific bmx7 config for ad-hoc mode.

3. **Pre-baked SSH key breaks after qcow2 overlay recreation**
   - Mitigation: SSH key is in the base flat image. qcow2 overlays inherit from base. Key persists across overlay recreation.

4. **Static IP 10.99.0.11 conflicts when multiple VMs use same base image**
   - Mitigation: `configure-vms.sh` changes the IP per node via SSH after initial connection. The base IP is only used for the first connection to each VM.

5. **Source-built image missing packages needed by adapters**
   - Mitigation: Already verified — `opkg list-installed` shows bmx7, vwifi, lime-packages all present.

## Alternative Approaches

1. **Fix dropbear blank password auth**: Debug why `-B` flag doesn't work on OpenWrt v24.10.x. Risk: could be a musl libc crypt() incompatibility that's hard to fix without rebuilding dropbear.

2. **Serial console configuration**: Use `configure-source-vms.sh` with serial sockets. Risk: Python socket connections are timing out; serial console login is unreliable.

3. **Per-node qcow2 images with pre-baked IPs**: Create 4 separate flat images, each with a different static IP. Risk: More complex, requires 4x disk space, harder to maintain.

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `scripts/qemu/prepare-source-image.sh` | Create | Pre-bake SSH keys + network config into flat image |
| `scripts/qemu/configure-vms.sh` | Modify | Add key auth support (try key first, password fallback) |
| `QEMU_ADAPTER_TEST_GUIDE.md` | Modify | Add source-built image boot instructions |
| `plans/2026-05-04-qemu-test-coverage-expansion-v3.md` | Modify | Mark Tier 1 items complete |

## Dependencies

- Source-built flat image must exist (`libremesh-x86-64-source-built-flat.img`)
- Source-built kernel must exist (`generic-kernel-source-built.bin`)
- SSH key pair must be generated (handled by `prepare-source-image.sh`)
- QEMU and bridge networking must be functional
