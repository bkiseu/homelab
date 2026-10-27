#!/usr/bin/env bash
# Run terraform against terraform/tailscale with the bootstrap credential
# decrypted into the environment. State holds the operator's OAuth secret, so
# it's kept SOPS-encrypted in git (terraform.tfstate.enc.json) and only exists
# in plaintext for the duration of this script.
#
#   scripts/tailscale-tf.sh plan
#   scripts/tailscale-tf.sh apply
#
# Off the home LAN: TF_VAR_kube_server=https://100.122.233.25:6443
set -euo pipefail
cd "$(dirname "$0")/../terraform/tailscale"

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
CREDS=bootstrap.enc.yaml
STATE_ENC=terraform.tfstate.enc.json

[[ -f "$CREDS" ]] || { echo "Missing $CREDS - run scripts/tailscale-bootstrap-credential.sh first." >&2; exit 1; }

# Re-encrypt whatever state exists on the way out, even after a failed apply.
seal() {
  if [[ -s terraform.tfstate ]]; then
    sops --encrypt --input-type json --output-type json --filename-override "$STATE_ENC" terraform.tfstate > "$STATE_ENC.tmp"
    mv "$STATE_ENC.tmp" "$STATE_ENC"
  fi
  rm -f terraform.tfstate terraform.tfstate.backup
}
trap seal EXIT

if [[ -f "$STATE_ENC" ]]; then
  sops --decrypt --input-type json --output-type json "$STATE_ENC" > terraform.tfstate
fi

terraform init -input=false >/dev/null

tf() { sops exec-env "$CREDS" "terraform $(printf '%q ' "$@")"; }

# The policy file always exists, so it has to be imported before the first
# apply. The plan then shows exactly what changes against the live policy.
if ! terraform state list 2>/dev/null | grep -qx 'tailscale_acl.policy'; then
  tf import tailscale_acl.policy acl
fi

tf "$@"
