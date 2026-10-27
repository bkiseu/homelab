# Tailnet configuration for the homelab. Everything that used to be a click
# in the Tailscale admin console lives here.

# Whole policy file (tag definitions now, access rules later). Applying this
# replaces whatever is in the admin console - edit policy.hujson, not the UI.
resource "tailscale_acl" "policy" {
  acl = file("${path.module}/policy.hujson")
}

resource "tailscale_dns_preferences" "this" {
  magic_dns = true
}

# Needed for Tailscale Ingress: each proxy gets a Let's Encrypt cert for
# <name>.<tailnet>.ts.net. Hostnames end up in public CT logs.
resource "tailscale_tailnet_settings" "this" {
  https_enabled = true
}

# Credential the Kubernetes operator uses to create its proxy devices.
# devices:core + auth_keys is what plain Ingress needs; add "services" if we
# move to ProxyGroup/Tailscale Services.
resource "tailscale_oauth_client" "k8s_operator" {
  description = "homelab k8s operator"
  scopes      = ["devices:core", "auth_keys"]
  tags        = ["tag:k8s-operator"]

  depends_on = [tailscale_acl.policy]
}

# The chart expects this pre-existing Secret (oauth block left empty in
# charts/tailscale-operator/dev-values.yaml).
resource "kubernetes_secret_v1" "operator_oauth" {
  metadata {
    name      = "operator-oauth"
    namespace = "tailscale"
  }

  data = {
    client_id     = tailscale_oauth_client.k8s_operator.id
    client_secret = tailscale_oauth_client.k8s_operator.key
  }
}
