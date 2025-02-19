resource "libvirt_cloudinit_disk" "cluster_orc" {
  name = "cluster-orc-init.iso"
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

resource "libvirt_volume" "cluster_orc" {
  for_each       = { for cluster in local.clusters : cluster.name => cluster }
  name           = "${each.value.name}.iso"
  pool           = libvirt_pool.oakestra_dev.name
  base_volume_id = libvirt_volume.ubuntu_24_04.id
  size           = 16 * 1024 * 1024 * 1024 # 16 GiB

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.cluster_orc]
  }
}

resource "libvirt_domain" "cluster_orc" {
  for_each  = { for cluster in local.clusters : cluster.name => cluster }
  name      = "${local.setup_name}-${each.value.name}"
  memory    = 4096
  vcpu      = 2
  cloudinit = libvirt_cloudinit_disk.cluster_orc.id

  disk {
    volume_id = libvirt_volume.cluster_orc[each.key].id
  }

  network_interface {
    network_id = libvirt_network.oakestra_dev.id
    hostname   = each.value.hostname
    addresses  = [each.value.ipv4]
    # Without a static MAC-address, the static IP assignment doesn't work during re-creation,
    # likely because the DHCP lease for the previous MAC is still active.
    mac            = each.value.mac
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
    replace_triggered_by = [libvirt_cloudinit_disk.cluster_orc]
  }
}

locals {
  cluster_orc_docker_hosts = { for cluster_orc_name, cluster_orc_domain in libvirt_domain.cluster_orc : cluster_orc_name => "tcp://${cluster_orc_domain.network_interface[0].addresses[0]}:2375" }
}

resource "docker_network" "cluster_watchtower" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  name     = "watchtower"

  ipam_config {
    subnet   = "192.168.0.0/30"
    gateway  = "192.168.0.1"
    ip_range = "192.168.0.2/32"
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }
}

resource "docker_network" "cluster_orc" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  name     = each.value.name

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }
}

resource "docker_image" "cluster_watchtower" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  name     = "containrrr/watchtower:1.7.1"

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_image" "cluster_mongo" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  name     = "mongo:3.6"

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_image" "cluster_redis" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  name     = "redis:7.4.2"

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_image" "cluster_mqtt" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  name     = "eclipse-mosquitto:1.6"

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  depends_on = [libvirt_domain.registry]
}

resource "docker_container" "cluster_watchtower" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  image    = docker_image.cluster_watchtower[each.key].image_id
  name     = "watchtower"
  restart  = "always"
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
    name = docker_network.cluster_watchtower[each.key].id
  }

  ports {
    internal = 8080
    external = local.watchtower_port
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "cluster_scheduler" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  image    = "oakestra/oakestra/cluster-scheduler:${var.oakestra_version}"
  name     = "cluster-scheduler"
  restart  = "always"
  env = [
    "MY_PORT=10105",
    "CLUSTER_MANAGER_URL=cluster-manager",
    "CLUSTER_MANAGER_PORT=10100",
    "CLUSTER_MONGO_URL=cluster-mongo",
    "CLUSTER_MONGO_PORT=10107",
    "REDIS_ADDR=redis://:clusterRedis@cluster-redis:6479"
  ]

  labels {
    label = "com.centurylinklabs.watchtower.enable"
    value = "true"
  }

  networks_advanced {
    name = docker_network.cluster_orc[each.key].id
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
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

resource "docker_container" "cluster_service_manager" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  image    = "oakestra/oakestra-net/cluster-service-manager:${var.oakestra_version}"
  name     = "cluster-service-manager"
  restart  = "always"
  env = [
    "MY_PORT=10110",
    "MQTT_BROKER_PORT=10003",
    "MQTT_BROKER_URL=cluster-mqtt",
    "ROOT_SERVICE_MANAGER_URL=${libvirt_domain.root_orc.network_interface[0].hostname}",
    "ROOT_SERVICE_MANAGER_PORT=10099",
    "SYSTEM_MANAGER_URL=cluster-manager",
    "SYSTEM_MANAGER_PORT=10000",
    "CLUSTER_MONGO_URL=cluster-mongo-net",
    "CLUSTER_MONGO_PORT=10108",
  ]

  labels {
    label = "com.centurylinklabs.watchtower.enable"
    value = "true"
  }

  networks_advanced {
    name = docker_network.cluster_orc[each.key].id
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
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

resource "docker_container" "cluster_manager" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  image    = "oakestra/oakestra/cluster-manager:${var.oakestra_version}"
  name     = "cluster-manager"
  restart  = "always"
  env = [
    "MY_PORT=10100",
    "SYSTEM_MANAGER_URL=${libvirt_domain.root_orc.network_interface[0].hostname}",
    "SYSTEM_MANAGER_PORT=10000",
    "CLUSTER_SERVICE_MANAGER_ADDR=cluster-service-manager",
    "CLUSTER_SERVICE_MANAGER_PORT=10110",
    "CLUSTER_MONGO_URL=cluster-mongo",
    "CLUSTER_MONGO_PORT=10107",
    "CLUSTER_SCHEDULER_URL=cluster-scheduler",
    "CLUSTER_SCHEDULER_PORT=10105",
    "MQTT_BROKER_URL=cluster-mqtt",
    "MQTT_BROKER_PORT=10003",
    "CLUSTER_NAME=${each.value.name}",
    "CLUSTER_LOCATION=${each.value.location}",
  ]

  labels {
    label = "com.centurylinklabs.watchtower.enable"
    value = "true"
  }

  networks_advanced {
    name = docker_network.cluster_orc[each.key].id
  }

  ports {
    internal = 10100
    external = 10100
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
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

resource "docker_container" "cluster_mongo" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  image    = docker_image.cluster_mongo[each.key].image_id
  name     = "cluster-mongo"
  restart  = "always"
  command  = ["mongod", "--port", "10107"]

  networks_advanced {
    name = docker_network.cluster_orc[each.key].id
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "cluster_mongo_net" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  image    = docker_image.cluster_mongo[each.key].image_id
  name     = "cluster-mongo-net"
  restart  = "always"
  command  = ["mongod", "--port", "10108"]

  networks_advanced {
    name = docker_network.cluster_orc[each.key].id
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "cluster_redis" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  image    = docker_image.cluster_redis[each.key].image_id
  name     = "cluster-redis"
  restart  = "always"
  command  = ["redis-server", "--requirepass", "clusterRedis", "--port", "6479"]

  networks_advanced {
    name = docker_network.cluster_orc[each.key].id
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}

resource "docker_container" "cluster_mqtt" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }
  image    = docker_image.cluster_mqtt[each.key].image_id
  name     = "cluster-mqtt"
  restart  = "always"

  networks_advanced {
    name = docker_network.cluster_orc[each.key].id
  }

  upload {
    file    = "/mosquitto/config/mosquitto.conf"
    content = <<-EOT
      listener 10003
      allow_anonymous true
    EOT
  }

  ports {
    internal = 10003
    external = 10003
  }

  override {
    host          = local.cluster_orc_docker_hosts[each.key]
    cert_material = tls_self_signed_cert.docker_client.cert_pem
    key_material  = tls_self_signed_cert.docker_client.private_key_pem
    ca_material   = tls_self_signed_cert.docker_server.cert_pem
  }

  lifecycle {
    ignore_changes = [network_mode]
  }
}
