module "vpc" {
  source                        = "terraform-aws-modules/vpc/aws"
  version                       = "3.4.0"
  name                          = "${var.project_id}-vpc"
  cidr                          = var.vpc_cidr
  azs                           = var.azs
  private_subnets               = var.private_subnets
  public_subnets                = var.public_subnets
  enable_nat_gateway            = true
  single_nat_gateway            = true
  enable_dns_hostnames          = true
  manage_default_security_group = true
  default_security_group_name   = "${var.project_id}-default-security-group"

  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "project" = var.project_id
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "project" = var.project_id
  }

  tags = {
    "project" = var.project_id
  }
}
