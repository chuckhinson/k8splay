#
# Terraform for deploying the compute and network resources needed for the
# Kubernetes the hard way - aws version. Note that this is mostly a translation
# from the aws cli commands found in the Provisioning Compute Resources lab.
# There are some differences because there are not direct mappings for all of the
# commands.  Note that while there is a separate Provisioning Pod Network Routes lab,
# we've included the setup of the pod routes here as well since it's easy enough
# to do.
#
# Note that the vpc cidr block is slightly different than what's used in the labs.
# (10.2.0.0 insetad of 10.0.0.0).  This was done to fit in my aws environment.  Either
# go find all of the 10.2.x.x references here and in prepare-files.sh and change them
# or be sure to modify the commands given in the labs to use 10.2.x.x instead of 10.0.x.x.
# (primarily in the Bootstrapping the Kubernetes Control PLan lab)
#
# Note also that we setup the security groups slightly differently than in the labs; 
# we restrict public access to the nodes to only be allowed from the machine that
# is being used to setup the cluster.  The IP address of that machine should be
# set in terraform.tfvars as a /32 CIDR block.


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

# Most of these should probably be locals instead of variables since there are some
# places that we've hard-coded assumptions based on the default value
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

  tags = {
    Name = "node routes"
  }
}

resource "aws_route" "external" {
  route_table_id         = aws_route_table.node-routes.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.k8splay-gw.id
}

resource "aws_route" "worker-pods" {
  # shouldnt we also include the controllers? Or are we making it so that
  # pods cant run on controllers?
  count = length(aws_instance.workers[*].private_ip)
  destination_cidr_block = "10.200.${count.index}.0/24"
  instance_id = aws_instance.workers[count.index].id
  route_table_id         = aws_route_table.node-routes.id
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

resource "aws_lb" "k8splay-api" {
  name               = "k8splay-api"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.node-subnet.id]
}

resource "aws_lb_target_group" "k8splay-api" {
  name        = "k8splay-api"
  port        = 6443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.k8splay-vpc.id
}

resource "aws_lb_target_group_attachment" "k8splay-api" {
  count = length(aws_instance.controllers[*].private_ip)

  target_group_arn = aws_lb_target_group.k8splay-api.arn
  target_id        = aws_instance.controllers[count.index].private_ip
  port             = 6443
}

resource "aws_lb_listener" "k8splay-api" {
  load_balancer_arn = aws_lb.k8splay-api.arn
  port              = "443"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8splay-api.arn
  }
}