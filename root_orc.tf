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
      "iptables-persistent",
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
          debug      = true,
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
          "registry-mirrors" = [
            "https://${libvirt_domain.registry.network_interface[0].hostname}:${local.registry_local_port}",
            "https://${libvirt_domain.registry.network_interface[0].hostname}:${local.registry_docker_hub_port}",
            "https://${libvirt_domain.registry.network_interface[0].hostname}:${local.registry_ghcr_io_port}"
          ]
          # Setting up proper certificate validation shouldn't be necessary for this, but here is the docs for it:
          # https://docs.docker.com/engine/security/certificates/
          "insecure-registries" = [
            "${libvirt_domain.registry.network_interface[0].hostname}:${local.registry_local_port}",
            "${libvirt_domain.registry.network_interface[0].hostname}:${local.registry_docker_hub_port}",
            "${libvirt_domain.registry.network_interface[0].hostname}:${local.registry_ghcr_io_port}"
          ]
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
        path        = "/etc/iptables/rules.v4"
        content     = <<-EOT
          *filter
          :DOCKER-USER - [0:0]
          -A DOCKER-USER -s 192.168.0.2/32 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
          -A DOCKER-USER -s 192.168.0.2/32 -j DROP
          -A DOCKER-USER -j RETURN
          COMMIT
        EOT
        owner       = "root:root"
        permissions = "0640"
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
}

locals {
  root_orc_docker_host = "tcp://${libvirt_domain.root_orc.network_interface[0].addresses[0]}:2375"
}

# Watchtower tries to check docker.io for updated images when their name does not contain a host part (like ghcr.io).
# We use the registry mirror functionality of docker to locally override images that also exist in remote repositories.
# In order for this to work, we need to stop Watchtower from making the request to docker.io and force it to use its
# secondary mechanism which is a plain Docker image pull (which internally uses our registry mirrors).
# We achieve this via a special docker network and an iptables rule that blocks outbound traffic from its container ip range.
resource "docker_network" "root_watchtower" {
  name = "watchtower"

  ipam_config {
    subnet   = "192.168.0.0/30"
    gateway  = "192.168.0.1"
    ip_range = "192.168.0.2/32"
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }
}

resource "docker_network" "root_orc" {
  name = "root-orc"

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }
}

resource "docker_image" "root_watchtower" {
  name = "containrrr/watchtower:1.7.1"

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_image" "root_mongo" {
  name = "mongo:3.6"

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_image" "root_redis" {
  name = "redis:7.4.2"

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_container" "root_watchtower" {
  image   = docker_image.root_watchtower.image_id
  name    = "watchtower"
  restart = "always"
  env = [
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

  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }

  networks_advanced {
    name = docker_network.root_watchtower.id
  }

  ports {
    internal = 8080
    external = local.watchtower_port
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "root_system_manager" {
  image   = "oakestra/oakestra/root-system-manager:${var.oakestra_version}"
  name    = "root-system-manager"
  restart = "always"
  env = [
    "CLOUD_MONGO_URL=root-mongo",
    "CLOUD_MONGO_PORT=10007",
    "CLOUD_SCHEDULER_URL=cloud-scheduler",
    "CLOUD_SCHEDULER_PORT=10004",
    "RESOURCE_ABSTRACTOR_URL=root-resource-abstractor",
    "RESOURCE_ABSTRACTOR_PORT=11011",
    "NET_PLUGIN_URL=root-service-manager",
    "NET_PLUGIN_PORT=10099"
  ]

  labels {
    label = "com.centurylinklabs.watchtower.enable"
    value = "true"
  }

  networks_advanced {
    name = docker_network.root_orc.id
  }

  ports {
    internal = 10000
    external = 10000
  }

  ports {
    internal = 50052
    external = 50052
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes       = [network_mode, image]
    replace_triggered_by = [null_resource.oakestra_version]
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_container" "root_resource_abstractor" {
  image   = "oakestra/oakestra/root-resource-abstractor:${var.oakestra_version}"
  name    = "root-resource-abstractor"
  restart = "always"
  env = [
    "RESOURCE_ABSTRACTOR_PORT=11011",
    "CLOUD_MONGO_URL=root-mongo",
    "CLOUD_MONGO_PORT=10007"
  ]

  labels {
    label = "com.centurylinklabs.watchtower.enable"
    value = "true"
  }

  networks_advanced {
    name = docker_network.root_orc.id
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes       = [network_mode, image]
    replace_triggered_by = [null_resource.oakestra_version]
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_container" "root_cloud_scheduler" {
  image   = "oakestra/oakestra/cloud-scheduler:${var.oakestra_version}"
  name    = "cloud-scheduler"
  restart = "always"
  env = [
    "MY_PORT=10004",
    "SYSTEM_MANAGER_URL=root-system-manager",
    "SYSTEM_MANAGER_PORT=10000",
    "RESOURCE_ABSTRACTOR_URL=root-resource-abstractor",
    "RESOURCE_ABSTRACTOR_PORT=11011",
    "REDIS_ADDR=redis://:cloudRedis@root-redis:6379",
    "CLOUD_MONGO_URL=root-mongo",
    "CLOUD_MONGO_PORT=10007"
  ]

  labels {
    label = "com.centurylinklabs.watchtower.enable"
    value = "true"
  }

  networks_advanced {
    name = docker_network.root_orc.id
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes       = [network_mode, image]
    replace_triggered_by = [null_resource.oakestra_version]
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_container" "root_service_manager" {
  image   = "oakestra/oakestra-net/root-service-manager:${var.oakestra_version}"
  name    = "root-service-manager"
  restart = "always"
  env = [
    "MY_PORT=10099",
    "SYSTEM_MANAGER_URL=root-system-manager",
    "SYSTEM_MANAGER_PORT=10000",
    "CLOUD_MONGO_URL=root-mongo-net",
    "CLOUD_MONGO_PORT=10008"
  ]

  labels {
    label = "com.centurylinklabs.watchtower.enable"
    value = "true"
  }

  networks_advanced {
    name = docker_network.root_orc.id
  }

  ports {
    internal = 10099
    external = 10099
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes       = [network_mode, image]
    replace_triggered_by = [null_resource.oakestra_version]
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_container" "dashboard" {
  image   = "oakestra/dashboard:${var.oakestra_dashboard_version}"
  name    = "dashboard"
  restart = "always"
  env = [
    "API_ADDRESS=${libvirt_domain.root_orc.network_interface[0].addresses[0]}:10000",
  ]

  labels {
    label = "com.centurylinklabs.watchtower.enable"
    value = "true"
  }

  networks_advanced {
    name = docker_network.root_orc.id
  }

  ports {
    internal = 80
    external = 80
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes       = [network_mode, image]
    replace_triggered_by = [null_resource.oakestra_dashboard_version]
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_container" "root_mongo" {
  image   = docker_image.root_mongo.image_id
  name    = "root-mongo"
  restart = "always"
  command = ["mongod", "--port", "10007"]

  networks_advanced {
    name = docker_network.root_orc.id
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "root_mongo_net" {
  image   = docker_image.root_mongo.image_id
  name    = "root-mongo-net"
  restart = "always"
  command = ["mongod", "--port", "10008"]

  networks_advanced {
    name = docker_network.root_orc.id
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "root_redis" {
  image   = docker_image.root_redis.image_id
  name    = "root-redis"
  restart = "always"
  command = ["redis-server", "--requirepass", "cloudRedis"]

  networks_advanced {
    name = docker_network.root_orc.id
  }

  override {
    host          = local.root_orc_docker_host
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

# TODO: cleanup containers that were updated by watchtower
# resource "null_resource" "root_watchtower_cleanup" {
#   triggers = {
#     container_ids = [
#       docker_container.root_system_manager.id,
#       docker_container.root_resource_abstractor.id,
#       docker_container.root_cloud_scheduler.id,
#       docker_container.root_service_manager.id,
#       docker_container.dashboard.id
#     ]
#   }
#
#   connection {
#     type        = "ssh"
#     host        = libvirt_domain.registry.network_interface[0].addresses[0]
#     user        = "root"
#     private_key = tls_private_key.ssh_client.private_key_openssh
#   }
#
#   provisioner "remote-exec" {
#     when    = destroy
#     inline  = [
#       "watchtower-cleanup.sh '${join("' '", self.triggers.container_ids)}'"
#     ]
#   }
# }
