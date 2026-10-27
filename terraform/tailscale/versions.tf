terraform {
  required_version = ">= 1.10"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
  }
}

# Auth comes from TAILSCALE_OAUTH_CLIENT_ID / TAILSCALE_OAUTH_CLIENT_SECRET,
# injected from bootstrap.enc.yaml by scripts/tailscale-tf.sh.
provider "tailscale" {}

provider "kubernetes" {
  config_path = var.kubeconfig_path
  # The Pis' LAN IP isn't reachable off-LAN; override with the tailnet IP.
  host = var.kube_server != "" ? var.kube_server : null
}
