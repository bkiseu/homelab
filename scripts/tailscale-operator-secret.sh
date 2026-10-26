#!/usr/bin/env bash
# One-time: store the Tailscale operator's OAuth client as a SOPS-encrypted
# Secret and apply it, plus the Immich Postgres secret (both are applied
# out-of-band; ArgoCD has no SOPS plugin in this repo).
#
# The client secret is read without echo and piped straight into sops, so the
# plaintext never touches disk or shell history.
#
# Usage: scripts/tailscale-operator-secret.sh
#   KUBE_SERVER overrides the API server, e.g. when off the home LAN:
#   KUBE_SERVER=https://100.122.233.25:6443 scripts/tailscale-operator-secret.sh
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=charts/tailscale-operator/dev-secrets.enc.yaml
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
KUBECTL=(kubectl --kubeconfig "${KUBECONFIG_PATH:-$HOME/.kube/homelab}")
[[ -n "${KUBE_SERVER:-}" ]] && KUBECTL+=(--server "$KUBE_SERVER")

if [[ -f "$OUT" ]]; then
  echo "$OUT already exists; skipping creation (delete it to recreate)."
else
  read -r -p "Tailscale OAuth client ID: " CLIENT_ID
  read -r -s -p "Tailscale OAuth client secret (hidden): " CLIENT_SECRET
  echo
  [[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || { echo "Both values are required." >&2; exit 1; }

  "${KUBECTL[@]}" create secret generic operator-oauth -n tailscale \
    --from-literal=client_id="$CLIENT_ID" \
    --from-file=client_secret=<(printf '%s' "$CLIENT_SECRET") \
    --dry-run=client -o yaml \
    | sops --encrypt --input-type yaml --output-type yaml --filename-override "$OUT" /dev/stdin > "$OUT"
  unset CLIENT_SECRET
  grep -q 'ENC\[AES256_GCM' "$OUT" || { echo "Encryption check failed; removing $OUT" >&2; rm -f "$OUT"; exit 1; }
  echo "Wrote encrypted $OUT"
fi

for f in "$OUT" charts/immich/dev-secrets.enc.yaml; do
  echo "Applying $f"
  sops -d "$f" | "${KUBECTL[@]}" apply -f -
done

echo "Restarting the operator so it picks up the secret"
"${KUBECTL[@]}" -n tailscale rollout restart deployment/operator
"${KUBECTL[@]}" -n tailscale rollout status deployment/operator --timeout=180s
