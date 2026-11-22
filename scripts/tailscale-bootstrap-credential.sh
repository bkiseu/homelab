#!/usr/bin/env bash
# Store the Tailscale API access token that Terraform uses to manage the tailnet
# (terraform/tailscale). It's the only thing created in the admin console:
# Settings > Keys > Generate access token.
#
# Why a token and not a bootstrap OAuth client: a client able to hand out
# devices:core/auth_keys has to be given a tag when it's created, and our tags
# don't exist until Terraform has applied the policy. An access token has its
# owner's permissions and needs no tag. It's powerful, so give it a short expiry;
# to change the tailnet after it expires, delete the .enc.yaml and run this again.
# The operator's own OAuth client doesn't expire with the token.
#
# Prompts for the token so it stays out of shell history, writes it SOPS-encrypted.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=terraform/tailscale/bootstrap.enc.yaml
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

if [[ -f "$OUT" ]]; then
  echo "$OUT already exists - delete it first to replace the token." >&2
  exit 1
fi

read -r -s -p "Tailscale API access token (hidden): " TOKEN
echo
if [[ ! "$TOKEN" =~ ^ts[k]ey-api-[A-Za-z0-9-]+$ ]]; then
  echo "That isn't an API access token (Settings > Keys > Generate access token). Nothing written." >&2
  exit 1
fi

if ! printf "TAILSCALE_API_KEY: '%s'\n" "$TOKEN" \
  | sops --encrypt --input-type yaml --output-type yaml --filename-override "$OUT" /dev/stdin > "$OUT"; then
  rm -f "$OUT"
  echo "encryption failed" >&2
  exit 1
fi
unset TOKEN

grep -q 'ENC\[AES256_GCM' "$OUT" || { rm -f "$OUT"; echo "encryption failed" >&2; exit 1; }
echo "Wrote $OUT"
