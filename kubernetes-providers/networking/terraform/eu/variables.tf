variable "name_prefix" {
  type    = string
  default = "mp-eu"
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "azure_location" {
  type    = string
  default = "westeurope"
}

variable "gcp_region" {
  type    = string
  default = "europe-west1"
}

variable "gcp_zone" {
  type    = string
  default = "europe-west1-b"
}

variable "gcp_project" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "aws_vpc_cidr" {
  type    = string
  default = "10.11.0.0/16"
}

variable "azure_vnet_cidr" {
  type    = string
  default = "10.21.0.0/16"
}

variable "gcp_vpc_cidr" {
  type    = string
  default = "10.31.0.0/16"
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
