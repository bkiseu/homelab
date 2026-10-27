variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/homelab"
}

variable "kube_server" {
  description = "Optional API server override, e.g. https://100.122.233.25:6443 when off the home LAN."
  type        = string
  default     = ""
}
