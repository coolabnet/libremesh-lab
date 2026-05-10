# LibreMesh Lab

## Quick Start

```bash
# 1. Build or download firmware image
bash scripts/qemu/build-libremesh-image.sh
# OR use pre-built:
bash scripts/qemu/convert-prebuilt.sh

# 2. Start the test bed (requires sudo for TAP/bridge)
sudo bash scripts/qemu/start-vwifi.sh
sudo bash scripts/qemu/start-mesh.sh

# 3. Configure VMs (wait ~90s for boot)
bash scripts/qemu/configure-vms.sh

# 4. Run tests
bash tests/qemu/run-all.sh

# 5. Stop the test bed
sudo bash scripts/qemu/stop-mesh.sh
```

## Architecture

4 LibreMesh VMs connected via TAP/bridge networking:

- **lm-testbed-node-1** (10.99.0.11) — gateway
- **lm-testbed-node-2** (10.99.0.12) — relay
- **lm-testbed-node-3** (10.99.0.13) — leaf
- **lm-testbed-tester** (10.99.0.14) — tester (512MB RAM)

Each VM has:

- mesh0 (TAP via mesha-br0) — management SSH + wired mesh
- wan0 (QEMU user-mode) — internet access
- wlan0 (vwifi-client → vwifi-server) — WiFi mesh simulation

The host (10.99.0.254) runs vwifi-server for inter-VM WiFi frame relay.

## Scripts

| Script | Purpose |
|--------|---------|
| `build-libremesh-image.sh` | Build custom LibreMesh firmware with vwifi support |
| `convert-prebuilt.sh` | Download and convert LibreRouterOS pre-built image |
| `start-vwifi.sh` | Compile and launch vwifi-server |
| `start-mesh.sh` | Launch 4 QEMU VMs with TAP/bridge networking |
| `configure-vms.sh` | Post-boot: hostname, IP, BMX7, lime-config, SSH keys |
| `stop-mesh.sh` | Teardown: kill VMs, cleanup TAP/bridge |
| `mesh-status.sh` | Status check: VM state, SSH, vwifi, bridge |
| `run-testbed-adapter.sh` | Run adapter scripts with testbed path mapping |
| `validate-adapters.sh` | Validate all adapter scripts against test bed |
| `collect-logs.sh` | Collect logs for CI artifact upload |

## Tests

| Test file | Tests |
|-----------|-------|
| `test-adapters.sh` | collect-nodes JSON, collect-topology, thisnode discovery, ip -j |
| `test-mesh-protocols.sh` | BMX7 neighbors, originators, mesh routing, Babel fallback |
| `test-validate-node.sh` | Healthy node, missing SSID detection, no neighbors |
| `test-config-drift.sh` | UCI write/read, drift detection |
| `test-topology-manipulation.sh` | vwifi-ctrl distance-based loss, node removal |
| `test-firmware-upgrade.sh` | Firmware version change, validate-node mismatch |

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB | 8 GB |
| CPU | 2 cores (TCG) | 4+ cores (KVM) |
| Disk | 2 GB | 5 GB |
| Permissions | sudo/CAP_NET_ADMIN | root |

## Known Limitations

- TCG mode (no KVM) is 3x slower — increase timeouts
- Pre-built images lack WiFi simulation (mac80211_hwsim, vwifi)
- BMX7 convergence takes 30-60s in virtualized environment
- vwifi-ctrl only supports global packet loss (not per-link)

## Troubleshooting

See [troubleshooting.md](troubleshooting.md).
