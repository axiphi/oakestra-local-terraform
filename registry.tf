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
          hosts = [
            "tcp://0.0.0.0:2375",
            "fd://"
          ]
          tls       = true
          tlsverify = true
          tlscert   = "/etc/docker/cert.pem"
          tlskey    = "/etc/docker/key.pem"
          tlscacert = "/etc/docker/ca.pem"
        })
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/etc/docker/cert.pem"
        content     = tls_self_signed_cert.docker_server.cert_pem
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/etc/docker/key.pem"
        content     = tls_self_signed_cert.docker_server.private_key_pem
        owner       = "root:root"
        permissions = "0600"
      },
      {
        path        = "/etc/docker/ca.pem"
        content     = tls_self_signed_cert.docker_client.cert_pem
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/etc/docker/certs.d/localhost:${local.registry_local_port}/ca.crt"
        content     = tls_self_signed_cert.docker_server.cert_pem
        owner       = "root:root"
        permissions = "0644"
      },
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
      }
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
      "cloud-init status --wait > /dev/null",
      "echo 'Done with waiting for cloud-init.'",
    ]
  }

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.registry]
  }
}

locals {
  registry_docker_host = "tcp://${libvirt_domain.registry.network_interface[0].addresses[0]}:2375"
}

resource "docker_network" "registry" {
  name = "registry"

  override {
    host          = local.registry_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }
}

resource "docker_image" "registry" {
  name = "registry:2.8.3"

  override {
    host          = local.registry_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }
}

resource "docker_container" "registry_local" {
  name  = "registry-local"
  image = docker_image.registry.image_id

  networks_advanced {
    name = docker_network.registry.id
  }

  upload {
    file = "/etc/docker/registry/config.yml"
    # Most of the content is copied from the defaults of the image.
    # Modified/added values are marked.
    content = yamlencode({
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
      # Added: notifications (web-hooks)
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
    })
  }

  upload {
    file    = "/etc/docker/registry/cert.pem"
    content = tls_self_signed_cert.docker_server.cert_pem
  }

  upload {
    file    = "/etc/docker/registry/key.pem"
    content = tls_self_signed_cert.docker_server.private_key_pem
  }

  ports {
    internal = 5000
    external = local.registry_local_port
  }

  override {
    host          = local.registry_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  connection {
    type        = "ssh"
    host        = libvirt_domain.registry.network_interface[0].addresses[0]
    user        = "root"
    private_key = tls_private_key.ssh_client.private_key_openssh
  }

  provisioner "remote-exec" {
    inline = [
      "wait-for-it.sh localhost:${self.ports[0].external}"
    ]
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "registry_docker_hub" {
  name  = "registry-docker-hub"
  image = docker_image.registry.image_id

  networks_advanced {
    name = docker_network.registry.id
  }

  upload {
    file = "/etc/docker/registry/config.yml"
    # Most of the content is copied from the defaults of the image.
    # Modified/added values are marked.
    content = yamlencode({
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
      # Added: Configure read-through proxy.
      proxy = {
        remoteurl = "https://registry-1.docker.io"
      }
    })
  }

  upload {
    file    = "/etc/docker/registry/cert.pem"
    content = tls_self_signed_cert.docker_server.cert_pem
  }

  upload {
    file    = "/etc/docker/registry/key.pem"
    content = tls_self_signed_cert.docker_server.private_key_pem
  }

  ports {
    internal = 5000
    external = local.registry_docker_hub_port
  }

  override {
    host          = local.registry_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  connection {
    type        = "ssh"
    host        = libvirt_domain.registry.network_interface[0].addresses[0]
    user        = "root"
    private_key = tls_private_key.ssh_client.private_key_openssh
  }

  provisioner "remote-exec" {
    inline = [
      "wait-for-it.sh localhost:${self.ports[0].external}"
    ]
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "registry_ghcr_io" {
  name  = "registry-ghcr-io"
  image = docker_image.registry.image_id

  networks_advanced {
    name = docker_network.registry.id
  }

  upload {
    file = "/etc/docker/registry/config.yml"
    # Most of the content is copied from the defaults of the image.
    # Modified/added values are marked.
    content = yamlencode({
      version = 0.1
      log = {
        fields = {
          service = "registry"
        }
        level = "debug"
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
      # Added: Configure read-through proxy.
      proxy = {
        remoteurl = "https://ghcr.io"
      }
    })
  }

  upload {
    file    = "/etc/docker/registry/cert.pem"
    content = tls_self_signed_cert.docker_server.cert_pem
  }

  upload {
    file    = "/etc/docker/registry/key.pem"
    content = tls_self_signed_cert.docker_server.private_key_pem
  }

  ports {
    internal = 5000
    external = local.registry_ghcr_io_port
  }

  override {
    host          = local.registry_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  connection {
    type        = "ssh"
    host        = libvirt_domain.registry.network_interface[0].addresses[0]
    user        = "root"
    private_key = tls_private_key.ssh_client.private_key_openssh
  }

  provisioner "remote-exec" {
    inline = [
      "wait-for-it.sh localhost:${self.ports[0].external}"
    ]
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}
