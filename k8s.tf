terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  profile = "k8splay"
  region = "us-east-1"
  default_tags {
    tags = {
      Environment = "k8splay"
    }
  }  
}

resource "aws_vpc" "k8splay-vpc" {
  cidr_block = "10.2.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name = "k8splay"
  }
}

