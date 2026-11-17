locals {
  ssh_key = trimspace(file("${var.deployment}/id_ed25519.pub"))
  ko_host = "${var.ko_label}.${var.zone_name}"
  names   = { ko = local.ko_host, enroll = "enroll.${local.ko_host}" }
}

resource "digitalocean_ssh_key" "operator" {
  name       = local.names.ko
  public_key = local.ssh_key
}

resource "digitalocean_droplet" "ko" {
  name          = local.names.ko
  image         = "debian-13-x64"
  region        = var.region
  size          = var.size
  ipv6          = true
  monitoring    = false
  droplet_agent = false
  ssh_keys      = [digitalocean_ssh_key.operator.fingerprint]
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_key      = jsonencode(local.ssh_key)
    host_key     = jsonencode(file("${var.deployment}/ssh_host_ed25519_key"))
    host_key_pub = jsonencode(trimspace(file("${var.deployment}/ssh_host_ed25519_key.pub")))
  })
}

resource "digitalocean_firewall" "ko" {
  name        = "ko-${var.ko_label}"
  droplet_ids = [digitalocean_droplet.ko.id]
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_cidrs
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "udp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "cloudflare_dns_record" "ipv4" {
  for_each = local.names
  zone_id  = var.zone_id
  name     = each.value
  type     = "A"
  content  = digitalocean_droplet.ko.ipv4_address
  ttl      = 60
  # Caddy must receive the device's TLS certificate, not a proxy certificate.
  proxied = false
}

resource "cloudflare_dns_record" "ipv6" {
  for_each = local.names
  zone_id  = var.zone_id
  name     = each.value
  type     = "AAAA"
  content  = digitalocean_droplet.ko.ipv6_address
  ttl      = 60
  proxied  = false
}
