terraform {
  required_version = ">=1.8.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">=3.2.3"
    }

    random = {
      source  = "hashicorp/random"
      version = ">=3.6.3"
    }

    tls = {
      source  = "hashicorp/tls"
      version = ">=4.0.6"
    }

    http = {
      source  = "hashicorp/http"
      version = ">=3.4.5"
    }

    local = {
      source  = "hashicorp/local"
      version = ">=2.5.2"
    }

    libvirt = {
      source  = "dmacvicar/libvirt"
      version = ">=0.8.1"
    }

    docker = {
      source  = "bierwirth-it/docker"
      version = ">=3.0.5"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

provider "docker" {
  host = "unix:///var/run/docker.sock"
}
