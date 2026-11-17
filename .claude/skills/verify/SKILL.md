---
name: verify
description: Checks that must pass before a homelab PR merges — render every Kustomize overlay and Helm chart's values, validate any Terraform, confirm SOPS files are actually encrypted, scan the diff for plaintext secrets, and confirm ArgoCD app YAML parses. Use before merging any PR in this repo.
---

# Homelab PR verification

Run before merging anything in `bkiseu/homelab`:

```bash
task verify
```

That runs `scripts/verify.sh`, which does everything below in one pass and exits non-zero if any section fails. None of it touches the live cluster — every check is local rendering/parsing against the working tree, no `kubectl apply`, no `argocd app sync`.

## What it checks

1. **Kustomize overlays** — `kubectl kustomize` against every directory under `kustomize/overlays/*/*/`.
2. **Helm charts, mechanically** — `scripts/verify_helm_apps.py` parses `argocd/apps/dev/*.yaml` (via a PyYAML-equipped interpreter in `scripts/.verify-venv`, bootstrapped on first run and gitignored — never installed into the system/Homebrew Python) to find every Application whose `sources[]` includes a `chart:` key, pulling `repoURL`/`chart`/`targetRevision` and resolving its `$values/...` valueFiles paths. `verify.sh` then runs `helm template <name> <chart> --repo <repoURL> --version <targetRevision> -f <values>` for each — no manual pairing to keep in sync by hand.
3. **Terraform** — loops over `terraform/*/` running `fmt -check` then `init -backend=false && validate`. Skips cleanly (not a failure) if `terraform/` doesn't exist yet or has no module directories.
4. **SOPS ciphertext** — `git ls-files -z` (NUL-separated, so filenames with spaces don't break it) over `*.enc.yaml`, `*-secrets.yaml`, `*.enc.json`. Zero `ENC[` markers in a file is an automatic FAIL, not a warning — and `sops -d` must also succeed against it.
5. **Plaintext-secret scan of the diff** — `git diff origin/main...HEAD` (override the base with `VERIFY_BASE_REF` if needed), restricted to added lines, grepped for the Tailscale auth-key prefix, a PEM private-key header, the age private-key prefix, and both GitHub PAT prefixes (classic and fine-grained), plus any `client_secret:`/`password:` holding a long value that isn't already `ENC[`-wrapped. No file is excluded from this scan, including this script and this doc — see Incidents below for why. The patterns themselves are deliberately not spelled out literally here or in `verify.sh`'s own source (a single-char bracket class breaks up the literal string without changing what it matches), so if a real token ever gets pasted into either file, the gate still catches it instead of only catching everyone else's mistakes.
6. **ArgoCD app layer YAML** — parses every `argocd/apps/dev/*.yaml` and `argocd/applicationsets/*.yaml` with `yaml.safe_load` to catch syntax/shape errors. Doesn't catch semantic issues (e.g. a `destination.namespace` ArgoCD would reject at sync time) — that still needs `kubectl apply --dry-run=server` against a live cluster, which this deliberately skips.

## Reading failures

- Kustomize/Helm render failures point at the overlay/chart, not the cluster — reproduce locally (`kubectl kustomize <dir>` or the printed `helm template` command) before assuming it's an environment problem.
- A Terraform failure from `fmt -check` means run `terraform fmt` and recommit; from `validate`, read the printed error — it's almost always a missing required variable or provider block.
- A SOPS or diff-scan failure is a stop-the-line issue, not a style nit. If either fires, flag it to Bryant directly rather than merging, even if asked to.
- YAML parse failures in ArgoCD layer files are almost always a bad indent under `applications:` or a missing `---`/duplicate key — the script's Python error includes a line number.

## Known failures

Checks that have broken before, their root cause, and open fix-queue items. Empty until the first one — append here when a check itself turns out wrong (not when it correctly caught something; that's an Incident, below).

_(none yet)_

## Incidents

When something slips through verification and reaches `main` anyway: find the root cause, add or fix a check so the same class of problem can't slip through silently again, then log it here — dated, with what broke and which check changed.

- **2026-11 — Secret scanner self-match → exclusion blind spot.** The plaintext-secret scan (check 5) originally flagged its own pattern definitions and fail-messages in `verify.sh`/`SKILL.md` as leaked secrets, since those files legitimately contained the literal strings being searched for. First fix excluded both files from the scan - but that meant a real secret pasted into either one would pass silently, which defeats the point of a gate that's supposed to catch exactly that. Root cause wasn't the self-match, it was fixing it by carving out a blind spot. Fixed properly by rewriting the patterns (and their descriptions in this doc) so they don't contain the literal substrings they match - a single-char bracket class around one letter of each prefix - and removed the exclusions entirely.
- **2026-11 — Tailscale OAuth client setup was manual console clicks, not code.** PR #5 (Tailscale-via-Terraform) exists specifically to close this: the OAuth client and its tags were originally created by hand in the Tailscale admin console per the instructions in `argocd/apps/dev/core.yaml`'s `dev-tailscale-operator` comment block, rather than declared in Terraform like everything else in this repo is meant to be (Bryant's rule: infra changes live in code, not console clicks). No automated check catches "a step that should have been Terraform wasn't" — that's a review-judgment call, not something `verify.sh` can currently assert. Once #5 merges, new Tailscale-admin-console resources should go through its Terraform module instead of a comment-block runbook.
