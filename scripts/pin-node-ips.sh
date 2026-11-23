#!/usr/bin/env bash
# Pins each Pi node's LAN address via a netplan override, so losing a DHCP
# lease while a node is off (see the 2026-11-22 incident below) doesn't
# strand it on the wrong address after reboot.
#
# Usage:
#   ./pin-node-ips.sh                    # dry-run: check all three nodes
#   ./pin-node-ips.sh <node>             # dry-run: check just one node
#   ./pin-node-ips.sh --apply <node>     # write the override on ONE node
#
# --apply never takes more than one node in a single run: writing this to
# two nodes back-to-back, with no human eyeballing the first result, is how
# you lose etcd/k8sd quorum if something's wrong. Run it once, read the
# output, run it again for the next node.
#
# MAC / IP table:
#   sentinel    user sentinel  tailnet 100.122.233.25  wlan0 2c:cf:67:af:47:16  -> 192.168.100.18/24
#   watchtower  user bryant    tailnet 100.76.174.97   wlan0 2c:cf:67:ec:f8:66  -> 192.168.100.12/24
#   cyclone     user bryant    tailnet 100.87.34.58    wlan0 2c:cf:67:ed:4c:c3  -> 192.168.100.14/24
#
# LIMITATION (read this before trusting this script): a static address on
# the node does not stop the router's DHCP server from handing that same
# address to a DIFFERENT device while this node is off - that's exactly
# what happened to sentinel on 2026-11-22 (it came back up with .27, having
# lost .18 to another device, and etcd/k8sd failed to bind until Bryant ran
# a manual `ip addr add 192.168.100.18/24 dev wlan0` and restarted both).
# The real fix is a DHCP reservation on the router (Huawei HG8145V6), keyed
# by the MAC addresses above - Bryant can't log into it yet. Until he can,
# this script only guarantees the node claims its address once it's back on
# the network; it can't stop something else from claiming it first.
#
# UNDO: on the node, run
#   sudo rm /etc/netplan/60-pin-node-ip.yaml && sudo netplan generate
# (no reboot or netplan apply needed to undo - same reasoning as below).
#
# WHY `netplan generate`, never `netplan apply` or a networkd restart: this
# script runs over the same wifi link it would be reconfiguring. `netplan
# apply` (or restarting systemd-networkd) would renegotiate wlan0 live,
# which is exactly the kind of mid-session network bounce we don't want to
# risk remotely. `netplan generate` only re-renders the systemd-networkd/
# wpa_supplicant files on disk and does a harmless `systemctl daemon-reload`
# - it validates the merged netplan config (that's how this script catches
# a bad override before leaving it in place) without touching the live
# interface. The pinned address takes effect on this node's next natural
# reboot, not immediately - this script can't fix today's incident, only
# the next one.
#
# WHY the override is keyed `wlan0:` with no `match:`/`set-name:`: tested in
# a throwaway container (ubuntu:24.04 + netplan.io, dummy SSID/PSK, never
# the real nodes or the real 50-cloud-init.yaml): netplan's networkd
# renderer flatly rejects match:-keyed wifi devices ("networkd backend does
# not support wifi with match:, only by interface name"). Since these
# nodes' wifi already works today, their real 50-cloud-init.yaml must
# already key wlan0 by its literal interface name - but this script still
# confirms that on the node before writing anything (detect_device_key)
# rather than assuming it from a test on a different file.
#
# WHAT THIS DOESN'T READ: never opens /etc/netplan/50-cloud-init.yaml's
# contents - it holds the wifi PSK. The one thing read from it is a single
# line (the top-level device-id key under `wifis:`), via a narrow grep that
# cannot match an access-points/password line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDE_NAME="60-pin-node-ip.yaml"
OVERRIDE_PATH="/etc/netplan/${OVERRIDE_NAME}"

# node -> "ssh_target mac ip"
declare -A NODES=(
  [sentinel]="sentinel@100.122.233.25 2c:cf:67:af:47:16 192.168.100.18"
  [watchtower]="bryant@100.76.174.97 2c:cf:67:ec:f8:66 192.168.100.12"
  [cyclone]="bryant@100.87.34.58 2c:cf:67:ed:4c:c3 192.168.100.14"
)

log() { echo "[$1] $2"; }

usage() {
  echo "Usage: $0 [<node>] | $0 --apply <node>" >&2
  echo "Nodes: ${!NODES[*]}" >&2
  exit 1
}

# --- argument parsing -------------------------------------------------------

APPLY=0
TARGET=""

if [ "${1:-}" = "--apply" ]; then
  APPLY=1
  shift
  [ $# -eq 1 ] || { echo "ERROR: --apply requires exactly one node" >&2; usage; }
  TARGET="$1"
elif [ $# -gt 1 ]; then
  usage
elif [ $# -eq 1 ]; then
  [ "$1" = "-h" ] || [ "$1" = "--help" ] && usage
  TARGET="$1"
fi

if [ -n "$TARGET" ] && [ -z "${NODES[$TARGET]+x}" ]; then
  echo "ERROR: unknown node '$TARGET'" >&2
  usage
fi

TARGETS=("${!NODES[@]}")
[ -n "$TARGET" ] && TARGETS=("$TARGET")

# --- per-node logic ----------------------------------------------------------

check_node() {
  local node="$1" ssh_target="$2" expected_mac="$3" expected_ip="$4"
  local ok=1

  log "$node" "checking over $ssh_target ..."

  local actual_hostname
  if ! actual_hostname="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$ssh_target" hostname 2>&1)"; then
    log "$node" "FAIL: could not SSH (over tailnet): $actual_hostname"
    return 1
  fi
  if [ "$actual_hostname" != "$node" ]; then
    log "$node" "FAIL: hostname is '$actual_hostname', expected '$node' - refusing to touch this host"
    ok=0
  else
    log "$node" "OK: hostname matches"
  fi

  local actual_mac
  actual_mac="$(ssh "$ssh_target" cat /sys/class/net/wlan0/address 2>&1 || true)"
  if [ "$actual_mac" != "$expected_mac" ]; then
    log "$node" "FAIL: wlan0 MAC is '$actual_mac', expected '$expected_mac'"
    ok=0
  else
    log "$node" "OK: wlan0 MAC matches"
  fi

  # The only line ever read from 50-cloud-init.yaml: the top-level key
  # immediately under whatever indentation level `wifis:` is at (netplan
  # always nests it under `network:`, so this can't assume a fixed column).
  # Walks indentation rather than matching a fixed prefix, so it finds the
  # device key one level deeper than `wifis:` itself and stops as soon as
  # indentation drops back to or below that - it never descends into
  # access-points/password lines, which sit two levels deeper still.
  local device_key
  device_key="$(ssh "$ssh_target" sudo awk '
      function indent(s) { n = 0; while (substr(s, n+1, 1) == " ") n++; return n }
      {
        if ($0 ~ /^[[:space:]]*wifis:[[:space:]]*$/) { inwifis=1; wifis_indent=indent($0); next }
        if (inwifis) {
          if ($0 ~ /^[[:space:]]*$/) next
          cur = indent($0)
          if (cur <= wifis_indent) { inwifis = 0 }
          else if (cur == wifis_indent + 2 && $0 ~ /:[[:space:]]*$/) {
            key = $0; sub(/^[[:space:]]+/, "", key); sub(/:[[:space:]]*$/, "", key)
            print key; exit
          }
        }
      }
    ' /etc/netplan/50-cloud-init.yaml 2>&1 || true)"
  if [ "$device_key" != "wlan0" ]; then
    log "$node" "FAIL: 50-cloud-init.yaml's wifis: device key is '$device_key', expected literally 'wlan0' (see script header - networkd renderer requires this, but confirm before trusting it)"
    ok=0
  else
    log "$node" "OK: wifis: device key is 'wlan0'"
  fi

  # Duplicate-address check: ask the node itself whether something else on
  # the wifi segment currently answers for the target IP. arping -D exits
  # 0 when the address looks free (no reply from a different MAC), nonzero
  # when something answered - which is exactly backwards from a normal
  # ping-style check, so don't substitute one in without re-reading this.
  if ssh "$ssh_target" command -v arping >/dev/null 2>&1; then
    if ssh "$ssh_target" sudo arping -D -c 2 -I wlan0 "$expected_ip" >/dev/null 2>&1; then
      log "$node" "OK: no other host answers for $expected_ip"
    else
      log "$node" "FAIL: something else on the network answered for $expected_ip - do not pin this address until that's resolved"
      ok=0
    fi
  else
    log "$node" "WARN: arping not installed on $node - could not check for an address conflict. Install iputils-arping or verify by hand before --apply."
  fi

  local existing
  existing="$(ssh "$ssh_target" "test -f $OVERRIDE_PATH && echo present || echo absent" 2>&1 || echo absent)"
  log "$node" "override file currently: $existing"

  [ "$ok" -eq 1 ]
}

render_override() {
  local ip="$1"
  cat <<EOF
network:
  version: 2
  wifis:
    wlan0:
      dhcp4: true
      addresses:
        - ${ip}/24
EOF
}

apply_node() {
  local node="$1" ssh_target="$2" expected_mac="$3" expected_ip="$4"

  if ! check_node "$node" "$ssh_target" "$expected_mac" "$expected_ip"; then
    log "$node" "ABORT: pre-flight checks failed, nothing written"
    return 1
  fi

  local desired
  desired="$(render_override "$expected_ip")"

  local current
  current="$(ssh "$ssh_target" "sudo cat $OVERRIDE_PATH 2>/dev/null" || true)"
  if [ "$current" = "$desired" ]; then
    log "$node" "OK: $OVERRIDE_PATH already matches - nothing to do (idempotent no-op)"
    return 0
  fi

  log "$node" "writing $OVERRIDE_PATH ..."
  local tmp="${OVERRIDE_PATH}.new"
  if ! printf '%s\n' "$desired" | ssh "$ssh_target" "sudo tee '$tmp' >/dev/null && sudo chmod 600 '$tmp' && sudo chown root:root '$tmp'"; then
    log "$node" "FAIL: could not write $tmp, nothing changed"
    return 1
  fi

  if ! ssh "$ssh_target" "sudo mv '$tmp' '$OVERRIDE_PATH'"; then
    log "$node" "FAIL: could not move $tmp into place, rolling back"
    ssh "$ssh_target" "sudo rm -f '$tmp'" || true
    return 1
  fi

  log "$node" "validating with 'netplan generate' (does not apply/restart networking) ..."
  if ssh "$ssh_target" "sudo netplan generate" 2>&1; then
    log "$node" "OK: $OVERRIDE_PATH written and validated. Takes effect on next reboot - nothing was applied or restarted just now."
  else
    log "$node" "FAIL: netplan generate rejected the merged config - rolling back $OVERRIDE_PATH"
    if [ "$current" != "" ]; then
      printf '%s\n' "$current" | ssh "$ssh_target" "sudo tee '$OVERRIDE_PATH' >/dev/null"
    else
      ssh "$ssh_target" "sudo rm -f '$OVERRIDE_PATH'"
    fi
    ssh "$ssh_target" "sudo netplan generate" >/dev/null 2>&1 || true
    return 1
  fi
}

# --- main --------------------------------------------------------------------

overall_rc=0
for node in "${TARGETS[@]}"; do
  read -r ssh_target mac ip <<< "${NODES[$node]}"
  echo "============================================================"
  if [ "$APPLY" -eq 1 ]; then
    apply_node "$node" "$ssh_target" "$mac" "$ip" || overall_rc=1
  else
    echo "[$node] DRY RUN - would pin $ip/24 on wlan0 via $OVERRIDE_PATH"
    check_node "$node" "$ssh_target" "$mac" "$ip" || overall_rc=1
    echo "[$node] would write:"
    render_override "$ip" | sed "s/^/[$node]   /"
  fi
done
echo "============================================================"
exit "$overall_rc"
