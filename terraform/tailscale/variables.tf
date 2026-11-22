variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/homelab"
}

variable "kube_server" {
  description = "API server. Defaults to sentinel over the tailnet; set to \"\" to use the kubeconfig's."
  type        = string
  default     = "https://100.122.233.25:6443"
}
