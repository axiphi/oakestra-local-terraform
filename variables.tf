variable "setup_name" {
  type        = string
  nullable    = true
  default     = null
  description = <<-EOT
    The name for the whole Oakestra setup, used for local domains, VM names and more.
    Must have a length between 1 and 16 characters and should not contain special characters other than '-' and '_'.
    Defaults to "oaks-<<linux user-id>>" if kept null or empty.
  EOT

  validation {
    condition     = var.setup_name == null || var.setup_name == "" || can(regex("^[0-9A-Za-z_-]{1,10}$", var.setup_name))
    error_message = "Must have a length between 1 and 10 characters and should not contain special characters other than '-' and '_'."
  }
}

variable "pool_base_path" {
  type        = string
  nullable    = false
  default     = "/var/oakestra-dev-pools"
  description = "The base path for the libvirt pool this setup creates, it will be located at '<<basepath>>/<<setup_name>>'."
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

variable "clusters" {
  type = list(object({
    memory   = number
    vcpu     = number
    location = string
    workers = list(object({
      memory = number
      vcpu   = number
    }))
  }))
  default = [{
    memory   = 4096
    vcpu     = 2
    location = "48.1507,11.5691,1000"
    workers = [
      {
        memory = 2048
        vcpu   = 1
      }
    ]
  }]
}

variable "libvirt_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "10.44.0.0/16"
  description = "The IPv4 subnet for the libvirt VMs being created."

  validation {
    condition     = can(cidrhost(var.libvirt_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }

  validation {
    condition     = endswith(var.libvirt_ipv4_cidr, "/16")
    error_message = "Currently only /16 subnets are supported."
  }
}

variable "container_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "172.18.0.0/16"
  description = "The IPv4 subnet for containers launched inside VMs."

  validation {
    condition     = can(cidrhost(var.container_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }
}

variable "watchtower_ipv4_cidr" {
  type        = string
  nullable    = false
  default     = "192.168.0.0/30"
  description = "The IPv4 subnet for Watchtower launched inside libvirt VMs."

  validation {
    condition     = can(cidrhost(var.watchtower_ipv4_cidr, 0))
    error_message = "Must be valid IPv4 CIDR."
  }

  validation {
    condition     = endswith(var.watchtower_ipv4_cidr, "/30")
    error_message = "Currently only /30 subnets are supported."
  }
}

variable "debug_ports_enabled" {
  type        = string
  nullable    = false
  default     = false
  description = "If true, additional ports are exposed from Oakestra components for debugging purposes."
}
