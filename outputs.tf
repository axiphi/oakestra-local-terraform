output "ssh_key" {
  value     = tls_private_key.ssh_client.private_key_openssh
  sensitive = true
}

output "user_data" {
  value     = libvirt_cloudinit_disk.root_orc.user_data
  sensitive = true
}

output "docker_client_cert" {
  value = tls_self_signed_cert.docker_client.cert_pem
}

output "docker_client_key" {
  value     = tls_self_signed_cert.docker_client.private_key_pem
  sensitive = true
}

output "docker_server_cert" {
  value = tls_self_signed_cert.docker_server.cert_pem
}
