# LibreMesh Lab Documentation

LibreMesh Lab is a Bash/QEMU testbed for running LibreMesh/OpenWrt mesh networks on a local Linux machine. The root [README](../README.md) gives the short introduction and quick start. This directory holds the detailed guides.

## Start Here

| Guide | Use it for |
|---|---|
| [Architecture](architecture.md) | How the VMs, host bridge, vwifi, wmediumd, topologies, and directories fit together. |
| [Testing](testing.md) | Test suites, test files, environment variables, and safe/destructive test rules. |
| [Mesha integration](mesha-integration.md) | Running Mesha or other adapter scripts against the lab without changing the caller repo. |
| [Contributing](contributing.md) | Development conventions, commit style, PR expectations, and safety rules. |
| [Troubleshooting](troubleshooting.md) | Common QEMU, SSH, vwifi, bridge, and mesh convergence failures. |
| [Self-hosted runner](self-hosted-runner.md) | Setting up a KVM-capable runner for VM-backed tests. |
| [QEMU adapter test guide](qemu-adapter-test-guide.md) | Full adapter testing walkthrough for Mesha-style adapter scripts. |

## Quick Start

```bash
# 1. Build or download firmware image
bin/libremesh-lab build-image
# OR use pre-built image conversion:
bash scripts/qemu/convert-prebuilt.sh

# 2. For source-built images only: install SSH keys and DHCP into the image
scripts/qemu/configure-source-image.sh --image images/libremesh-combined.img

# 3. Start the test bed; requires root for bridge/TAP/dnsmasq/QEMU networking
sudo bin/libremesh-lab start

# 4. Configure VMs after roughly 90 seconds of boot time
bin/libremesh-lab configure

# 5. Run tests
bin/libremesh-lab test
bin/libremesh-lab test --suite lab
MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter

# 6. Tear down
sudo bin/rollback-lab.sh
sudo bin/rollback-lab.sh --full
```

## Main Commands

| Command | Purpose |
|---|---|
| `bin/libremesh-lab build-image` | Build or prepare a LibreMesh firmware image. |
| `sudo bin/libremesh-lab start` | Start vwifi, host networking, and four QEMU VMs. |
| `bin/libremesh-lab configure` | Configure hostnames, IPs, mesh protocol, and SSH keys after boot. |
| `sudo bin/libremesh-lab stop` | Stop VMs and clean lab networking/runtime state. |
| `bin/libremesh-lab status` | Print lab status as JSON. |
| `bin/libremesh-lab logs` | Collect logs for debugging or CI artifacts. |
| `bin/libremesh-lab test` | Run the default safe `fast` suite. |
| `bin/libremesh-lab run-adapter <script>` | Run an external adapter script against lab config. |
| `sudo bin/rollback-lab.sh` | Comprehensive cleanup for VMs, TAPs, bridge, runtime state, and locks. |

## Full Workflow

```bash
# Build or get an image
bin/libremesh-lab build-image
# or
bash scripts/qemu/convert-prebuilt.sh

# Prepare source-built images when needed
scripts/qemu/configure-source-image.sh --image images/libremesh-combined.img

# Start and configure the lab
sudo bin/libremesh-lab start
bin/libremesh-lab configure

# Run checks
bin/libremesh-lab test
bin/libremesh-lab test --suite lab
MESHA_ROOT=/path/to/mesha bin/libremesh-lab test --suite adapter

# Clean up
sudo bin/rollback-lab.sh
```

## Requirements

| Resource | Minimum | Recommended |
|---|---:|---:|
| RAM | 4 GB | 8 GB |
| CPU | 2 cores using TCG | 4+ cores with KVM |
| Disk | 2 GB | 5 GB |
| OS | Linux | Linux with KVM |
| Permissions | sudo / CAP_NET_ADMIN for VM networking | root on isolated QA hosts |

Root privileges are required for bridge, TAP, dnsmasq, vwifi, QEMU, loopback mount, and namespace operations. `status`, `logs`, `configure`, `test --suite fast`, and `run-adapter` normally run unprivileged after the lab exists.

## Known Limitations

- QEMU TCG mode is about 3x slower than KVM. Use `QEMU_TIMEOUT_MULTIPLIER` on slower hosts.
- Pre-built images are quick to prepare but do not include full Wi-Fi simulation support.
- Mesh protocol convergence can take 30-60 seconds in virtualized environments.
- Babel in a wired `br-lan` topology may not install extra kernel routes because layer 2 already provides reachability.
- `vwifi-ctrl` currently supports global packet loss, not per-link packet loss.

## Agent and QA Notes

- Agent-facing repository conventions live in [AGENTS.md](../AGENTS.md).
- End-to-end QA guidance lives in [QA.md](../QA.md).
- Generated runtime data belongs in `run/`, built firmware images in `images/`, and external checkouts in `src/`; keep these artifacts out of commits.
