# Self-Hosted Runner for QEMU Tests

## Why

GitHub Actions hosted runners lack KVM support, forcing QEMU to use TCG (software emulation).
This makes VM boot 3x slower and some timing-sensitive tests may be flaky.

A self-hosted runner with KVM support enables:

- Faster boot times (90s → 30s)
- Larger topologies (>4 VMs)
- More reliable BMX7 convergence timing

## Setup

### 1. Install GitHub Actions Runner

Follow [GitHub's self-hosted runner docs](https://docs.github.com/en/actions/hosting-your-own-runners):

```bash
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64-2.311.0.tar.gz -L \
    https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-linux-x64-2.311.0.tar.gz
tar xzf actions-runner-linux-x64-2.311.0.tar.gz
./config.sh --url https://github.com/YOUR_ORG/mesha --token YOUR_TOKEN
```

### 2. Enable KVM

```bash
# Verify KVM available
ls -la /dev/kvm
# If not: sudo apt install qemu-kvm && sudo usermod -aG kvm $(whoami)
```

### 3. Install Dependencies

```bash
sudo apt-get install -y \
    qemu-system-x86 qemu-utils cmake g++ pkg-config \
    libnl-3-dev libnl-genl-3-dev iproute2 python3-yaml jq
```

### 4. Start Runner

```bash
./run.sh
# Or install as service: sudo ./svc.sh install && sudo ./svc.sh start
```

### 5. Label the Runner

Add label `qemu` to the runner in GitHub Settings → Actions → Runners.
Update workflow to target: `runs-on: [self-hosted, qemu]`

## Security Notes

- Runner needs `sudo` for TAP/bridge creation
- Runner needs `CAP_NET_ADMIN` capability
- SSH keys are generated per-run and stored in `run/ssh-keys/` (gitignored)
- No production credentials are used in the test bed
