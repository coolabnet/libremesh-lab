# QEMU Adapter Test Plan

## Objective
Run all adapter tests against QEMU LibreMesh testbed using prebuilt image for faster setup.

## Steps

### 1. Acquire Bootable Image
- Run `./scripts/qemu/convert-prebuilt.sh` to download and create LibreRouterOS-based image
- Image will be at `/home/luandro/Dev/coolab/mesha/images/librerouteros-prebuilt.img`
- Note: This image lacks vwifi-client and mac80211_hwsim but provides basic IP connectivity over wired interfaces

### 2. Start Testbed VMs
- Modify `scripts/qemu/start-mesh.sh` to use the prebuilt image:
  - Change `BASE_IMAGE` variable to point to `librerouteros-prebuilt.img`
  - Keep other settings (will still create qcow2 overlays)
- Run `./scripts/qemu/start-mesh.sh` in background
- Wait for VMs to boot (check for SSH connectivity)

### 3. Configure VMs
- Run `./scripts/qemu/configure-vms.sh` to:
  - Wait for SSH connectivity
  - Set hostnames, network config
  - Attempt to load kernel modules (may fail but continue)
  - Configure UCI settings
  - Inject SSH keys
  - Generate resolved SSH config

### 4. Run Adapter Tests
- Execute `./tests/qemu/test-adapters.sh` to run TAP tests on:
  - collect-nodes.sh (against all 4 nodes)
  - collect-topology.sh (against gateway)
  - discover-from-thisnode.sh (HTTP to thisnode.info)
  - ip -j addr show (JSON validation)
- Execute `./tests/qemu/run-all.sh` to run full test suite including:
  - Adapter Contract
  - Mesh Protocols
  - Validate Node
  - Config Drift
  - Topology Manipulation

### 5. Cleanup
- Stop testbed with `./scripts/qemu/stop-mesh.sh` (or Ctrl+C in start-mesh terminal)
- Remove temporary files if desired

## Verification
- All adapter tests should pass (exit code 0)
- TAP output shows expected number of passes
- SSH connectivity to all VMs works
- Basic mesh functionality (BMX7 over wired interfaces) operational

## Notes
- Prebuilt image limitation: No WiFi simulation, but adapter tests primarily test JSON-over-SSH and HTTP functionality which should work over wired BMX7
- If any adapter fails due to missing packages, we may need to adjust tests or note limitations
- Total time: ~10-15 minutes for image download/create + ~1 minute for VM boot + ~1 minute for configuration + ~1 minute for testing