# LibreMesh Lab

LibreMesh Lab is a standalone simulation and firmware testbed for LibreMesh/OpenWrt operations. It owns QEMU lifecycle scripts, testbed topology/configuration, firmware image build helpers, vwifi integration, simulator tests, and research notes for the next host `mac80211_hwsim` + wmediumd + namespace track.

The lab is intentionally independent from Mesha. Mesha adapter tests call this repository through `bin/libremesh-lab run-adapter`, and the lab provides inventories, desired state, SSH configuration, keys, and hostname aliases without modifying the caller repository.

## Layout

```text
libremesh-lab/
├── bin/libremesh-lab
├── scripts/qemu/
├── tests/qemu/
├── config/
├── docs/
├── images/
├── research/
├── plans/archive/
└── docker/qemu-builder/
```

Generated runtime data lives under `run/`. Downloaded or built images live under `images/`. Compiled vwifi binaries and external source checkouts live under `bin/` and `src/vwifi/`. These artifacts are ignored by git.

## CLI

```bash
bin/libremesh-lab build-image
bin/libremesh-lab start
bin/libremesh-lab configure
bin/libremesh-lab status
bin/libremesh-lab logs
bin/libremesh-lab test
bin/libremesh-lab run-adapter /path/to/mesha/adapters/mesh/collect-nodes.sh lm-testbed-node-1
bin/libremesh-lab stop
```

`start` and `stop` may need root privileges for bridges, TAP devices, dnsmasq, and QEMU networking. The default bridge name remains `mesha-br0` for compatibility and is configurable in `config/topology.yaml`.

## Mesha Integration

From a Mesha checkout next to this repository:

```bash
../libremesh-lab/bin/libremesh-lab run-adapter \
  "$PWD/adapters/mesh/collect-nodes.sh" lm-testbed-node-1
```

If Mesha lives elsewhere, set `MESHA_ROOT` for lab tests and `LIBREMESH_LAB_ROOT` for Mesha wrappers.
