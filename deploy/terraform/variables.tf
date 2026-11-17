variable "zone_id" {
  type = string
}
variable "zone_name" {
  type = string
}
variable "ko_label" {
  type    = string
  default = "ko"
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.ko_label))
    error_message = "Use a DNS label."
  }
}
variable "region" {
  type    = string
  default = "fra1"
}
variable "size" {
  type    = string
  default = "s-1vcpu-1gb"
}
variable "deployment" {
  type = string
}
variable "ssh_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0", "::/0"]
  validation {
    condition     = length(var.ssh_cidrs) > 0 && alltrue([for cidr in var.ssh_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Supply at least one SSH CIDR."
  }
}
