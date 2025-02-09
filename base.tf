data "external" "xdg_data_home" {
  program = ["sh", "${path.module}/resources/json-wrap.sh", "--ignore-error", "printenv", "XDG_DATA_HOME"]
}

data "external" "uid" {
  program = ["sh", "${path.module}/resources/json-wrap.sh", "id", "-u"]
}

locals {
  setup_name = coalesce(var.setup_name, substr("oaks-${data.external.uid.result.value}", 0, 16))

  base_data_dir     = trimsuffix(pathexpand(coalesce(data.external.xdg_data_home.result.value, "~/.local/share")), "/")
  oakestra_data_dir = "${local.base_data_dir}/oakestra-dev/${local.setup_name}"
  oakestra_pool_dir = "${trimsuffix(pathexpand(var.pool_base_path), "/")}/${local.setup_name}"

  oakestra_domain = "${local.setup_name}.local"

  network_ipv4_cidr = "10.44.0.0/16"
  host_ipv4         = "10.44.0.1"

  registry_hostname        = "registry.${local.oakestra_domain}"
  registry_ipv4            = "10.44.1.2"
  registry_mac             = "52:54:00:22:01:00"
  registry_local_port      = 10500
  registry_docker_hub_port = 10501
  registry_ghcr_io_port    = 10502

  root_orc_hostname = "root-orc.${local.oakestra_domain}"
  root_orc_ipv4     = "10.44.2.2"
  root_orc_mac      = "52:54:00:22:02:00"

  clusters = [for cluster_idx, cluster in var.clusters : {
    index    = cluster_idx
    name     = "cluster-orc-${cluster_idx + 1}"
    hostname = "cluster-orc-${cluster_idx + 1}.${local.oakestra_domain}"
    ipv4     = "10.44.${cluster_idx + 3}.2"
    mac      = format("52:54:00:22:%02X:00", cluster_idx + 3)
    memory   = cluster.memory
    vcpu     = cluster.vcpu
    location = cluster.location
    workers = [for worker_idx, worker in cluster.workers : {
      index         = worker_idx
      name          = "worker-${cluster_idx + 1}-${worker_idx + 1}"
      hostname      = "worker-${cluster_idx + 1}-${worker_idx + 1}.${local.oakestra_domain}"
      ipv4          = "10.44.${cluster_idx + 3}.${worker_idx + 3}"
      mac           = format("52:54:00:22:%02X:%02X", cluster_idx + 3, worker_idx + 1)
      memory        = worker.memory
      vcpu          = worker.vcpu
      cluster_index = cluster_idx
      cluster_name  = "cluster-orc-${cluster_idx + 1}"
    }]
  }]
  # flattened version of local.clusters, to make for_each resources easier
  workers = flatten([for cluster in local.clusters : cluster.workers])

  libvirt_network_interface = "virbr-${local.setup_name}"

  watchtower_port = 8080
}

resource "null_resource" "oakestra_version" {
  triggers = {
    subnet = var.oakestra_version
  }
}

resource "null_resource" "oakestra_dashboard_version" {
  triggers = {
    subnet = var.oakestra_dashboard_version
  }
}

resource "tls_private_key" "ssh_client" {
  algorithm = "ED25519"
}

resource "tls_private_key" "ssh_server" {
  algorithm = "ED25519"
}

resource "tls_private_key" "docker_server" {
  algorithm = "ED25519"
}

resource "tls_self_signed_cert" "docker_server" {
  private_key_pem = tls_private_key.docker_server.private_key_pem
  dns_names       = ["*.${local.oakestra_domain}"]
  ip_addresses = concat(
    [
      local.registry_ipv4,
      local.root_orc_ipv4
    ],
    [for cluster in local.clusters : cluster.ipv4]
  )
  validity_period_hours = 24 * 365 * 10 # 10 years
  allowed_uses = [
    "digital_signature",
    "server_auth"
  ]

  subject {
    common_name  = "*.${local.oakestra_domain}"
    organization = "Docker Server (${local.setup_name})"
  }
}

resource "tls_private_key" "docker_client" {
  algorithm = "ED25519"
}

resource "tls_self_signed_cert" "docker_client" {
  private_key_pem       = tls_private_key.docker_client.private_key_pem
  dns_names             = ["*.${local.oakestra_domain}"]
  ip_addresses          = [local.host_ipv4]
  validity_period_hours = 24 * 365 * 10 # 10 years
  allowed_uses = [
    "digital_signature",
    "client_auth"
  ]

  subject {
    common_name  = "*.${local.oakestra_domain}"
    organization = "Docker Client (${local.setup_name})"
  }
}

resource "random_password" "watchtower" {
  length  = 20
  special = false
}

resource "libvirt_network" "oakestra_dev" {
  name      = local.setup_name
  mode      = "nat"
  domain    = local.oakestra_domain
  addresses = [local.network_ipv4_cidr]
  bridge    = local.libvirt_network_interface

  dns {
    local_only = true
  }

  dhcp {
    enabled = true
  }
}

resource "libvirt_pool" "oakestra_dev" {
  name = local.setup_name
  type = "dir"

  target {
    path = local.oakestra_pool_dir
  }
}

resource "libvirt_volume" "ubuntu_24_04" {
  name = "ubuntu-24-04.iso"
  pool = libvirt_pool.oakestra_dev.name
  source = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
  format = "qcow2"
}
