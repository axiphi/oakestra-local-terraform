resource "libvirt_cloudinit_disk" "worker" {
  for_each = { for cluster in local.clusters : cluster.name => cluster }

  name     = "${each.key}-worker-init.iso"
  pool     = libvirt_pool.oakestra_dev.name
  user_data = join("\n", ["#cloud-config", yamlencode({
    package_update = true
    packages = var.additional_packages
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
        path        = "/usr/local/lib/systemd/system/netmanager.service"
        content     = <<-EOT
          [Unit]
          Description=Oakestra NetManager Service
          After=network.target

          [Service]
          Type=simple
          Restart=always
          RestartSec=5
          ExecStart=/usr/local/bin/NetManager
          StandardOutput=append:/var/log/oakestra/netmanager.log
          StandardError=append:/var/log/oakestra/netmanager.log

          [Install]
          WantedBy=multi-user.target
        EOT
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path        = "/usr/local/lib/systemd/system/nodeengine.service"
        content     = <<-EOT
          [Unit]
          Description=Oakestra NodeEngine Service
          After=network.target

          [Service]
          Type=simple
          Restart=always
          RestartSec=5
          ExecStart=/usr/local/bin/nodeengined
          StandardOutput=append:/var/log/oakestra/nodeengine.log
          StandardError=append:/var/log/oakestra/nodeengine.log

          [Install]
          WantedBy=multi-user.target
        EOT
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path = "/etc/netmanager/tuncfg.json"
        content = jsonencode({
          HostTunnelDeviceName      = "goProxyTun"
          TunnelIP                  = "10.19.1.254"
          ProxySubnetwork           = "10.30.0.0"
          ProxySubnetworkMask       = "255.255.0.0"
          TunnelPort                = 50103
          MTUsize                   = 1450
          TunNetIPv6                = "fcef::dead:beef"
          ProxySubnetworkIPv6       = "fcef::"
          ProxySubnetworkIPv6Prefix = 21
        })
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path = "/etc/netmanager/netcfg.json"
        content = jsonencode({
          NodePublicAddress = "0.0.0.0"
          NodePublicPort    = "50103"
          ClusterUrl        = "0.0.0.0"
          ClusterMqttPort   = "10003"
          Debug             = false
          MqttCert          = ""
          MqttKey           = ""
        })
        owner       = "root:root"
        permissions = "0644"
      },
      {
        path = "/etc/oakestra/conf.json"
        content = jsonencode({
          conf_version         = "1.0"
          cluster_address      = each.value.orc_ipv4
          cluster_port         = 10100
          app_logs             = "/tmp"
          overlay_network      = "default"
          overlay_network_port = 0
          mqtt_cert_file       = ""
          mqtt_key_file        = ""
          addons               = null
          virtualizations = [
            {
              # [sic!]
              "virutalizaiton_name" : "containerd",
              "virutalizaiton_runtime" : "docker",
              "virutalizaiton_active" : true,
              "virutalizaiton_config" : []
            }
          ]
        })
      }
    ],
    runcmd = [
      # install containerd
      "curl --location --silent https://github.com/containerd/containerd/releases/download/v2.0.2/containerd-2.0.2-linux-amd64.tar.gz | tar --extract --gzip --directory=/usr/local --file=-",
      # install runc
      "curl --location --silent --create-dirs --output /usr/local/sbin/runc https://github.com/opencontainers/runc/releases/download/v1.2.4/runc.amd64",
      "chmod 0755 /usr/local/sbin/runc",
      # install CNI plugins
      "mkdir -p /opt/cni/bin",
      "curl --location --silent https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz | tar --extract --gzip --directory=/opt/cni/bin --file=-",
      # install containerd systemd-service
      "curl --location --silent --create-dirs --output /usr/local/lib/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service",
      "chmod 0755 /usr/local/lib/systemd /usr/local/lib/systemd/system",
      # install Oakestra binaries
      join(" && ", [
        "export OAK_TMP=\"$(mktemp -d)\"",
        "curl --location --silent https://github.com/oakestra/oakestra/releases/download/${var.oakestra_version}/NodeEngine_amd64.tar.gz | tar --extract --gzip \"--directory=$${OAK_TMP}\" --file=-",
        "cp \"$${OAK_TMP}/NodeEngine\" /usr/local/bin/NodeEngine",
        "cp \"$${OAK_TMP}/nodeengined\" /usr/local/bin/nodeengined",
        "rm -r \"$${OAK_TMP}\""
      ]),
      join(" && ", [
        "export OAK_TMP=\"$(mktemp -d)\"",
        "curl --location --silent https://github.com/oakestra/oakestra-net/releases/download/${var.oakestra_version}/NetManager_amd64.tar.gz | tar --extract --gzip \"--directory=$${OAK_TMP}\" --file=-",
        "cp \"$${OAK_TMP}/NetManager\" /usr/local/bin/NetManager",
        "rm -r \"$${OAK_TMP}\""
      ]),
      "mkdir -p /var/log/oakestra",
      # start containerd and Oakestra
      "systemctl daemon-reload",
      "systemctl enable --now containerd netmanager nodeengine",
    ]
  })])
  network_config = file("${path.module}/resources/ubuntu-network.yml")
}

resource "libvirt_volume" "worker" {
  for_each       = { for worker in local.workers : worker.name => worker }
  name           = "${each.key}.iso"
  pool           = libvirt_pool.oakestra_dev.name
  base_volume_id = libvirt_volume.ubuntu_24_04.id
  size           = 16 * 1024 * 1024 * 1024 # 16 GiB

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.worker]
  }
}

resource "libvirt_domain" "worker" {
  for_each = { for worker in local.workers : worker.name => worker }

  name     = "${var.setup_name}-${each.key}"
  memory   = 4096
  vcpu     = 2
  cloudinit = libvirt_cloudinit_disk.worker[each.value.cluster_name].id

  cpu {
    mode = "host-model"
  }

  disk {
    volume_id = libvirt_volume.worker[each.key].id
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

  depends_on = [libvirt_domain.registry]
}
