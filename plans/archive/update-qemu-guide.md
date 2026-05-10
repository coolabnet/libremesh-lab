# Plan: Update QEMU_ADAPTER_TEST_GUIDE.md with scripts_guarita patterns

## Source
External guide: https://github.com/is4bel4/scripts_guarita/blob/main/docs/QEMU.md
Our guide: QEMU_ADAPTER_TEST_GUIDE.md

## Analysis: What to merge from scripts_guarita

### Useful additions (not in our guide):
1. **Multi-OS QEMU install commands** — Arch, Debian/Ubuntu, Alpine, macOS
2. **Permission checks** — verify sudo/root before operations
3. **QEMU exit key combo** — Ctrl+A then X (users don't know this)
4. **Default route config inside VMs** — `ip route add default via 10.0.2.2 dev eth1` for internet
5. **Connectivity test** — `ping 8.8.8.8` from inside VM
6. **OpenWRT image download** — direct link to OpenWRT 23.05.1 (alternative to LibreRouterOS prebuilt)

### Already covered (skip):
- Prerequisites (we have them)
- Script execution basics
- Networking overview (we have detailed architecture diagram)

## Changes to QEMU_ADAPTER_TEST_GUIDE.md

### 1. Expand Prerequisites section
Add multi-OS QEMU install commands:
```bash
# Arch Linux
sudo pacman -S qemu-system-x86

# Debian/Ubuntu
sudo apt-get install -y qemu-system-x86 qemu-utils

# Alpine Linux
sudo apk add qemu-system-x86_64 qemu-img

# macOS
brew install qemu
```

### 2. Add "Quick QEMU Install" subsection under Prerequisites
After existing prerequisites list, add install commands.

### 3. Add "Inside the VM" subsection after Configure VMs step
- Default route config: `ip route add default via 10.0.2.2 dev eth1`
- Connectivity test: `ping 8.8.8.8`
- Exit QEMU: Ctrl+A then X

### 4. Add alternative OpenWRT image path
In Quick Test Procedure, add note about using vanilla OpenWRT 23.05.1 image as alternative to LibreRouterOS prebuilt:
- URL: https://archive.openwrt.org/releases/23.05.1/targets/x86/64/
- File: `openwrt-23.05.1-x86-64-generic-ext4-combined.img.gz`
- Limitation: No LibreMesh packages, basic OpenWRT only

### 5. Add "Permission Requirements" subsection
Clarify which steps need sudo and why:
- `convert-prebuilt.sh` — needs sudo for image creation (loop device, mount)
- `start-mesh.sh` — needs sudo for TAP/bridge creation
- `configure-vms.sh` — does NOT need sudo (SSH-based)
- `stop-mesh.sh` — needs sudo for TAP/bridge cleanup

### 6. No changes needed to:
- Networking Architecture diagram (already comprehensive)
- Adapter tests section (already accurate)
- Troubleshooting section (already has detailed troubleshooting)
