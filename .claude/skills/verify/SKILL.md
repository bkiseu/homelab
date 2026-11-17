---
name: verify
description: Checks that must pass before a homelab PR merges — render every Kustomize overlay and Helm chart's values, validate any Terraform, confirm SOPS files are actually encrypted, and confirm ArgoCD app YAML parses. Use before merging any PR in this repo.
---

# Homelab PR verification

Run before merging anything in `bkiseu/homelab`. None of this touches the live cluster — every check below is local rendering/parsing against the working tree, no `kubectl apply`, no `argocd app sync`.

## 1. Kustomize overlays build

Every directory under `kustomize/overlays/*/*` must render without error:

```bash
for d in kustomize/overlays/*/*/; do
  echo "== $d =="
  kubectl kustomize "$d" > /dev/null || echo "FAILED: $d"
done
```

A failure here usually means a missing/renamed resource in the overlay's `kustomization.yaml`, or a base resource that doesn't exist at the referenced path.

## 2. Helm chart values

Every chart under `charts/<app>/` with a `dev-values.yaml` must template cleanly against the chart/version pinned in the matching ArgoCD layer file (`argocd/apps/dev/*.yaml`, `sources[].targetRevision`):

```bash
for f in charts/*/dev-values.yaml; do
  chart_dir=$(dirname "$f")
  app=$(basename "$chart_dir")
  echo "== $app =="
  # repoURL/chart/targetRevision for $app live in argocd/apps/dev/*.yaml - match
  # them manually (grep for the app name) since values files don't carry chart
  # identity themselves, then:
  #   helm template <app> <repoURL> --repo <repoURL>... -f "$f"
  # or, for a chart already in a local Helm repo cache, --version <targetRevision>
done
```

There's no single mechanical loop here because each layer file's `sources` block is the source of truth for which chart+version a `dev-values.yaml` belongs to — check `argocd/apps/dev/core.yaml` and `apps.yaml` for the pairing before templating. A failure usually means the values file uses a key the pinned chart version doesn't recognize (check the chart's version bump notes) or a required value was left unset.

## 3. Terraform (once `terraform/` exists)

As of this writing `terraform/` doesn't exist in `main` yet (it's introduced in PR #5, Tailscale-via-Terraform — not merged). Once it lands:

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Skip this section with a note in the PR if `terraform/` isn't present yet — don't fail a PR over a directory that doesn't exist on the branch it's based on.

## 4. SOPS files are actually encrypted

Every file matching `.sops.yaml`'s patterns (`*.enc.yaml`, `*-secrets.yaml`, `kubeconfig.enc.yaml`) must contain only SOPS ciphertext — never plaintext secret values, even transiently in a diff:

```bash
for f in $(git ls-files | grep -E '\.enc\.yaml$|-secrets\.yaml$'); do
  echo "== $f =="
  # Every leaf secret value should show up as ENC[...]; grep for ENC[ and compare
  # count against the number of secret keys sops's own metadata lists.
  grep -c 'ENC\[' "$f" || echo "FAILED: $f has no ENC[ markers - may be plaintext"
  # Confirm sops itself considers it valid ciphertext (requires the age key):
  sops -d "$f" > /dev/null && echo "decrypts OK" || echo "FAILED: $f does not decrypt"
done
```

A failure here is a stop-the-line issue, not a style nit — if `grep -c 'ENC\['` comes back 0, treat the PR as leaking a secret and flag it to Bryant directly rather than merging, even if asked to.

## 5. ArgoCD app layer YAML parses

Every file under `argocd/apps/dev/*.yaml` and `argocd/applicationsets/*.yaml` must be valid YAML with the `projects:`/`applications:` (or ApplicationSet) shape the `argocd-apps` chart expects:

```bash
for f in argocd/apps/dev/*.yaml argocd/applicationsets/*.yaml; do
  echo "== $f =="
  python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$f" || echo "FAILED: $f"
done
```

This only catches YAML syntax errors and gross shape problems, not semantic ones (e.g. a `destination.namespace` ArgoCD will reject at sync time) — those still need `kubectl apply --dry-run=server` against a live cluster, which this skill deliberately doesn't do.

## Reading failures

- Kustomize/Helm render failures point at the overlay/chart, not the cluster — reproduce locally before assuming it's an environment problem.
- A SOPS failure (missing `ENC[`, or `sops -d` erroring) means either the file was committed unencrypted, or it's encrypted for an age recipient whose key isn't on this machine — check `.sops.yaml`'s recipient list for the path before assuming the second.
- YAML parse failures in ArgoCD layer files are almost always a bad indent under `applications:` or a missing `---`/duplicate key — `python3 -c "...yaml.safe_load..."` will print the line number.

## Known failures

_(Append an entry here per incident: what broke, which check should have caught it but didn't, and what changed to close the gap. Empty until the first one.)_
