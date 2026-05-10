# LibreMesh Lab

## Quick Start

Install the CLI into the default user-local location:

```bash
curl -fsSL https://raw.githubusercontent.com/coolabnet/libremesh-lab/main/scripts/install.sh | bash
```

The installer clones the repository to `~/.local/share/libremesh-lab` and
symlinks `libremesh-lab` into `~/.local/bin`. For a local checkout, run the same
commands through `bin/libremesh-lab`.

```bash
# 1. Build or download firmware image
bin/libremesh-lab build-image
# OR use pre-built image conversion:
bash scripts/qemu/convert-prebuilt.sh

# 2. Start the test bed (requires root for bridge/TAP/dnsmasq/QEMU networking)
sudo bin/libremesh-lab start

# 3. Configure VMs (wait ~90s for boot)
bin/libremesh-lab configure

# 4. Run the safe VM-free suite
bin/libremesh-lab test --suite fast

# 5. Run VM-backed checks while the lab is still running
bin/libremesh-lab test --suite lab
MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter

# 6. Stop the test bed
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

## Suite Selection

The default test command is intentionally safe:

```bash
bin/libremesh-lab test
bin/libremesh-lab test --suite fast
```

Available suites:

| Suite | Requirements | Notes |
|-------|--------------|-------|
| `fast` | No VMs, no Mesha checkout, no root | CLI contract, `run-adapter` workspace isolation, and namespace preflight |
| `lab` | Already running and configured QEMU/vwifi lab | Mesh protocol and rollback checks |
| `adapter` | Running lab plus `MESHA_ROOT=/path/to/mesha` | Mesha adapters, rollout, drift, validation, readonly, and failure-path checks |
| `lifecycle` | Isolated host, root-capable start/stop, `RUN_LIFECYCLE_TESTS=1` | Destructive lifecycle cleanup coverage |
| `namespace` | Future namespace/wmediumd prerequisites | Placeholder; skipped unless `RUN_NAMESPACE_TESTS=1`, then exits nonzero until implemented |

`lab` and `adapter` do not create the VMs themselves. Build or prepare the
firmware, start the lab with root privileges, wait for boot, run
`bin/libremesh-lab configure`, and then run those suites. Use `CONVERGE_WAIT` and
`QEMU_TIMEOUT_MULTIPLIER` on slower hosts.

The namespace suite is still a placeholder for future namespace/wmediumd tests,
but it runs the safe preflight first. The preflight checks for `ip`, `iw`,
`wmediumd`, `modprobe`, `unshare` or `ip netns`, and `mac80211_hwsim`
availability without creating namespaces, loading kernel modules, or requiring
root:

```bash
bash scripts/qemu/preflight-namespace.sh
bin/libremesh-lab test --suite namespace
RUN_NAMESPACE_TESTS=1 bin/libremesh-lab test --suite namespace
```

## Test Files

| Test file | Tests |
|-----------|-------|
| `test-adapters.sh` | collect-nodes JSON, collect-topology, thisnode discovery, ip -j |
| `test-mesh-protocols.sh` | BMX7 neighbors, originators, mesh routing, Babel fallback |
| `test-validate-node.sh` | Healthy node, missing SSID detection, no neighbors |
| `test-config-drift.sh` | UCI write/read, drift detection |
| `test-topology-manipulation.sh` | vwifi-ctrl distance-based loss, node removal |
| `test-firmware-upgrade.sh` | Firmware version change, validate-node mismatch |
| `test-multi-hop.sh` | End-to-end multi-hop connectivity |
| `test-rollback.sh` | Configuration backup and rollback |
| `test-rollout.sh` | Rolling configuration update dry runs |
| `test-failure-paths.sh` | Unreachable hosts and adapter error handling |
| `test-run-adapter-wrapper.sh` | No-VM adapter workspace isolation regression |
| `test-namespace-preflight.sh` | No-root namespace/wmediumd preflight regression |

## Adapter Isolation

`bin/libremesh-lab run-adapter <script> [args...]` runs Mesha or other adapter
scripts from a temporary workspace instead of the caller repository. The wrapper:

- Maps lab `config/inventories`, `config/desired-state`, `config/topology.yaml`, and SSH config into the temporary workspace.
- Copies adapter repository entries into the temporary workspace while excluding selected generated or heavy top-level entries such as `.git`, `.venv`, `node_modules`, `exports`, `images`, `logs`, and `run`, then removes VCS metadata from the copy.
- Exposes `REPO_ROOT`, `WORKSPACE_ROOT`, `SOURCE_WORKSPACE_ROOT`, `LIBREMESH_LAB_ROOT`, `LIBREMESH_LAB_CONFIG`, `LIBREMESH_LAB_INVENTORIES`, `LIBREMESH_LAB_DESIRED_STATE`, `SSH_CONFIG_PATH`, `SSH_KEY`, and `GIT_SSH_COMMAND`.
- Sets an isolated `HOME` and an SSH wrapper that automatically uses the lab SSH config.

This lets adapter scripts that expect repository-relative paths run against lab
fixtures without writing generated files back into the source checkout.

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB | 8 GB |
| CPU | 2 cores (TCG) | 4+ cores (KVM) |
| Disk | 2 GB | 5 GB |
| Permissions | sudo/CAP_NET_ADMIN for VM networking | root on isolated QA hosts |

Host root privileges are required for commands that create or remove bridge, TAP,
dnsmasq, vwifi, QEMU, loopback mount, or namespace state. In practice, run
`start`, `stop`, direct `start-vwifi.sh`, direct `start-mesh.sh`, direct
`stop-mesh.sh`, and pre-built image conversion with `sudo` when prompted by the
host. `status`, `logs`, `configure`, `test --suite fast`, and `run-adapter`
should run unprivileged after the lab exists.

Namespace VM work is not active yet. Before adding real namespace tests, start
with the non-mutating preflight:

```bash
bash scripts/qemu/preflight-namespace.sh
```

Only move on to root-backed namespace creation or module loading on an isolated
host after bridge, namespace, and wireless simulation cleanup is verified.

## Known Limitations

- TCG mode (no KVM) is 3x slower — increase timeouts
- Pre-built images lack WiFi simulation (mac80211_hwsim, vwifi)
- BMX7 convergence takes 30-60s in virtualized environment
- vwifi-ctrl only supports global packet loss (not per-link)

## Troubleshooting

See [troubleshooting.md](troubleshooting.md).
