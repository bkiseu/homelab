#!/bin/bash
# Runs ON a Pi node, as root (invoked by pin-node-ips.sh via
# `ssh -t host sudo bash /tmp/pin-node-ip-remote.sh <mode> <node> <mac> <ip>`,
# then deleted). Not meant to be copied anywhere permanent or run by hand -
# see scripts/pin-node-ips.sh for the orchestration and design rationale
# (why -t, why netplan generate and never apply, why this never reads
# 50-cloud-init.yaml's contents beyond one device-key line).
#
# Usage: pin-node-ip-remote.sh check|apply <node> <expected-mac> <expected-ip>
set -uo pipefail

MODE="${1:?mode (check|apply) required}"
NODE="${2:?expected node name required}"
EXPECTED_MAC="${3:?expected wlan0 MAC required}"
EXPECTED_IP="${4:?expected IP required}"
OVERRIDE_PATH="/etc/netplan/60-pin-node-ip.yaml"

FAILED=0
fail() { echo "FAIL: $1"; FAILED=1; }
ok()   { echo "OK: $1"; }
warn() { echo "WARN: $1"; }

# --- hostname -----------------------------------------------------------
actual_hostname="$(hostname)"
if [ "$actual_hostname" != "$NODE" ]; then
  fail "hostname is '$actual_hostname', expected '$NODE' - refusing to touch this host"
else
  ok "hostname matches"
fi

# --- wlan0 MAC ------------------------------------------------------------
actual_mac="$(cat /sys/class/net/wlan0/address 2>&1)"
if [ "$actual_mac" != "$EXPECTED_MAC" ]; then
  fail "wlan0 MAC is '$actual_mac', expected '$EXPECTED_MAC'"
else
  ok "wlan0 MAC matches"
fi

# --- device-id key in 50-cloud-init.yaml -----------------------------------
# The only line ever read from this file - it holds the wifi PSK. Walks
# indentation (netplan always nests wifis: under network:, so this can't
# assume a fixed column) to find the key one level deeper than `wifis:`
# itself, and stops as soon as indentation drops back to or below that -
# it never descends into access-points/password lines, which sit two
# levels deeper still.
device_key="$(awk '
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
  ' /etc/netplan/50-cloud-init.yaml 2>&1)"
if [ "$device_key" != "wlan0" ]; then
  fail "50-cloud-init.yaml's wifis: device key is '$device_key', expected literally 'wlan0' (networkd's renderer requires this for wifi - see pin-node-ips.sh header)"
else
  ok "wifis: device key is 'wlan0'"
fi

# --- is the target address already live on this node's OWN wlan0? ---------
# Informational, not pass/fail: this is what distinguishes "clean, never
# assigned anywhere" from "sentinel already has this via the manual
# `ip addr add` from 2026-11-22, but only until next reboot."
live_already="false"
if ip -4 -o addr show wlan0 2>/dev/null | grep -q " ${EXPECTED_IP}/"; then
  live_already="true"
fi

# --- is anyone else currently answering for the target address? -----------
# arping -D run from THIS node's own wlan0, for an address already
# configured on this same interface, correctly reports "0 responses" / exit
# 0 (not a conflict) - Linux doesn't ARP-reply to itself about its own
# address on the same link, confirmed in a throwaway two-container test
# before trusting this. So the self-vs-other distinction below is purely
# about the message shown, not the conflict logic itself.
if command -v arping >/dev/null 2>&1; then
  if arping -D -c 2 -I wlan0 "$EXPECTED_IP" >/dev/null 2>&1; then
    if [ "$live_already" = "true" ]; then
      ok "no conflict for $EXPECTED_IP (it's already this node's own address - manual/temporary, see WARN below)"
    else
      ok "no other host answers for $EXPECTED_IP"
    fi
  else
    fail "something else on the network answered for $EXPECTED_IP - do not pin this address until that's resolved"
  fi
else
  warn "arping not installed - could not check for an address conflict. Install iputils-arping or verify by hand before trusting --apply."
fi

existing="absent"
[ -f "$OVERRIDE_PATH" ] && existing="present"
echo "override file currently: $existing"

if [ "$live_already" = "true" ]; then
  if [ "$existing" = "present" ]; then
    warn "$EXPECTED_IP is live on wlan0 right now AND already pinned in $OVERRIDE_PATH - it will survive the next reboot."
  else
    warn "$EXPECTED_IP is live on wlan0 right now, but only as a manual/temporary assignment - it is NOT in netplan yet and will be lost on the next reboot until this override is applied."
  fi
fi

if [ "$MODE" = "check" ]; then
  [ "$FAILED" -eq 0 ]
  exit $?
fi

# --- apply ------------------------------------------------------------------
if [ "$FAILED" -ne 0 ]; then
  echo "ABORT: pre-flight checks failed, nothing written"
  exit 1
fi

desired="$(cat <<YAML
network:
  version: 2
  wifis:
    wlan0:
      dhcp4: true
      addresses:
        - ${EXPECTED_IP}/24
YAML
)"

current="$(cat "$OVERRIDE_PATH" 2>/dev/null || true)"
if [ "$current" = "$desired" ]; then
  ok "$OVERRIDE_PATH already matches - nothing to do (idempotent no-op)"
  exit 0
fi

echo "writing $OVERRIDE_PATH ..."
tmp="${OVERRIDE_PATH}.new"
if ! printf '%s\n' "$desired" > "$tmp"; then
  fail "could not write $tmp, nothing changed"
  exit 1
fi
chmod 600 "$tmp"
chown root:root "$tmp"

if ! mv "$tmp" "$OVERRIDE_PATH"; then
  fail "could not move $tmp into place, rolling back"
  rm -f "$tmp"
  exit 1
fi

echo "validating with 'netplan generate' (does not apply/restart networking) ..."
if netplan generate 2>&1; then
  ok "$OVERRIDE_PATH written and validated. Takes effect on next reboot - nothing was applied or restarted just now."
  exit 0
else
  echo "FAIL: netplan generate rejected the merged config - rolling back $OVERRIDE_PATH"
  if [ -n "$current" ]; then
    printf '%s\n' "$current" > "$OVERRIDE_PATH"
  else
    rm -f "$OVERRIDE_PATH"
  fi
  netplan generate >/dev/null 2>&1 || true
  exit 1
fi
