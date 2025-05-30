locals {
  cluster_orc_compose_base = yamldecode(file("${path.module}/resources/cluster-orc.docker-compose.yml"))
  cluster_orc_compose_full = merge(
    local.cluster_orc_compose_base,
    {
      services = merge(lookup(local.cluster_orc_compose_base, "services", {}), {
        watchtower = {
          image   = "containrrr/watchtower:1.7.1"
          restart = "always"
          environment = [
            # the local docker registry notifies watchtower when an image was uploaded
            "WATCHTOWER_HTTP_API_UPDATE=true",
            "WATCHTOWER_HTTP_API_TOKEN=${random_password.watchtower.result}",
            # we're only updating oakestra containers, which we explicitly label
            "WATCHTOWER_LABEL_ENABLE=true",
            # no need to keep unused images
            "WATCHTOWER_CLEANUP=true",
            # we're only updating stateless containers, so this should help with removing temporary state
            "WATCHTOWER_REMOVE_VOLUMES=true",
            # when a faulty image is uploaded that keeps crashing its container, this will allow fixing it by uploading again
            "WATCHTOWER_INCLUDE_RESTARTING=true",
            # we block watchtower's head requests on purpose, so errors are expected
            "WATCHTOWER_WARN_ON_HEAD_FAILURE=never"
          ]
          ports = ["${local.watchtower_port}:8080"]
          volumes = [{
            type   = "bind"
            source = "/var/run/docker.sock"
            target = "/var/run/docker.sock"
          }]
          networks = ["watchtower"]
        }
      })
      networks = merge(lookup(local.cluster_orc_compose_base, "networks", {}), {
        default = {
          ipam = {
            config = [
              {
                subnet = var.container_subnet_ipv4_cidr
              }
            ]
          }
        }
        watchtower = {
          ipam = {
            config = [
              {
                subnet   = var.watchtower_subnet_ipv4_cidr
                gateway  = cidrhost(var.watchtower_subnet_ipv4_cidr, 1)
                ip_range = cidrsubnet(var.watchtower_subnet_ipv4_cidr, 2, 2)
              }
            ]
          }
        }
      })
    }
  )
}

resource "libvirt_cloudinit_disk" "cluster_orc" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }

  name = "${each.key}-orc-init.iso"
  pool = libvirt_pool.oakestra_dev.name
  user_data = join("\n", ["#cloud-config", yamlencode({
    apt = {
      sources = {
        docker = {
          source    = "deb https://download.docker.com/linux/ubuntu $RELEASE stable"
          keyserver = "https://download.docker.com/linux/ubuntu/gpg"
          keyid     = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
        }
      }
    }
    package_update = true
    packages = concat(var.additional_packages, [
      "iptables-persistent",
      "docker-ce",
      "docker-ce-cli",
      "containerd.io",
      "docker-compose-plugin"
    ])
    growpart = {
      mode    = "auto"
      devices = ["/"]
    }
    disable_root = false
    users = [
      {
        name                = "root"
        ssh_authorized_keys = [chomp(tls_private_key.ssh_client.public_key_openssh)]
      }
    ]
    ssh_keys = {
      ed25519_private = tls_private_key.ssh_server.private_key_openssh
      ed25519_public  = tls_private_key.ssh_server.public_key_openssh
    }
    write_files = [
      {
        path = "/etc/systemd/system/docker.service.d/override.conf"
        # Having options in /etc/docker/daemon.json, conflicts with passing command line arguments to dockerd,
        # so we override the systemd service to not pass any.
        content     = <<-EOT
          [Service]
          ExecStart=
          ExecStart=/usr/bin/dockerd
        EOT
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path = "/etc/docker/daemon.json"
        content = jsonencode({
          containerd = "/run/containerd/containerd.sock"
          hosts      = ["fd://"]
          "registry-mirrors" = [
            "https://${local.registry_ipv4}:${local.registry_local_port}",
            "https://${local.registry_ipv4}:${local.registry_docker_hub_port}",
            "https://${local.registry_ipv4}:${local.registry_ghcr_io_port}"
          ]
          # Setting up proper certificate validation shouldn't be necessary for this, but here is the docs for it:
          # https://docs.docker.com/engine/security/certificates/
          "insecure-registries" = [
            "${local.registry_ipv4}:${local.registry_local_port}",
            "${local.registry_ipv4}:${local.registry_docker_hub_port}",
            "${local.registry_ipv4}:${local.registry_ghcr_io_port}"
          ]
        })
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/etc/iptables/rules.v4"
        content     = <<-EOT
          *filter
          :DOCKER-USER - [0:0]
          -A DOCKER-USER -s ${cidrsubnet(var.watchtower_subnet_ipv4_cidr, 2, 2)} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
          -A DOCKER-USER -s ${cidrsubnet(var.watchtower_subnet_ipv4_cidr, 2, 2)} -j REJECT
          COMMIT
        EOT
        owner       = "root:root"
        permissions = "0640"
      },
      {
        path        = "/etc/docker-compose/oakestra-cluster-orc/docker-compose.yml",
        content     = yamlencode(local.cluster_orc_compose_full)
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/etc/docker-compose/oakestra-cluster-orc/.env",
        content     = <<-EOT
          OAKESTRA_VERSION="${var.oakestra_version}"
          ROOT_ORC_IPV4="${local.root_orc_ipv4}"
          CLUSTER_NAME="${each.value.name}"
          CLUSTER_LOCATION="${each.value.location}"
        EOT
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/usr/local/lib/systemd/system/oakestra-cluster-orc.service"
        content     = <<-EOT
          [Unit]
          Description=Oakestra Cluster Orchestrator (via Docker Compose)
          After=docker.service
          Requires=docker.service

          [Service]
          Type=simple
          Restart=always
          WorkingDirectory=/etc/docker-compose/oakestra-cluster-orc
          ExecStart=/usr/bin/docker compose up
          ExecStop=/usr/bin/docker compose down

          [Install]
          WantedBy=multi-user.target
        EOT
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/root/.bashrc"
        content     = <<-EOT
          cd /etc/docker-compose/oakestra-cluster-orc
        EOT
        owner       = "root:root"
        permissions = "0644"
      }
    ]
    runcmd = ["systemctl enable --now oakestra-cluster-orc"]
  })])
  network_config = file("${path.module}/resources/ubuntu-network.yml")
}

resource "libvirt_volume" "cluster_orc" {
  for_each       = { for cluster in local.clusters : cluster.name => cluster }
  name           = "${each.key}-orc.iso"
  pool           = libvirt_pool.oakestra_dev.name
  base_volume_id = libvirt_volume.ubuntu_24_04.id
  size           = 16 * 1024 * 1024 * 1024 # 16 GiB

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.cluster_orc]
  }
}

resource "libvirt_domain" "cluster_orc" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }

  name      = "${var.setup_name}-${each.key}-orc"
  memory    = each.value.orc_memory
  vcpu      = each.value.orc_vcpu
  cloudinit = libvirt_cloudinit_disk.cluster_orc[each.key].id

  cpu {
    mode = "host-model"
  }

  disk {
    volume_id = libvirt_volume.cluster_orc[each.key].id
  }

  network_interface {
    network_id = libvirt_network.oakestra_dev.id
    hostname   = each.value.orc_hostname
    addresses  = [each.value.orc_ipv4]
    # Without a static MAC-address, the static IP assignment doesn't work during re-creation,
    # likely because the DHCP lease for the previous MAC is still active.
    mac            = each.value.orc_mac
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.cluster_orc]
  }

  depends_on = [libvirt_domain.registry]
}
