output "aws_gateway_public_ip" {
  value = aws_eip.wg.public_ip
}

output "azure_gateway_public_ip" {
  value = azurerm_public_ip.wg.ip_address
}

output "gcp_gateway_public_ip" {
  value = google_compute_address.wg.address
}

output "cidrs" {
  value = {
    aws   = var.aws_vpc_cidr
    azure = var.azure_vnet_cidr
    gcp   = var.gcp_vpc_cidr
  }
}
