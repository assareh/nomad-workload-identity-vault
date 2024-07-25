locals {
  private_key_filename = "aws-ssh-key.pem"
}

variable "allowed-source-ip" {
  description = "Your IP address to allow traffic from in CIDR notation."
  default     = "0.0.0.0/0"
}

variable "address_space" {
  description = "The address space that is used by the virtual network. You can supply more than one address space. Changing this forces a new resource to be created."
  default     = "10.0.0.0/16"
}

variable "aws_region" {
  description = "The region where the resources are created."
  default     = "us-west-2"
}

variable "instance_type" {
  description = "Specifies the AWS instance type."
  default     = "t3a.small"
}

variable "ssh_username" {
  type    = string
  default = "ubuntu"
}

variable "subnet_prefix" {
  description = "The address prefix to use for the subnet."
  default     = "10.0.10.0/24"
}