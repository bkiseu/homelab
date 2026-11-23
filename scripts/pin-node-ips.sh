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
# sentinel specifically still has that manual `ip addr add` live right now
# (not in netplan) - this script's dry-run flags that with a WARN rather
# than treating it as a conflict with itself; see pin-node-ip-remote.sh.
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
# already key wlan0 by its literal interface name - pin-node-ip-remote.sh
# still confirms that on the node before writing anything rather than
# assuming it from a test on a different file.
#
# WHY `ssh -t ... sudo bash <remote script>` instead of `ssh host sudo ...`
# per-command: these nodes' sudo needs a password (confirmed - Bryant
# already uses `ssh -t` for that). A bare `ssh host "sudo ..."` has no TTY
# for sudo to prompt on, so every call would fail with "sudo: a terminal is
# required to read the password" - it fails safe, but every check would
# misreport as a generic failure instead of what's actually wrong. Tested
# end-to-end in a container with a password-protected sudo user (key-based
# SSH login, password-required sudo - the same shape as these nodes): a
# bare `ssh host sudo whoami` reproduces that exact error; `ssh -t host sudo
# bash <remote script>` correctly opens a pty, prompts for the password
# (Bryant types it, same as his own `ssh -t` habit - this script never
# sees or stores it), and the remote script runs as root. Because `-t`
# allocates a real pty, piping the override's contents over stdin isn't an
# option here - pin-node-ip-remote.sh re-derives it from the IP argument
# instead of having it piped in.
#
# WHY the remote copy lives in $HOME, not a fixed /tmp path: /tmp is
# world-writable, so a fixed name there is a symlink/swap target for
# another local user - low stakes on a single-user Pi, but there's no
# reason to leave it open. mktemp creates a randomly-named file directly in
# the SSH user's home (`~/.pin-node-ip-remote.XXXXXX.sh`, chmod 700), and
# it's removed on every exit from run_node below - success, an early
# failure (bad mktemp/scp/sudo), or a Ctrl-C while the remote sudo/script
# is running (trap on INT/TERM, not just the normal fall-through path).
#
# A real Ctrl-C at an actual terminal does clean this up: tested by sending
# the interrupt into the pty right at the sudo password prompt, and the
# remote temp file was gone afterward. That works because a terminal
# delivers SIGINT to the whole foreground process group at once - this
# script AND the `ssh -t` child both get it, the child dies, and bash's
# own wait() for that child unblocks, running the pending trap right away.
# Separately confirmed what does NOT clean up promptly: sending SIGINT to
# only this script's PID (bypassing the terminal/process group, the way a
# process supervisor might) while `ssh -t` is still blocked on the
# password prompt - bash defers a trap until the foreground command it's
# waiting on actually returns, so the file sits there until that ssh
# session eventually ends on its own. Real interactive Ctrl-C doesn't hit
# this because of the process-group delivery above; a bare `kill` targeting
# just this process's PID would.
#
# WHAT THIS DOESN'T READ: never opens /etc/netplan/50-cloud-init.yaml's
# contents - it holds the wifi PSK. The one thing read from it is a single
# line (the top-level device-id key under `wifis:`), via a narrow grep that
# cannot match an access-points/password line. See pin-node-ip-remote.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SCRIPT="$SCRIPT_DIR/pin-node-ip-remote.sh"

# node -> "ssh_target mac ip". A plain case statement, not `declare -A`:
# this script runs on Bryant's Mac, not the Pis, and macOS's default
# /usr/bin/env bash resolves to Apple's bash 3.2 (no Homebrew bash
# installed, confirmed while testing this) - which has no associative
# arrays at all. An earlier version of this script used declare -A and
# crashed with "unbound variable" on this exact Mac before it got as far
# as printing usage.
ALL_NODES="sentinel watchtower cyclone"

node_info() {
  case "$1" in
    sentinel)   echo "sentinel@100.122.233.25 2c:cf:67:af:47:16 192.168.100.18" ;;
    watchtower) echo "bryant@100.76.174.97 2c:cf:67:ec:f8:66 192.168.100.12" ;;
    cyclone)    echo "bryant@100.87.34.58 2c:cf:67:ed:4c:c3 192.168.100.14" ;;
    *) return 1 ;;
  esac
}

log() { echo "[$1] $2"; }

usage() {
  echo "Usage: $0 [<node>] | $0 --apply <node>" >&2
  echo "Nodes: $ALL_NODES" >&2
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

if [ -n "$TARGET" ] && ! node_info "$TARGET" >/dev/null; then
  echo "ERROR: unknown node '$TARGET'" >&2
  usage
fi

[ -f "$REMOTE_SCRIPT" ] || { echo "ERROR: $REMOTE_SCRIPT not found" >&2; exit 1; }

TARGETS=($ALL_NODES)
[ -n "$TARGET" ] && TARGETS=("$TARGET")

# --- per-node run ------------------------------------------------------------

remote_cleanup() {
  local node="$1" ssh_target="$2" remote_tmp="$3"
  [ -n "$remote_tmp" ] || return 0
  ssh -o ConnectTimeout=10 "$ssh_target" "rm -f '$remote_tmp'" 2>/dev/null \
    || log "$node" "WARN: could not remove $remote_tmp from the node - clean it up by hand"
}

run_node() {
  local node="$1" ssh_target="$2" mac="$3" ip="$4" mode="$5"
  local rc=0
  local remote_tmp=""

  # Covers Ctrl-C/SIGTERM while this node is being processed, not just the
  # normal fall-through at the bottom of this function. Single-quoted so
  # $remote_tmp is read at trap-FIRE time (whatever mktemp below set it
  # to), not frozen empty at trap-SET time.
  trap 'remote_cleanup "$node" "$ssh_target" "$remote_tmp"' INT TERM

  log "$node" "creating a private temp path on $node ..."
  # Only stdout is captured into remote_tmp - anything ssh itself writes to
  # stderr (a first-connection host-key warning, a banner, whatever) still
  # reaches this terminal but can't corrupt the path we're about to scp to
  # and later rm. Caught exactly this happening during testing: with stderr
  # merged in, a host-key warning ended up prepended to $remote_tmp, which
  # broke both the scp (wrong path) and the rollback cleanup (couldn't find
  # the file mktemp had actually created).
  if ! remote_tmp="$(ssh -o ConnectTimeout=10 "$ssh_target" \
    'f=$(mktemp "$HOME/.pin-node-ip-remote.XXXXXX.sh") && chmod 700 "$f" && echo "$f"')"; then
    log "$node" "FAIL: could not create a temp path on $node"
    trap - INT TERM
    return 1
  fi
  if [ -z "$remote_tmp" ]; then
    log "$node" "FAIL: mktemp on $node returned an empty path"
    trap - INT TERM
    return 1
  fi

  log "$node" "copying remote script to $remote_tmp ..."
  if ! scp -o ConnectTimeout=10 -q "$REMOTE_SCRIPT" "${ssh_target}:${remote_tmp}"; then
    log "$node" "FAIL: could not scp the remote script to $node"
    remote_cleanup "$node" "$ssh_target" "$remote_tmp"
    trap - INT TERM
    return 1
  fi

  # -t: sudo on these nodes needs a password and can only prompt for one
  # with a real pty. Output streams back live, so the prompt (and anything
  # else) shows up in this terminal as it happens.
  log "$node" "running ($mode) over $ssh_target - sudo will prompt for your password on the node ..."
  if ! ssh -t -o ConnectTimeout=10 "$ssh_target" "sudo bash '$remote_tmp' '$mode' '$node' '$mac' '$ip'"; then
    rc=1
  fi

  remote_cleanup "$node" "$ssh_target" "$remote_tmp"
  trap - INT TERM
  return "$rc"
}

# --- main --------------------------------------------------------------------

overall_rc=0
for node in "${TARGETS[@]}"; do
  read -r ssh_target mac ip <<< "$(node_info "$node")"
  echo "============================================================"
  if [ "$APPLY" -eq 1 ]; then
    run_node "$node" "$ssh_target" "$mac" "$ip" apply || overall_rc=1
  else
    echo "[$node] DRY RUN - would pin $ip/24 on wlan0 via /etc/netplan/60-pin-node-ip.yaml"
    run_node "$node" "$ssh_target" "$mac" "$ip" check || overall_rc=1
  fi
done
echo "============================================================"
exit "$overall_rc"
