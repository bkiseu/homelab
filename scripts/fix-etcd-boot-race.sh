#!/usr/bin/env bash
# Widens the restart burst allowance on snap.k8s.etcd/k8sd so a reboot's
# network-not-ready-yet race gets ~2 minutes of retries instead of giving up
# in under a second. See docs/canonical-kubernetes-bootstrap.md,
# "Power-cycle gotcha" - network-online.target ordering was evaluated and
# rejected (netplan marks every interface `optional: true` on this fleet, so
# the target is satisfied trivially and wouldn't actually gate anything).
set -euo pipefail

HOSTS=(
  "sentinel@192.168.100.18"
  "bryant@192.168.100.12"
  "bryant@192.168.100.14"
)

for host in "${HOSTS[@]}"; do
  echo "=== $host ==="
  ssh "$host" bash -s <<'REMOTE'
set -euo pipefail
sudo mkdir -p /etc/systemd/system/snap.k8s.etcd.service.d /etc/systemd/system/snap.k8s.k8sd.service.d

for unit in snap.k8s.etcd.service snap.k8s.k8sd.service; do
  sudo tee "/etc/systemd/system/${unit}.d/override.conf" >/dev/null <<'OVERRIDE'
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=20

[Service]
Restart=on-failure
RestartSec=5
OVERRIDE
done

sudo systemctl daemon-reload
echo "--- effective settings ---"
systemctl show snap.k8s.etcd.service snap.k8s.k8sd.service -p Id,StartLimitIntervalUSec,StartLimitBurst,RestartUSec
REMOTE
  echo
done

echo "Done. Takes effect on these units' next start attempt - nothing was restarted just now."
