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
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.ko_label)) && var.ko_label != "enroll"
    error_message = "Use a DNS label other than enroll."
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
variable "ssh_public_key_path" {
  type    = string
  default = null
}
variable "ssh_public_key" {
  type    = string
  default = null
}
variable "ssh_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.ssh_cidrs) > 0 && alltrue([for cidr in var.ssh_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Supply at least one SSH CIDR."
  }
}
