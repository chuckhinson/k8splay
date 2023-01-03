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

variable "node_vpc_cidr_block" {
  default = "10.2.0.0/16"
  description = "This is the CIDR block for the VPC where the cluster will live"
}
variable "cluster_cidr_block" {
  default = "10.200.0.0/16"
  description = "The CIDR block to be used for Cluster IP addresses"
}
variable "service_cidr_block" {
  default = "10.32.0.0/24"
  description = "The CIDR block to be used for Service Virtual IP addresses"
}

variable "mgmt_server_cidr_block" {
  description = "The IP address of the (remote) server that is allowed to access the nodes (as a /32 CIDR block)"
}

locals {
  node_subnet_cidr_block = cidrsubnet(var.node_vpc_cidr_block,8,1)
}

resource "aws_vpc" "k8splay-vpc" {
  cidr_block = var.node_vpc_cidr_block
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name = "k8splay"
  }
}

resource "aws_internet_gateway" "k8splay-gw" {
  vpc_id = aws_vpc.k8splay-vpc.id
  tags = {
    Name = "k8splay"
  }
}

resource "aws_subnet" "node-subnet" {
  vpc_id = aws_vpc.k8splay-vpc.id
  cidr_block = local.node_subnet_cidr_block
  tags = {
    Name = "node subnet"
  }
}

resource "aws_route_table" "node-routes" {
  vpc_id = aws_vpc.k8splay-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.k8splay-gw.id
  }

  tags = {
    Name = "node routes"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.node-subnet.id
  route_table_id = aws_route_table.node-routes.id
}

resource "aws_security_group" "k8splay-internal" {
  name        = "k8splay-internal"
  description = "Allow cluster inbound traffic"
  vpc_id      = aws_vpc.k8splay-vpc.id

  ingress {
    description      = "Node network"
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = [aws_vpc.k8splay-vpc.cidr_block]
  }
  ingress {
    description      = "cluster network"
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = [var.cluster_cidr_block]
  }

  # AWS normally provides a default egress rule, but terraform
  # deletes it by default, so we need to add it here to keep it
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "k8splay-internal"
  }
}

resource "aws_security_group" "k8splay-remote" {
  name        = "k8splay-remote"
  description = "Allow remote access to cluster"
  vpc_id      = aws_vpc.k8splay-vpc.id

  ingress {
    description      = "ssh from mgmt server"
    protocol         = "tcp"
    from_port        = "22"
    to_port          = "22"
    cidr_blocks      = [var.mgmt_server_cidr_block]
  }
  ingress {
    description      = "internal https from mgmt server"
    protocol         = "tcp"
    from_port        = "6443"
    to_port          = "6443"
    cidr_blocks      = [var.mgmt_server_cidr_block]
  }
  ingress {
    description      = "https from mgmt server"
    protocol         = "tcp"
    from_port        = "443"
    to_port          = "443"
    cidr_blocks      = [var.mgmt_server_cidr_block]
  }
  ingress {
    description      = "icmp from mgmt server"
    protocol         = "icmp"
    from_port        = "-1"
    to_port          = "-1"
    cidr_blocks      = [var.mgmt_server_cidr_block]
  }

  tags = {
    Name = "k8splay-remote"
  }
}


data "aws_ami" "ubuntu_jammy" {
  most_recent      = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name = "architecture"
    values = ["x86_64"]
  }

  owners = ["099720109477"]  # amazon
}

resource "aws_instance" "controllers" {
  count = 3

  ami           = data.aws_ami.ubuntu_jammy.id
  associate_public_ip_address = true
  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = "50"
  }
  instance_type = "t3.micro"
  key_name = "k8splay"
  private_ip =  cidrhost(local.node_subnet_cidr_block,10+count.index)
  source_dest_check = false
  subnet_id = aws_subnet.node-subnet.id
  user_data = "name=controller-${count.index}"
  vpc_security_group_ids = [aws_security_group.k8splay-internal.id, aws_security_group.k8splay-remote.id]

  tags = {
    Name = "controller-${count.index}"
  }
}

resource "aws_instance" "workers" {
  count = 3

  ami           = data.aws_ami.ubuntu_jammy.id
  associate_public_ip_address = true
  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = "50"
  }
  instance_type = "t3.micro"
  key_name = "k8splay"
  private_ip =  cidrhost(local.node_subnet_cidr_block,20+count.index)
  source_dest_check = false
  subnet_id = aws_subnet.node-subnet.id
  user_data = "name=worker-${count.index}|pod-cidr=10.200.${count.index}.0/24"
  vpc_security_group_ids = [aws_security_group.k8splay-internal.id, aws_security_group.k8splay-remote.id]

  tags = {
    Name = "worker-${count.index}"
  }
}
