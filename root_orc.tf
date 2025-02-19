resource "libvirt_volume" "root_orc" {
  name           = "root-orc.iso"
  pool           = libvirt_pool.oakestra_dev.name
  base_volume_id = libvirt_volume.ubuntu_24_04.id
  size           = 16 * 1024 * 1024 * 1024 # 16 GiB

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.root_orc]
  }
}

resource "libvirt_cloudinit_disk" "root_orc" {
  name = "root-orc-init.iso"
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
    packages = [
      "docker-ce",
      "docker-ce-cli",
      "containerd.io",
      "iptables-persistent",
      "kitty-terminfo"
    ]
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
            "https://${local.registry_hostname}:${local.registry_local_port}",
            "https://${local.registry_hostname}:${local.registry_docker_hub_port}",
            "https://${local.registry_hostname}:${local.registry_ghcr_io_port}"
          ]
          # Setting up proper certificate validation shouldn't be necessary for this, but here is the docs for it:
          # https://docs.docker.com/engine/security/certificates/
          "insecure-registries" = [
            "${local.registry_hostname}:${local.registry_local_port}",
            "${local.registry_hostname}:${local.registry_docker_hub_port}",
            "${local.registry_hostname}:${local.registry_ghcr_io_port}"
          ]
        })
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path = "/etc/iptables/rules.v4"
        # Watchtower tries to check docker.io for updated images when their name does not contain a host part (like ghcr.io).
        # We use the registry mirror functionality of docker to locally override images that also exist in remote repositories.
        # In order for this to work, we need to stop Watchtower from making the request to docker.io and force it to use its
        # secondary mechanism which is a plain Docker image pull (which internally uses our registry mirrors).
        # We achieve this via a special docker network and an iptables rule that blocks outbound traffic from its container ip range.
        content     = <<-EOT
          *filter
          :DOCKER-USER - [0:0]
          -A DOCKER-USER -s ${cidrsubnet(var.watchtower_ipv4_cidr, 2, 2)} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
          -A DOCKER-USER -s ${cidrsubnet(var.watchtower_ipv4_cidr, 2, 2)} -j DROP
          -A DOCKER-USER -j RETURN
          COMMIT
        EOT
        owner       = "root:root"
        permissions = "0640"
      },
      {
        path = "/etc/docker-compose/oakestra-root-orc/docker-compose.yml",
        content = yamlencode({
          services = {
            "watchtower" = {
              image   = "containrrr/watchtower:1.7.1"
              restart = "always"
              ports   = ["${local.watchtower_port}:8080"]
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
              volumes = [{
                type   = "bind"
                source = "/var/run/docker.sock"
                target = "/var/run/docker.sock"
              }]
              networks = ["watchtower"]
            }
            "root-system-manager" = {
              image   = "oakestra/oakestra/root-system-manager:${var.oakestra_version}"
              restart = "always"
              ports = [
                "10000:10000",
                "50052:50052"
              ]
              environment = [
                "CLOUD_MONGO_URL=root-mongo",
                "CLOUD_MONGO_PORT=10007",
                "CLOUD_SCHEDULER_URL=cloud-scheduler",
                "CLOUD_SCHEDULER_PORT=10004",
                "RESOURCE_ABSTRACTOR_URL=root-resource-abstractor",
                "RESOURCE_ABSTRACTOR_PORT=11011",
                "NET_PLUGIN_URL=root-service-manager",
                "NET_PLUGIN_PORT=10099"
              ]
              labels = {
                "com.centurylinklabs.watchtower.enable" = "true"
              }
            }
            "root-resource-abstractor" = {
              image   = "oakestra/oakestra/root-resource-abstractor:${var.oakestra_version}"
              restart = "always"
              ports   = var.debug_ports_enabled ? ["11011:11011"] : []
              environment = [
                "RESOURCE_ABSTRACTOR_PORT=11011",
                "CLOUD_MONGO_URL=root-mongo",
                "CLOUD_MONGO_PORT=10007"
              ]
              labels = {
                "com.centurylinklabs.watchtower.enable" = "true"
              }
            }
            "cloud-scheduler" = {
              image   = "oakestra/oakestra/cloud-scheduler:${var.oakestra_version}"
              restart = "always"
              ports   = var.debug_ports_enabled ? ["10004:10004"] : []
              environment = [
                "MY_PORT=10004",
                "SYSTEM_MANAGER_URL=root-system-manager",
                "SYSTEM_MANAGER_PORT=10000",
                "RESOURCE_ABSTRACTOR_URL=root-resource-abstractor",
                "RESOURCE_ABSTRACTOR_PORT=11011",
                "REDIS_ADDR=redis://:cloudRedis@root-redis:6379",
                "CLOUD_MONGO_URL=root-mongo",
                "CLOUD_MONGO_PORT=10007"
              ]
              labels = {
                "com.centurylinklabs.watchtower.enable" = "true"
              }
            }
            "root-service-manager" = {
              image   = "oakestra/oakestra-net/root-service-manager:${var.oakestra_version}"
              restart = "always"
              ports   = ["10099:10099"]
              environment = [
                "MY_PORT=10099",
                "SYSTEM_MANAGER_URL=root-system-manager",
                "SYSTEM_MANAGER_PORT=10000",
                "CLOUD_MONGO_URL=root-mongo-net",
                "CLOUD_MONGO_PORT=10008"
              ]
              labels = {
                "com.centurylinklabs.watchtower.enable" = "true"
              }
            }
            "dashboard" = {
              image   = "oakestra/dashboard:${var.oakestra_dashboard_version}"
              restart = "always"
              ports   = ["80:80"]
              environment = [
                "API_ADDRESS=${local.root_orc_ipv4}:10000",
              ]
              labels = {
                "com.centurylinklabs.watchtower.enable" = "true"
              }
            }
            "root-mongo" = {
              image   = "mongo:3.6"
              restart = "always"
              command = ["mongod", "--port", "10007"]
              ports   = var.debug_ports_enabled ? ["10007:10007"] : []
            }
            "root-mongo-net" = {
              image   = "mongo:3.6"
              restart = "always"
              command = ["mongod", "--port", "10008"]
              ports   = var.debug_ports_enabled ? ["10008:10008"] : []
            }
            "root-redis" = {
              image   = "redis:7.4.2"
              restart = "always"
              command = ["redis-server", "--requirepass", "cloudRedis"]
              ports   = var.debug_ports_enabled ? ["6379:6379"] : []
            }
          }
          networks = {
            default = {
              ipam = {
                config = [
                  {
                    subnet = var.container_ipv4_cidr
                  }
                ]
              }
            }
            watchtower = {
              ipam = {
                config = [
                  {
                    subnet   = var.watchtower_ipv4_cidr
                    gateway  = cidrhost(var.watchtower_ipv4_cidr, 1)
                    ip_range = cidrsubnet(var.watchtower_ipv4_cidr, 2, 2)
                  }
                ]
              }
            }
          }
        })
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/usr/local/lib/systemd/system/oakestra-root-orc.service"
        content     = <<-EOT
          [Unit]
          Description=Oakestra Root Orchestrator (via Docker Compose)
          After=docker.service
          Requires=docker.service

          [Service]
          Type=simple
          Restart=always
          WorkingDirectory=/etc/docker-compose/oakestra-root-orc
          ExecStart=/usr/bin/docker compose up
          ExecStop=/usr/bin/docker compose down

          [Install]
          WantedBy=multi-user.target
        EOT
        owner       = "root:root"
        permissions = "0644"
      }
    ]
    runcmd = ["systemctl enable --now oakestra-root-orc"]
  })])
  network_config = file("${path.module}/resources/ubuntu-network.yml")
}

resource "libvirt_domain" "root_orc" {
  name      = "${local.setup_name}-root-orc"
  memory    = 4096
  vcpu      = 2
  cloudinit = libvirt_cloudinit_disk.root_orc.id

  disk {
    volume_id = libvirt_volume.root_orc.id
  }

  network_interface {
    network_id = libvirt_network.oakestra_dev.id
    hostname   = local.root_orc_hostname
    addresses  = [local.root_orc_ipv4]
    # Without a static MAC-address, the static IP assignment doesn't work during re-creation,
    # likely because the DHCP lease for the previous MAC is still active.
    mac            = local.root_orc_mac
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  connection {
    type        = "ssh"
    host        = self.network_interface[0].addresses[0]
    user        = "root"
    private_key = tls_private_key.ssh_client.private_key_openssh
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to finish...'",
      "cloud-init status --wait > /dev/null",
      "echo 'Done with waiting for cloud-init.'",
    ]
  }

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.root_orc]
  }

  depends_on = [libvirt_domain.registry]
}
