locals {
  # Most of this is copied from the defaults of the registry image.
  # Modified/added values are marked.
  shared_registry_config = {
    version = 0.1
    log = {
      fields = {
        service = "registry"
      }
    }
    storage = {
      cache = {
        blobdescriptor = "inmemory"
      }
      filesystem = {
        rootdirectory = "/var/lib/registry"
      }
    }
    health = {
      storagedriver = {
        enabled   = true
        interval  = "10s"
        threshold = 3
      }
    }
    http = {
      addr = ":5000"
      headers = {
        "X-Content-Type-Options" = ["nosniff"]
      }
      # Added: Configure TLS.
      tls = {
        certificate = "/etc/docker/registry/cert.pem"
        key         = "/etc/docker/registry/key.pem"
      }
    }
  }
}

resource "libvirt_volume" "registry" {
  name           = "registry.iso"
  pool           = libvirt_pool.oakestra_dev.name
  base_volume_id = libvirt_volume.ubuntu_24_04.id
  size           = 32 * 1024 * 1024 * 1024 # 32 GiB

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.registry]
  }
}

resource "libvirt_cloudinit_disk" "registry" {
  name = "registry-init.iso"
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
        path        = "/usr/local/bin/wait-for-it.sh",
        content     = file("${path.module}/resources/wait-for-it.sh")
        owner       = "root:root"
        permissions = "0755"
      },
      {
        path        = "/usr/local/bin/normalize-image.sh",
        content     = file("${path.module}/resources/normalize-image.sh")
        owner       = "root:root"
        permissions = "0755"
      },
      {
        path        = "/usr/local/bin/restore-image.sh",
        content     = <<-EOT
          #!/usr/bin/env sh

          normalized_image="$(normalize-image.sh $1)"
          retagged_image="localhost:${local.registry_local_port}/$${normalized_image}:${var.oakestra_version}"

          docker load
          docker tag "$1" "$${retagged_image}"
          docker push "$${retagged_image}"

          docker rmi "$1"
          docker rmi "$${retagged_image}"
        EOT
        owner       = "root:root"
        permissions = "0755"
      },
      {
        path = "/etc/docker-compose/oakestra-registries/docker-compose.yml",
        content = yamlencode({
          services = {
            "registry-local" = {
              image = "registry:2.8.3"
              ports = ["${local.registry_local_port}:5000"]
              configs = [
                {
                  source = "registry-config-local"
                  target = "/etc/docker/registry/config.yml"
                },
                {
                  source = "registry-cert"
                  target = "/etc/docker/registry/cert.pem"
                },
                {
                  source = "registry-key"
                  target = "/etc/docker/registry/key.pem"
                }
              ]
            }
            "registry-docker-hub" = {
              image = "registry:2.8.3"
              ports = ["${local.registry_docker_hub_port}:5000"]
              configs = [
                {
                  source = "registry-config-docker-hub"
                  target = "/etc/docker/registry/config.yml"
                },
                {
                  source = "registry-cert"
                  target = "/etc/docker/registry/cert.pem"
                },
                {
                  source = "registry-key"
                  target = "/etc/docker/registry/key.pem"
                }
              ]
            }
            "registry-ghcr-io" = {
              image = "registry:2.8.3"
              ports = ["${local.registry_ghcr_io_port}:5000"]
              configs = [
                {
                  source = "registry-config-ghcr-io"
                  target = "/etc/docker/registry/config.yml"
                },
                {
                  source = "registry-cert"
                  target = "/etc/docker/registry/cert.pem"
                },
                {
                  source = "registry-key"
                  target = "/etc/docker/registry/key.pem"
                }
              ]
            }
          }
          configs = {
            "registry-config-local" = {
              content = yamlencode(merge(local.shared_registry_config, {
                notifications = {
                  endpoints = concat(
                    [{
                      name = "watchtower-root-orc"
                      url  = "http://${local.root_orc_hostname}:${local.watchtower_port}/v1/update"
                      headers = {
                        "Authorization" = ["Bearer ${random_password.watchtower.result}"]
                      }
                      timeout   = "30s"
                      threshold = 3
                      backoff   = "30s"
                      ignore = {
                        actions    = ["pull"]
                        mediatypes = ["application/octet-stream"]
                      }
                    }],
                    [for cluster in local.clusters : {
                      name = "watchtower-${cluster.name}"
                      url  = "http://${cluster.hostname}:${local.watchtower_port}/v1/update"
                      headers = {
                        "Authorization" = ["Bearer ${random_password.watchtower.result}"]
                      }
                      timeout   = "30s"
                      threshold = 3
                      backoff   = "30s"
                      ignore = {
                        actions    = ["pull"]
                        mediatypes = ["application/octet-stream"]
                      }
                    }]
                  )
                }
              }))
            }
            "registry-config-docker-hub" = {
              content = yamlencode(merge(local.shared_registry_config, {
                proxy = {
                  remoteurl = "https://registry-1.docker.io"
                }
              }))
            }
            "registry-config-ghcr-io" = {
              content = yamlencode(merge(local.shared_registry_config, {
                proxy = {
                  remoteurl = "https://ghcr.io"
                }
              }))
            }
            "registry-cert" = {
              content = tls_self_signed_cert.docker_server.cert_pem
            }
            "registry-key" = {
              content = tls_self_signed_cert.docker_server.private_key_pem
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
          }
        })
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/usr/local/lib/systemd/system/oakestra-registries.service"
        content     = <<-EOT
          [Unit]
          Description=Oakestra Development Container Registries (via Docker Compose)
          After=docker.service
          Requires=docker.service

          [Service]
          Type=simple
          Restart=always
          WorkingDirectory=/etc/docker-compose/oakestra-registries
          ExecStart=/usr/bin/docker compose up
          ExecStop=/usr/bin/docker compose down

          [Install]
          WantedBy=multi-user.target
        EOT
        owner       = "root:root"
        permissions = "0644"
      },
    ]
    runcmd = ["systemctl enable --now oakestra-registries"]
  })])
  network_config = file("${path.module}/resources/ubuntu-network.yml")
}

resource "libvirt_domain" "registry" {
  name      = "${local.setup_name}-registry"
  memory    = 4096
  vcpu      = 2
  cloudinit = libvirt_cloudinit_disk.registry.id

  disk {
    volume_id = libvirt_volume.registry.id
  }

  network_interface {
    network_id = libvirt_network.oakestra_dev.id
    hostname   = local.registry_hostname
    addresses  = [local.registry_ipv4]
    # Without a static MAC-address, the static IP assignment doesn't work during re-creation,
    # likely because the DHCP lease for the previous MAC is still active.
    mac            = local.registry_mac
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
      "cloud-init status --wait > /dev/null || exit 1",
      "echo 'Done with waiting for cloud-init.'",
      "echo 'Waiting for registries to come up...'",
      "wait-for-it.sh -q -t 60 localhost:${local.registry_local_port} || exit 1",
      "wait-for-it.sh -q -t 60 localhost:${local.registry_docker_hub_port} || exit 1",
      "wait-for-it.sh -q -t 60 localhost:${local.registry_ghcr_io_port} || exit 1",
      "echo 'Done with waiting for registries.'",
    ]
  }

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.registry]
  }
}
