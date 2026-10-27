#!/usr/bin/env bash
# One-time: store the bootstrap OAuth client that Terraform uses to manage the
# tailnet (terraform/tailscale). This is the only thing created in the admin
# console: Settings > Trust credentials > OAuth client, scopes Policy File,
# DNS, Feature Settings and OAuth Keys (write). Prompts for the ID and secret
# so neither lands in shell history, and writes them SOPS-encrypted.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=terraform/tailscale/bootstrap.enc.yaml
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

if [[ -f "$OUT" ]]; then
  echo "$OUT already exists - delete it first to replace the credential." >&2
  exit 1
fi

read -r -p "Bootstrap OAuth client ID: " CLIENT_ID
read -r -s -p "Bootstrap OAuth client secret (hidden): " CLIENT_SECRET
echo

printf "TAILSCALE_OAUTH_CLIENT_ID: '%s'\nTAILSCALE_OAUTH_CLIENT_SECRET: '%s'\n" "$CLIENT_ID" "$CLIENT_SECRET" \
  | sops --encrypt --input-type yaml --output-type yaml --filename-override "$OUT" /dev/stdin > "$OUT"
unset CLIENT_SECRET

grep -q 'ENC\[AES256_GCM' "$OUT" || { rm -f "$OUT"; echo "encryption failed" >&2; exit 1; }
echo "Wrote $OUT"
