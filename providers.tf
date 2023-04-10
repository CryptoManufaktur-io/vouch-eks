terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.61"
    }
  }
  
  #  backend "gcs" {}
  backend "s3" {}
}

provider "aws" {}
