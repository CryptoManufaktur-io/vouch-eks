terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.37.0"
    }
  }
  
  #  backend "gcs" {}
  backend "s3" {}
}

provider "aws" {}
