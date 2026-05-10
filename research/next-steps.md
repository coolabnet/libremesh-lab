# LibreMesh Lab Next Steps

## Primary Path

Build the next simulation layer around host `mac80211_hwsim`, wmediumd, and Linux network namespaces. This should make WiFi data-frame behavior observable and controllable without depending on the current QEMU guest vwifi limitations.

## Preserved Path

Keep the current QEMU/vwifi environment as the firmware and operations testbed. It is useful for image boot checks, SSH/key injection, adapter contract tests, rollout dry-runs, topology fixtures, and lifecycle cleanup.

## Parked Path

Park direct vwifi data-frame debugging and hwsim virtio transport investigation until the namespace/wmediumd path proves insufficient. Preserve the current findings in `research/wifi-mesh-simulation-research.md` for continuity.
