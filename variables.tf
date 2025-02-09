variable "setup_name" {
  type     = string
  nullable = true
  default  = null
  validation {
    condition     = var.setup_name == null || var.setup_name == "" || can(regex("^[0-9A-Za-z_-]{1,10}$", var.setup_name))
    error_message = "Must have a length between 1 and 10 characters and should not contain special characters other than '-' and '_'."
  }
  description = <<-EOT
    The name for the whole Oakestra setup, used for local domains, VM names and more.
    Must have a length between 1 and 16 characters and should not contain special characters other than '-' and '_'.
    Defaults to "oaks-<<linux user-id>>" if kept null or empty.
  EOT
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
