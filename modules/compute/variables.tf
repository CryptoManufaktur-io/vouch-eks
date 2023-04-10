variable "compute_name" {
  description = "name of instance"
  type = string
}

variable "compute_size" {
  description = "size of instance"
  type = string
}

variable "subnet_id" {
  description = "Subnetwork"
  type = string
}

variable "compute_image" {
  description = "type of image for instance"
  type = string
}

variable "zone" {
  description = "zone instance is deployed in"
  type = string
}

variable "region" {
  description = "zone instance is deployed in"
  type = string
}

variable "ssh_user" {
  description = "SSH Username"
  type        = string
}

variable "key_name" {
  description = "SSH Public Key"
  type        = string
}


variable "metadata_startup_script" {
  type = string
}

variable "security_groups" {
  type = list(string)
}
