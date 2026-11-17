output "ipv4" {
  value = digitalocean_droplet.ko.ipv4_address
}
output "ipv6" {
  value = digitalocean_droplet.ko.ipv6_address
}
output "ko_host" {
  value = local.names.ko
}
output "ssh_cidrs" {
  value = var.ssh_cidrs
}
