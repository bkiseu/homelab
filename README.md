# Homelab GitOps

GitOps-driven homelab using k3s, ArgoCD, and SOPS.

## Architecture

```
root-app.yaml (manual apply once)
  └── argocd/applicationsets/dev-appset.yaml
        └── argocd/apps/dev/core.yaml → cert-manager
```

## Prerequisites

- [go-task](https://taskfile.dev): `brew install go-task`
- [sops](https://github.com/getsops/sops): `brew install sops`
- [age](https://github.com/FiloSottile/age): `brew install age`
- [kubectl](https://kubernetes.io/docs/tasks/tools/): `brew install kubectl`
- [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/): `brew install argocd`

## Quick Start

### 1. Setup SOPS (run on each MacBook)

```bash
task setup
```

This generates an age key at `~/.config/sops/age/keys.txt`. Add the public key to `.sops.yaml`.

### 2. Export kubeconfig from k3s node

```bash
# On k3s node
sudo cat /etc/rancher/k3s/k3s.yaml

# Copy to local machine as kubeconfig.yaml
# Update server URL: 127.0.0.1 → your node IP

# Encrypt it
task encrypt-kubeconfig
```

### 3. Bootstrap the cluster (one-time)

```bash
task decrypt-kubeconfig
task bootstrap
```

### 4. Access ArgoCD

```bash
# Get password
task argocd:password

# Port forward UI
task argocd:port-forward

# Open https://localhost:8080
```

## Directory Structure

```
homelab/
├── argocd/
│   ├── applicationsets/     # Per-environment ApplicationSets
│   │   └── dev-appset.yaml
│   └── apps/                # Layer definitions (project + apps)
│       └── dev/
│           └── core.yaml    # dev-core project + cert-manager
├── bootstrap/
│   ├── argocd-install/      # Initial ArgoCD kustomization
│   └── root-app.yaml        # Root application (manual apply)
├── charts/                  # Helm values per app
│   └── cert-manager/
│       └── dev-values.yaml
├── scripts/
│   └── setup-sops.sh
├── .sops.yaml               # SOPS encryption rules
├── kubeconfig.enc.yaml      # Encrypted kubeconfig
└── Taskfile.yaml            # Task runner commands
```

## Adding Apps

Edit `argocd/apps/dev/core.yaml` to add apps to the core layer, or create new layer files:

- `argocd/apps/dev/observability.yaml` - prometheus, loki, grafana
- `argocd/apps/dev/home.yaml` - home-assistant, pihole

Each layer file needs:
1. A `projects:` section defining the ArgoCD project
2. An `applications:` section with the apps

## Common Tasks

```bash
task status           # Check all app sync status
task logs             # View ArgoCD server logs
task sync             # Manually sync all apps
task cluster:info     # Show cluster info
task secret:edit FILE=path/to/secrets.enc.yaml  # Edit encrypted secrets
```

## GitOps Workflow

1. Make changes in git
2. Push to main branch
3. ArgoCD auto-syncs (within 3 minutes)

No manual kubectl commands needed after bootstrap.
