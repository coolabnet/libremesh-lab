# LibreMesh QEMU Test Bed — Images

This directory holds firmware images for the LibreMesh Lab. Images are
gitignored by default — they are built or downloaded locally.

## Quick Start

### Option A: Build Custom LibreMesh Image (recommended)

The full build produces a LibreMesh image with WiFi simulation support:

```bash
# From the repo root
./scripts/qemu/build-libremesh-image.sh
```

**Requirements:** A Linux host with `git`, `make`, and standard build tools, or
use the Docker builder:

```bash
docker build -t libremesh-lab-qemu-builder -f docker/qemu-builder/Dockerfile .
docker run --rm -v $(pwd)/images:/output libremesh-lab-qemu-builder
```

### Option B: Convert Pre-built LibreRouterOS (fast path)

Downloads an official LibreRouterOS image and converts it for QEMU:

```bash
./scripts/qemu/convert-prebuilt.sh
```

Add `--skip-download` to reuse previously downloaded files.

## Pre-built Image Limitations

Pre-built LibreRouterOS images have significant limitations for mesh testing:

| Feature | Custom Build | Pre-built |
|---|---|---|
| mac80211_hwsim (simulated WiFi) | Yes | No |
| vwifi-client (virtual WiFi) | Yes | No |
| BMX7 over WiFi | Yes | Wired only |
| Custom packages | Yes | No |
| Build time | ~2-4 hours | ~2 minutes |

For full mesh simulation with virtual WiFi interfaces, use the custom build.

## Package List

Each package in the custom build and its purpose:

| Package | Purpose |
|---|---|
| `kmod-mac80211-hwsim` | Simulated WiFi hardware for QEMU |
| `vwifi-client` | Virtual WiFi client (mac80211_hwsim userspace) |
| `bmx7` | BMX7 mesh routing protocol |
| `babeld` | Babel routing protocol (alternative) |
| `ip-full` | Full iproute2 for advanced networking |
| `iwinfo` | Wireless information library |
| `uc` | Micro controller (uclient) HTTP client |
| `ubus` | OpenWrt inter-process communication bus |
| `uhttpd` | Lightweight HTTP server (LuCI backend) |
| `python3-light` | Python 3 runtime (for test scripts) |
| `netcat` | Network utility for debugging |
| `iw` | Wireless configuration tool |
| `lime-system` | LibreMesh core system |
| `lime-proto-bmx7` | LibreMesh BMX7 protocol support |
| `ccache` | Build cache for faster rebuilds |

## Image Versioning

Custom builds produce images named:

```text
libremesh-x86-64-<short-hash>-<date>.img.gz
```

Where:

- `<short-hash>` — First 12 chars of the build-inputs hash (defconfig + feeds + build scripts)
- `<date>` — Build date in `YYYYMMDD` format

The `build-manifest.yaml` file accompanies each image with full build metadata.

## Caching

The build script computes a hash over all inputs (defconfig, Dockerfile, build
script, feed commits). If the hash hasn't changed, the build is skipped. Use
`--force` to override:

```bash
./scripts/qemu/build-libremesh-image.sh --force
```

## Files in This Directory

| File | Description |
|---|---|
| `*.img.gz` | Compressed disk images (gitignored) |
| `*.img` | Raw disk images (gitignored) |
| `build-manifest.yaml` | Build metadata (gitignored) |
| `build-inputs.hash` | Input hash for caching (gitignored) |
| `README.md` | This file |
