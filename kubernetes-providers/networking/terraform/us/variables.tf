variable "name_prefix" {
  type    = string
  default = "mp-us"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "azure_location" {
  type    = string
  default = "eastus"
}

variable "gcp_region" {
  type    = string
  default = "us-east4"
}

variable "gcp_zone" {
  type    = string
  default = "us-east4-a"
}

variable "gcp_project" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "aws_vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "azure_vnet_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "gcp_vpc_cidr" {
  type    = string
  default = "10.30.0.0/16"
}

variable "wg_aws_private_key" { type = string }
variable "wg_aws_public_key" { type = string }
variable "wg_azure_private_key" { type = string }
variable "wg_azure_public_key" { type = string }
variable "wg_gcp_private_key" { type = string }
variable "wg_gcp_public_key" { type = string }
variable "wg_psk_aws_azure" { type = string }
variable "wg_psk_aws_gcp" { type = string }
variable "wg_psk_azure_gcp" { type = string }
