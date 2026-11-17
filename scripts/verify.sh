#!/bin/bash
# Homelab PR verification gate - see .claude/skills/verify/SKILL.md for what
# each section checks and how to read a failure. Run via `task verify`.
#
# Exits 0 if everything passes, 1 if anything failed. Every check here is
# local rendering/parsing against the working tree - nothing touches the
# live cluster (no kubectl apply, no argocd app sync).
set -uo pipefail
cd "$(dirname "$0")/.."

# macOS sops doesn't reliably find ~/.config/sops/age/keys.txt without this
# set explicitly - same issue Taskfile.yaml's secret:apply task works around.
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

FAILED=0
fail() { echo "FAIL: $1"; FAILED=1; }
ok()   { echo "OK: $1"; }

echo "############################################"
echo "# 1. Kustomize overlays"
echo "############################################"
shopt -s nullglob
overlays=(kustomize/overlays/*/*/)
if [ ${#overlays[@]} -eq 0 ]; then
  echo "(no overlays found under kustomize/overlays/*/*/)"
fi
for d in "${overlays[@]}"; do
  if kubectl kustomize "$d" > /dev/null 2>/tmp/verify-kustomize-err; then
    ok "$d"
  else
    fail "$d - kustomize build error: $(tail -1 /tmp/verify-kustomize-err)"
  fi
done
rm -f /tmp/verify-kustomize-err

echo
echo "############################################"
echo "# 2. Helm charts (mechanical: parsed from argocd/apps/dev/*.yaml)"
echo "############################################"
VENV_DIR="scripts/.verify-venv"
VENV_PY="$VENV_DIR/bin/python3"
if [ ! -x "$VENV_PY" ]; then
  echo "bootstrapping isolated venv for PyYAML at $VENV_DIR (one-time, never committed)..."
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install -q --upgrade pip pyyaml
fi

helm_rows="$("$VENV_PY" scripts/verify_helm_apps.py argocd/apps/dev/*.yaml)"
if [ -z "$helm_rows" ]; then
  echo "(no Helm-chart Applications found in argocd/apps/dev/*.yaml)"
else
  while IFS=$'\t' read -r name repo_url chart version values_csv; do
    IFS=',' read -r -a value_files <<< "$values_csv"
    helm_args=(template "$name" "$chart" --repo "$repo_url" --version "$version")
    for vf in "${value_files[@]}"; do
      [ -n "$vf" ] && helm_args+=(-f "$vf")
    done
    if helm "${helm_args[@]}" > /dev/null 2>/tmp/verify-helm-err; then
      ok "$name ($chart @ $version)"
    else
      fail "$name ($chart @ $version) - helm template error: $(tail -1 /tmp/verify-helm-err)"
    fi
  done <<< "$helm_rows"
fi
rm -f /tmp/verify-helm-err

echo
echo "############################################"
echo "# 3. Terraform (skipped cleanly if terraform/ has no modules yet)"
echo "############################################"
tf_dirs=(terraform/*/)
if [ ! -d terraform ] || [ ${#tf_dirs[@]} -eq 0 ]; then
  echo "(no terraform/*/ modules present - skipping)"
else
  for d in "${tf_dirs[@]}"; do
    d="${d%/}"
    if terraform -chdir="$d" fmt -check > /tmp/verify-tf-err 2>&1 \
      && terraform -chdir="$d" init -backend=false -input=false > /tmp/verify-tf-err 2>&1 \
      && terraform -chdir="$d" validate >> /tmp/verify-tf-err 2>&1; then
      ok "$d"
    else
      fail "$d - $(tail -1 /tmp/verify-tf-err)"
    fi
  done
  rm -f /tmp/verify-tf-err
fi

echo
echo "############################################"
echo "# 4. SOPS files are real ciphertext"
echo "############################################"
sops_files=()
while IFS= read -r -d '' f; do
  sops_files+=("$f")
done < <(git ls-files -z -- '*.enc.yaml' '*-secrets.yaml' '*.enc.json')

if [ ${#sops_files[@]} -eq 0 ]; then
  echo "(no *.enc.yaml / *-secrets.yaml / *.enc.json files tracked)"
else
  for f in "${sops_files[@]}"; do
    enc_count=$(grep -c 'ENC\[' "$f" || true)
    if [ "$enc_count" -eq 0 ]; then
      fail "$f - zero ENC[ markers, looks unencrypted (STOP - do not merge, flag to Bryant)"
      continue
    fi
    if sops -d "$f" > /dev/null 2>/tmp/verify-sops-err; then
      ok "$f"
    else
      fail "$f - does not decrypt: $(tail -1 /tmp/verify-sops-err)"
    fi
  done
  rm -f /tmp/verify-sops-err
fi

echo
echo "############################################"
echo "# 5. Plaintext-secret scan of the PR diff"
echo "############################################"
BASE_REF="${VERIFY_BASE_REF:-origin/main}"
if git rev-parse --verify "$BASE_REF" > /dev/null 2>&1; then
  diff_added="$(git diff "$BASE_REF"...HEAD -- . | grep '^+' | grep -v '^+++' || true)"

  secret_patterns='tskey-|BEGIN [A-Z ]*PRIVATE KEY|AGE-SECRET-KEY-|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
  hits="$(printf '%s\n' "$diff_added" | grep -E "$secret_patterns" || true)"
  if [ -n "$hits" ]; then
    fail "diff contains a plaintext-secret-looking pattern (tskey-/PRIVATE KEY/AGE-SECRET-KEY-/ghp_/github_pat_) - STOP, do not merge:"
    printf '%s\n' "$hits"
  fi

  # client_secret:/password: with a long value that isn't already ENC[-wrapped
  kv_hits="$(printf '%s\n' "$diff_added" | grep -E '^\+[[:space:]]*(client_secret|password)[[:space:]]*:[[:space:]]*[A-Za-z0-9+/=_-]{20,}' | grep -v 'ENC\[' || true)"
  if [ -n "$kv_hits" ]; then
    fail "diff has a client_secret:/password: value that looks like plaintext (not ENC[-wrapped) - STOP, do not merge:"
    printf '%s\n' "$kv_hits"
  fi

  if [ -z "$hits" ] && [ -z "$kv_hits" ]; then
    ok "diff against $BASE_REF has no plaintext-secret patterns"
  fi
else
  echo "($BASE_REF not found locally - run 'git fetch origin main' first; skipping diff scan)"
fi

echo
echo "############################################"
echo "# 6. ArgoCD app layer YAML parses"
echo "############################################"
yaml_targets=(argocd/apps/dev/*.yaml argocd/applicationsets/*.yaml)
for f in "${yaml_targets[@]}"; do
  [ -e "$f" ] || continue
  if "$VENV_PY" -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/tmp/verify-yaml-err; then
    ok "$f"
  else
    fail "$f - $(tail -1 /tmp/verify-yaml-err)"
  fi
done
rm -f /tmp/verify-yaml-err

echo
if [ "$FAILED" -eq 0 ]; then
  echo "=== verify: all checks passed ==="
  exit 0
else
  echo "=== verify: FAILED - see FAIL lines above ==="
  exit 1
fi
