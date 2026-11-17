terraform {
  required_version = ">= 1.8.0"
  backend "local" {}
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.75.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.19.0"
    }
  }
}

provider "digitalocean" {}
provider "cloudflare" {}
