resource "null_resource" "oakestra_data_dir" {
  triggers = {
    oakestra_data_dir = local.oakestra_data_dir
  }

  provisioner "local-exec" {
    command = "mkdir -p '${self.triggers.oakestra_data_dir}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -rf ${self.triggers.oakestra_data_dir}"
  }
}

resource "local_sensitive_file" "ssh_key" {
  filename        = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/ssh_key"
  content         = tls_private_key.ssh_client.private_key_openssh
  file_permission = "0600"
}

resource "local_file" "ssh_known_hosts" {
  filename = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/ssh_known_hosts"
  content = join("\n", concat(
    [
      "${libvirt_domain.registry.network_interface[0].addresses[0]} ${chomp(tls_private_key.ssh_server.public_key_openssh)}",
      "${libvirt_domain.root_orc.network_interface[0].addresses[0]} ${chomp(tls_private_key.ssh_server.public_key_openssh)}"
    ],
    flatten([for cluster in local.clusters : concat(
      [
        "${libvirt_domain.cluster_orc[cluster.name].network_interface[0].addresses[0]} ${chomp(tls_private_key.ssh_server.public_key_openssh)}"
      ],
      [for worker in cluster.workers : (
        "${libvirt_domain.worker[worker.name].network_interface[0].addresses[0]} ${chomp(tls_private_key.ssh_server.public_key_openssh)}"
      )]
    )])
  ))
  file_permission = "0600"
}

resource "local_file" "ssh_config" {
  filename = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/ssh_config"
  content = join("\n", concat(
    [
      <<-EOT
        Host registry
         HostName ${libvirt_domain.registry.network_interface[0].addresses[0]}
         User root
         IdentityFile ${local_sensitive_file.ssh_key.filename}
         UserKnownHostsFile ${local_file.ssh_known_hosts.filename}
      EOT
      ,
      <<-EOT
        Host root-orc
         HostName ${libvirt_domain.root_orc.network_interface[0].addresses[0]}
         User root
         IdentityFile ${local_sensitive_file.ssh_key.filename}
         UserKnownHostsFile ${local_file.ssh_known_hosts.filename}
      EOT
    ],
    flatten([for cluster in local.clusters : concat(
      [
        <<-EOT
          Host ${cluster.name}
           HostName ${libvirt_domain.cluster_orc[cluster.name].network_interface[0].addresses[0]}
           User root
           IdentityFile ${local_sensitive_file.ssh_key.filename}
           UserKnownHostsFile ${local_file.ssh_known_hosts.filename}
        EOT
      ],
      [for worker in cluster.workers : (
        <<-EOT
          Host ${worker.name}
           HostName ${libvirt_domain.worker[worker.name].network_interface[0].addresses[0]}
           User root
           IdentityFile ${local_sensitive_file.ssh_key.filename}
           UserKnownHostsFile ${local_file.ssh_known_hosts.filename}
        EOT
      )]
    )])
  ))
  file_permission = "0644"
}

locals {
  worker_names = [for worker in local.workers : worker.name]
}

resource "local_file" "activate" {
  filename        = "${null_resource.oakestra_data_dir.triggers.oakestra_data_dir}/activate"
  content         = <<-EOT
    # This file must be used with "source" *from bash*
    # you cannot run it directly

    if [ "$${BASH_SOURCE-}" = "$0" ]; then
      echo "You must source this script: \$ source $0" >&2
      exit 33
    fi

    ${local.setup_name}-ssh() {
      ssh -F "${local_file.ssh_config.filename}" "$@"
    }

    ${local.setup_name}-image-push() {
      if [ $# -ne 1 ]; then
          echo "Error: ${local.setup_name}-image-push expects exactly one argument." >&2
          return 1
      fi

      docker save "$1" | ${local.setup_name}-ssh -q registry "restore-image.sh \"$1\""
    }

    ${local.setup_name}-nodeengine-push() {
      if [ $# -ne 2 ]; then
        echo "Error: ${local.setup_name}-nodeengine-push expects exactly two arguments." >&2
        return 1
      fi

      for worker in '${join("' '", local.worker_names)}'; do
        ${local.setup_name}-ssh -q "$${worker}" "systemctl stop nodeengine.service"
        scp -q -p -F "/home/phiber/.local/share/oakestra-dev/oaks-1000/ssh_config" "$1" "$${worker}:/usr/local/bin/NodeEngine"
        scp -q -p -F "/home/phiber/.local/share/oakestra-dev/oaks-1000/ssh_config" "$2" "$${worker}:/usr/local/bin/nodeengined"
        ${local.setup_name}-ssh -q "$${worker}" "systemctl start nodeengine.service"
      done
    }

    ${local.setup_name}-netmanager-push() {
      if [ $# -ne 1 ]; then
        echo "Error: ${local.setup_name}-netmanager-push expects exactly one argument." >&2
        return 1
      fi

      for worker in '${join("' '", local.worker_names)}'; do
        ${local.setup_name}-ssh -q "$${worker}" "systemctl stop netmanager.service"
        scp -q -p -F "/home/phiber/.local/share/oakestra-dev/oaks-1000/ssh_config" "$1" "$${worker}:/usr/local/bin/NetManager"
        ${local.setup_name}-ssh -q "$${worker}" "systemctl start netmanager.service"
      done
    }
  EOT
  file_permission = "0744"
}
