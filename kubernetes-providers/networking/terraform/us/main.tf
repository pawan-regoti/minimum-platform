############################
# AWS
############################

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_vpc" "wg" {
  cidr_block           = var.aws_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.name_prefix}-aws-vpc"
  }
}

resource "aws_internet_gateway" "wg" {
  vpc_id = aws_vpc.wg.id
  tags = {
    Name = "${var.name_prefix}-aws-igw"
  }
}

resource "aws_subnet" "wg" {
  vpc_id                  = aws_vpc.wg.id
  cidr_block              = cidrsubnet(var.aws_vpc_cidr, 8, 0)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-aws-subnet"
  }
}

resource "aws_route_table" "wg" {
  vpc_id = aws_vpc.wg.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.wg.id
  }

  tags = {
    Name = "${var.name_prefix}-aws-rt"
  }
}

resource "aws_route_table_association" "wg" {
  subnet_id      = aws_subnet.wg.id
  route_table_id = aws_route_table.wg.id
}

resource "aws_security_group" "wg" {
  name   = "${var.name_prefix}-aws-wg-sg"
  vpc_id = aws_vpc.wg.id

  ingress {
    description = "WireGuard"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  wg_port     = 51820
  aws_wg_ip   = "172.16.10.1"
  azure_wg_ip = "172.16.10.2"
  gcp_wg_ip   = "172.16.10.3"
}

resource "aws_instance" "wg" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.wg.id
  vpc_security_group_ids = [aws_security_group.wg.id]
  source_dest_check      = false

  user_data = <<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - wireguard
      - iptables
    write_files:
      - path: /etc/sysctl.d/99-ipforward.conf
        content: |
          net.ipv4.ip_forward=1
      - path: /etc/wireguard/wg0.conf
        permissions: '0600'
        content: |
          [Interface]
          Address = ${local.aws_wg_ip}/24
          ListenPort = ${local.wg_port}
          PrivateKey = ${var.wg_aws_private_key}

          [Peer]
          PublicKey = ${var.wg_azure_public_key}
          PresharedKey = ${var.wg_psk_aws_azure}
          Endpoint = ${azurerm_public_ip.wg.ip_address}:${local.wg_port}
          AllowedIPs = ${local.azure_wg_ip}/32,${var.azure_vnet_cidr}
          PersistentKeepalive = 25

          [Peer]
          PublicKey = ${var.wg_gcp_public_key}
          PresharedKey = ${var.wg_psk_aws_gcp}
          Endpoint = ${google_compute_address.wg.address}:${local.wg_port}
          AllowedIPs = ${local.gcp_wg_ip}/32,${var.gcp_vpc_cidr}
          PersistentKeepalive = 25
    runcmd:
      - sysctl --system
      - systemctl enable wg-quick@wg0
      - systemctl start wg-quick@wg0
  CLOUDINIT

  tags = {
    Name = "${var.name_prefix}-aws-wg"
  }
}

resource "aws_eip" "wg" {
  domain = "vpc"
  tags = {
    Name = "${var.name_prefix}-aws-wg-eip"
  }
}

resource "aws_eip_association" "wg" {
  instance_id   = aws_instance.wg.id
  allocation_id = aws_eip.wg.id
}

resource "aws_route" "to_azure" {
  route_table_id         = aws_route_table.wg.id
  destination_cidr_block = var.azure_vnet_cidr
  network_interface_id   = aws_instance.wg.primary_network_interface_id
}

resource "aws_route" "to_gcp" {
  route_table_id         = aws_route_table.wg.id
  destination_cidr_block = var.gcp_vpc_cidr
  network_interface_id   = aws_instance.wg.primary_network_interface_id
}

############################
# Azure
############################

resource "azurerm_resource_group" "wg" {
  name     = "${var.name_prefix}-rg"
  location = var.azure_location
}

resource "azurerm_virtual_network" "wg" {
  name                = "${var.name_prefix}-vnet"
  location            = azurerm_resource_group.wg.location
  resource_group_name = azurerm_resource_group.wg.name
  address_space       = [var.azure_vnet_cidr]
}

resource "azurerm_subnet" "wg" {
  name                 = "${var.name_prefix}-subnet"
  resource_group_name  = azurerm_resource_group.wg.name
  virtual_network_name = azurerm_virtual_network.wg.name
  address_prefixes     = [cidrsubnet(var.azure_vnet_cidr, 8, 0)]
}

resource "azurerm_public_ip" "wg" {
  name                = "${var.name_prefix}-pip"
  location            = azurerm_resource_group.wg.location
  resource_group_name = azurerm_resource_group.wg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "wg" {
  name                = "${var.name_prefix}-nsg"
  location            = azurerm_resource_group.wg.location
  resource_group_name = azurerm_resource_group.wg.name

  security_rule {
    name                       = "wireguard"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "51820"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "ssh"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "wg" {
  name                  = "${var.name_prefix}-nic"
  location              = azurerm_resource_group.wg.location
  resource_group_name   = azurerm_resource_group.wg.name
  ip_forwarding_enabled = true

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.wg.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.wg.id
  }
}

resource "azurerm_network_interface_security_group_association" "wg" {
  network_interface_id      = azurerm_network_interface.wg.id
  network_security_group_id = azurerm_network_security_group.wg.id
}

resource "azurerm_linux_virtual_machine" "wg" {
  name                  = "${var.name_prefix}-vm"
  resource_group_name   = azurerm_resource_group.wg.name
  location              = azurerm_resource_group.wg.location
  size                  = "Standard_B1s"
  admin_username        = "ubuntu"
  network_interface_ids = [azurerm_network_interface.wg.id]

  admin_ssh_key {
    username   = "ubuntu"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - wireguard
      - iptables
    write_files:
      - path: /etc/sysctl.d/99-ipforward.conf
        content: |
          net.ipv4.ip_forward=1
      - path: /etc/wireguard/wg0.conf
        permissions: '0600'
        content: |
          [Interface]
          Address = ${local.azure_wg_ip}/24
          ListenPort = ${local.wg_port}
          PrivateKey = ${var.wg_azure_private_key}

          [Peer]
          PublicKey = ${var.wg_aws_public_key}
          PresharedKey = ${var.wg_psk_aws_azure}
          Endpoint = ${aws_eip.wg.public_ip}:${local.wg_port}
          AllowedIPs = ${local.aws_wg_ip}/32,${var.aws_vpc_cidr}
          PersistentKeepalive = 25

          [Peer]
          PublicKey = ${var.wg_gcp_public_key}
          PresharedKey = ${var.wg_psk_azure_gcp}
          Endpoint = ${google_compute_address.wg.address}:${local.wg_port}
          AllowedIPs = ${local.gcp_wg_ip}/32,${var.gcp_vpc_cidr}
          PersistentKeepalive = 25
    runcmd:
      - sysctl --system
      - systemctl enable wg-quick@wg0
      - systemctl start wg-quick@wg0
  CLOUDINIT
  )
}

resource "azurerm_route_table" "wg" {
  name                = "${var.name_prefix}-rt"
  location            = azurerm_resource_group.wg.location
  resource_group_name = azurerm_resource_group.wg.name
}

resource "azurerm_route" "to_aws" {
  name                   = "to-aws"
  resource_group_name    = azurerm_resource_group.wg.name
  route_table_name       = azurerm_route_table.wg.name
  address_prefix         = var.aws_vpc_cidr
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_network_interface.wg.private_ip_address
}

resource "azurerm_route" "to_gcp" {
  name                   = "to-gcp"
  resource_group_name    = azurerm_resource_group.wg.name
  route_table_name       = azurerm_route_table.wg.name
  address_prefix         = var.gcp_vpc_cidr
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_network_interface.wg.private_ip_address
}

resource "azurerm_subnet_route_table_association" "wg" {
  subnet_id      = azurerm_subnet.wg.id
  route_table_id = azurerm_route_table.wg.id
}

############################
# GCP
############################

resource "google_compute_network" "wg" {
  name                    = "${var.name_prefix}-gcp-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "wg" {
  name          = "${var.name_prefix}-gcp-subnet"
  ip_cidr_range = cidrsubnet(var.gcp_vpc_cidr, 8, 0)
  region        = var.gcp_region
  network       = google_compute_network.wg.id
}

resource "google_compute_firewall" "wg" {
  name    = "${var.name_prefix}-gcp-fw"
  network = google_compute_network.wg.name

  allow {
    protocol = "udp"
    ports    = ["51820"]
  }

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["wg"]
}

resource "google_compute_address" "wg" {
  name   = "${var.name_prefix}-gcp-ip"
  region = var.gcp_region
}

resource "google_compute_instance" "wg" {
  name           = "${var.name_prefix}-gcp-vm"
  machine_type   = "e2-micro"
  zone           = var.gcp_zone
  tags           = ["wg"]
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
    }
  }

  network_interface {
    network    = google_compute_network.wg.id
    subnetwork = google_compute_subnetwork.wg.id
    access_config {
      nat_ip = google_compute_address.wg.address
    }
  }

  metadata_startup_script = <<-SCRIPT
    #!/usr/bin/env bash
    set -euo pipefail
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables
    sysctl -w net.ipv4.ip_forward=1
    cat >/etc/wireguard/wg0.conf <<'EOF'
    [Interface]
    Address = ${local.gcp_wg_ip}/24
    ListenPort = ${local.wg_port}
    PrivateKey = ${var.wg_gcp_private_key}

    [Peer]
    PublicKey = ${var.wg_aws_public_key}
    PresharedKey = ${var.wg_psk_aws_gcp}
    Endpoint = ${aws_eip.wg.public_ip}:${local.wg_port}
    AllowedIPs = ${local.aws_wg_ip}/32,${var.aws_vpc_cidr}
    PersistentKeepalive = 25

    [Peer]
    PublicKey = ${var.wg_azure_public_key}
    PresharedKey = ${var.wg_psk_azure_gcp}
    Endpoint = ${azurerm_public_ip.wg.ip_address}:${local.wg_port}
    AllowedIPs = ${local.azure_wg_ip}/32,${var.azure_vnet_cidr}
    PersistentKeepalive = 25
    EOF
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
  SCRIPT
}

resource "google_compute_route" "to_aws" {
  name              = "${var.name_prefix}-to-aws"
  network           = google_compute_network.wg.name
  dest_range        = var.aws_vpc_cidr
  next_hop_instance = google_compute_instance.wg.self_link
  priority          = 1000
}

resource "google_compute_route" "to_azure" {
  name              = "${var.name_prefix}-to-azure"
  network           = google_compute_network.wg.name
  dest_range        = var.azure_vnet_cidr
  next_hop_instance = google_compute_instance.wg.self_link
  priority          = 1000
}
