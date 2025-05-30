variable "setup_name" {
  type        = string
  description = <<-EOT
    The name for the whole Oakestra setup, used for local domains and more.
    Must have a length between 1 and 16 characters and should not contain special characters other than '-' and '_'.
  EOT

  validation {
    condition     = can(regex("^[0-9A-Za-z_-]{1,10}$", var.setup_name))
    error_message = "Must have a length between 1 and 10 characters and should not contain special characters other than '-' and '_'."
  }
}

variable "pool_base_path" {
  type        = string
  nullable    = false
  default     = "/var/oakestra-dev-pools"
  description = "The base path for the libvirt pool this setup creates, it will be located at '#basepath#/#setup_name#'."
}

variable "oakestra_version" {
  type        = string
  nullable    = false
  description = <<-EOT
    The version of Oakestra that is used to deploy its docker containers and binaries.
    Oakestra docker images that are pushed to the local registry will replace the default one for that version.
  EOT
}

variable "oakestra_dashboard_version" {
  type        = string
  nullable    = false
  description = <<-EOT
    The version of Oakestra that is used to deploy its dashboard docker container.
    Oakestra docker images that are pushed to the local registry will replace the default one for that version.
  EOT
}

variable "registry_memory" {
  type    = number
  default = 4096
}

variable "registry_vcpu" {
  type    = number
  default = 2
}

variable "root_orc_memory" {
  type    = number
  default = 4096
}

variable "root_orc_vcpu" {
  type    = number
  default = 2
}

variable "clusters" {
  type = list(object({
    memory   = number
    vcpu     = number
    location = string
    workers = list(object({
      memory = number
      vcpu   = number
      disk   = number
    }))
  }))
  default = [{
    memory   = 4096
    vcpu     = 2
    location = "48.1507,11.5691,1000"
    workers = [
      {
        memory = 2048
        vcpu   = 2
        disk   = 16384
      }
    ]
  }]
}

variable "node_subnet_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "10.44.0.0/16"
  description = "The IPv4 subnet for the libvirt VMs being created."

  validation {
    condition     = can(cidrhost(var.node_subnet_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }

  validation {
    condition     = endswith(var.node_subnet_ipv4_cidr, "/16")
    error_message = "Currently only /16 subnets are supported."
  }
}

variable "container_subnet_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "172.18.0.0/16"
  description = "The IPv4 subnet for containers launched inside VMs."

  validation {
    condition     = can(cidrhost(var.container_subnet_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }
}

variable "watchtower_subnet_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "192.168.0.0/30"
  description = "The IPv4 subnet for Watchtower launched inside libvirt VMs."

  validation {
    condition     = can(cidrhost(var.watchtower_subnet_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }

  validation {
    condition     = endswith(var.watchtower_subnet_ipv4_cidr, "/30")
    error_message = "Currently only /30 subnets are supported."
  }
}

variable "additional_packages" {
  type        = list(string)
  nullable    = false
  default     = []
  description = "Additional packages to be installed on each node."
}
