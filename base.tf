data "external" "xdg_data_home" {
  program = ["sh", "${path.module}/resources/json-wrap.sh", "--ignore-error", "printenv", "XDG_DATA_HOME"]
}

data "external" "uid" {
  program = ["sh", "${path.module}/resources/json-wrap.sh", "id", "-u"]
}

locals {
  base_data_dir     = trimsuffix(pathexpand(coalesce(data.external.xdg_data_home.result.value, "~/.local/share")), "/")
  oakestra_data_dir = "${local.base_data_dir}/oakestra-dev/${var.setup_name}"
  oakestra_pool_dir = "${trimsuffix(pathexpand(var.pool_base_path), "/")}/${var.setup_name}"

  oakestra_domain = "${var.setup_name}.local"

  host_ipv4 = cidrhost(var.node_subnet_ipv4_cidr, 1)

  registry_subnet_ipv4_cidr = cidrsubnet(var.node_subnet_ipv4_cidr, 4, 0)
  registry_hostname         = "registry.${local.oakestra_domain}"
  registry_ipv4             = cidrhost(local.registry_subnet_ipv4_cidr, 2)
  registry_mac              = "52:54:00:22:01:00"
  registry_local_port       = 10500
  registry_docker_hub_port  = 10501
  registry_ghcr_io_port     = 10502

  root_subnet_ipv4_cidr = cidrsubnet(var.node_subnet_ipv4_cidr, 4, 1)
  root_orc_hostname     = "root-orc.${local.oakestra_domain}"
  root_orc_ipv4         = cidrhost(local.root_subnet_ipv4_cidr, 2)
  root_orc_mac          = "52:54:00:22:02:00"

  cluster_subnet_ipv4_cidrs = [for cluster_idx in range(length(var.clusters)) : cidrsubnet(var.node_subnet_ipv4_cidr, 4, 2 + cluster_idx)]
  clusters = [for cluster_idx, cluster in var.clusters : {
    index            = cluster_idx
    name             = "cluster-${cluster_idx + 1}"
    location         = cluster.location
    subnet_ipv4_cidr = local.cluster_subnet_ipv4_cidrs[cluster_idx]
    orc_hostname     = "cluster-${cluster_idx + 1}-orc.${local.oakestra_domain}"
    orc_ipv4         = cidrhost(local.cluster_subnet_ipv4_cidrs[cluster_idx], 2)
    orc_mac          = format("52:54:00:22:%02X:00", cluster_idx + 3)
    orc_memory       = cluster.memory
    orc_vcpu         = cluster.vcpu
    workers = [for worker_idx, worker in cluster.workers : {
      index         = worker_idx
      name          = "worker-${cluster_idx + 1}-${worker_idx + 1}"
      hostname      = "worker-${cluster_idx + 1}-${worker_idx + 1}.${local.oakestra_domain}"
      ipv4          = cidrhost(local.cluster_subnet_ipv4_cidrs[cluster_idx], 3 + worker_idx)
      mac           = format("52:54:00:22:%02X:%02X", cluster_idx + 3, worker_idx + 1)
      memory        = worker.memory
      vcpu          = worker.vcpu
      cluster_index = cluster_idx
      cluster_name  = "cluster-${cluster_idx + 1}"
    }]
  }]
  # flattened version of local.clusters, to make for_each resources easier
  workers = flatten([for cluster in local.clusters : cluster.workers])

  libvirt_network_interface = "virbr-${var.setup_name}"

  watchtower_port = 8080
}

resource "tls_private_key" "ssh_client" {
  algorithm = "ED25519"
}

resource "tls_private_key" "ssh_server" {
  algorithm = "ED25519"
}

resource "tls_private_key" "registry" {
  algorithm = "ED25519"
}

resource "tls_self_signed_cert" "registry" {
  private_key_pem       = tls_private_key.registry.private_key_pem
  ip_addresses          = [local.registry_ipv4]
  validity_period_hours = 24 * 365 * 10 # 10 years
  allowed_uses = [
    "digital_signature",
    "server_auth"
  ]

  subject {
    common_name  = local.registry_ipv4
    organization = "Oakestra Container Registry (${var.setup_name})"
  }
}

resource "random_password" "watchtower" {
  length  = 20
  special = false
}

resource "libvirt_network" "oakestra_dev" {
  name      = var.setup_name
  mode      = "nat"
  domain    = local.oakestra_domain
  addresses = [var.node_subnet_ipv4_cidr]
  bridge    = local.libvirt_network_interface

  dns {
    local_only = true
  }

  dhcp {
    enabled = true
  }
}

resource "libvirt_pool" "oakestra_dev" {
  name = var.setup_name
  type = "dir"

  target {
    path = local.oakestra_pool_dir
  }
}

resource "libvirt_volume" "ubuntu_24_04" {
  name   = "ubuntu-24-04.iso"
  pool   = libvirt_pool.oakestra_dev.name
  source = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
  format = "qcow2"
}
