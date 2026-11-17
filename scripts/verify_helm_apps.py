#!/usr/bin/env python3
"""
Print one TSV line per Helm-chart Application found in the given ArgoCD
layer file(s) (argocd/apps/dev/*.yaml): name, repoURL, chart, targetRevision,
comma-separated resolved value-file paths (repo-relative).

An Application counts as "Helm-chart" if any of its `sources[]` entries has
a `chart:` key. The resolved value-file paths strip the `$values/` prefix
Argo's multi-source apps use to reference this repo's own files - see
argocd/apps/dev/core.yaml's dev-cert-manager/dev-tailscale-operator for the
shape this assumes. Kustomize-only apps (a `path:` source, no `chart:`) are
skipped - scripts/verify.sh handles those via `kubectl kustomize` instead.

Used by scripts/verify.sh, which runs this with the PyYAML-equipped
interpreter from scripts/.verify-venv (bootstrapped on first run, gitignored,
never touches the system Python).
"""
import sys

import yaml


def resolve_values_path(value_file: str) -> str:
    prefix = "$values/"
    if value_file.startswith(prefix):
        return value_file[len(prefix):]
    return value_file


def main(paths: list[str]) -> int:
    for path in paths:
        with open(path) as f:
            doc = yaml.safe_load(f) or {}
        apps = doc.get("applications") or {}
        for name, app in apps.items():
            sources = app.get("sources") or []
            chart_source = next((s for s in sources if "chart" in s), None)
            if chart_source is None:
                continue
            repo_url = chart_source.get("repoURL", "")
            chart = chart_source.get("chart", "")
            version = chart_source.get("targetRevision", "")
            value_files = (chart_source.get("helm") or {}).get("valueFiles") or []
            resolved = [resolve_values_path(v) for v in value_files]
            print("\t".join([name, repo_url, chart, version, ",".join(resolved)]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
