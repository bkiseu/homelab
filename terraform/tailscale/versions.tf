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

# Auth comes from TAILSCALE_API_KEY (an API access token),
# injected from bootstrap.enc.yaml by scripts/tailscale-tf.sh.
provider "tailscale" {}

provider "kubernetes" {
  config_path = var.kubeconfig_path
  # The tailnet IP works on and off the LAN; TLS is still verified (it's a SAN).
  host = var.kube_server != "" ? var.kube_server : null
}
