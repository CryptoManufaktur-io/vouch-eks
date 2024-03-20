variable "compute" {
  description = "compute instances"
  type        = map(any)
}

variable "compute_size" {
  description = "Compute Instance size"
  type        = string
}

variable "project_id" {
  description = "Project ID"
  type        = string
}

variable "vouch_tag" {
  description = "Vouch docker image tag"
  type        = string
}

variable "azs" {
  description = "List of availability zones used"
  type        = list(string)
}

variable "default_tags" {
  description = "Default tags when not provided"
  type        = list(string)
}

variable "ssh_user" {
  description = "SSH Username"
  type        = string
}

variable "ssh_key_name" {
  description = "SSH Key Pair name that's already imported/created in EC2"
  type        = string
}

variable "ssh_private_key" {
  description = "SSH Private Key"
  type        = string
}

variable "ssh_extra_args" {
  description = "SSH Command extra arguments. E.g: -J for jumphost"
  type        = string
}

variable "acme_email" {
  description = "ACME email for SSL certificates"
  type = string
}

variable "cf_api_token" {
  description = "CloudFlare Global API Key"
  type        = string
}

variable "cf_domain" {
  description = "CloudFlare domain"
  type        = string
}

variable "mev_subdomain" {
  description = "MEV subdomain"
  type = string
}

variable "ssh_in_addresses" {
  description = "List of CIDR blocks to allow SSH traffic from"
  type = list(string)
}

variable "vouch_https_in_addresses" {
  description = "List of CIDR blocks to allow Vouch MEV traffic from"
  type        = list(string)
}

variable "ec2_ami" {
  description = "EC2 AMI ID obtained from the AMI Catalog"
  type = string
}

variable "public_subnets" {
  description = "List of Public Subnets CIDR Blocks"
  type = list(string)
}

variable "private_subnets" {
  description = "List of Private Subnets CIDR Blocks"
  type = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR Block"
  type = string
}

variable "kubernetes_version" {
  description = "kubernetes version"
  type = string
}

variable "kube_proxy_version" {
  description = "kube-proxy version"
  type = string
}

variable "vpc_cni_version" {
  description = "vpc-cni version"
  type = string
}

variable "coredns_version" {
  description = "coredns version"
  type = string
}

variable "admin_role_arns" {
  description = "List of IAM Role ARNs that get admin permissions"
  type = list(string)
}

variable "admin_user_arns" {
  description = "List of IAM User ARNs that get admin permissions"
  type = list(string)
}
