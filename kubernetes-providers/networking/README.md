# full-mesh private connectivity (AWS <-> Azure <-> GCP)

This folder provisions **private network connectivity** between AWS, Azure, and GCP for two regional groups:

- **US**: AWS `us-east-1` <-> Azure `eastus` <-> GCP `us-east4`
- **EU**: AWS `eu-west-1` <-> Azure `westeurope` <-> GCP `europe-west1`

## approach

Terraform creates, per region group:

- 1 VPC/VNet/VPC (with a single subnet)
- 1 small Linux VM per cloud acting as a VPN router
- A **WireGuard full mesh** between the 3 VPN routers
- Cloud route rules so traffic between the three networks is routed via the local VPN router

This connects the **VPC/VNet networks** together (L3 routing), which you can then use for private access patterns.

## prerequisites

- `terraform` installed
- AWS/Azure/GCP credentials available (environment variables are the simplest)
- WireGuard keys + PSKs (see below)

### wireguard keys

Generate 3 keypairs + 3 PSKs (example on macOS):

- `brew install wireguard-tools`
- `wg genkey | tee aws.key | wg pubkey > aws.pub`
- `wg genkey | tee azure.key | wg pubkey > azure.pub`
- `wg genkey | tee gcp.key | wg pubkey > gcp.pub`
- `wg genpsk > psk-aws-azure`
- `wg genpsk > psk-aws-gcp`
- `wg genpsk > psk-azure-gcp`

Put these into `config.local.json` under `secrets` (this repo gitignores that file).

Required keys:

- `WG_AWS_PRIVATE_KEY`, `WG_AWS_PUBLIC_KEY`
- `WG_AZURE_PRIVATE_KEY`, `WG_AZURE_PUBLIC_KEY`
- `WG_GCP_PRIVATE_KEY`, `WG_GCP_PUBLIC_KEY`
- `WG_PSK_AWS_AZURE`, `WG_PSK_AWS_GCP`, `WG_PSK_AZURE_GCP`

Also required (for Terraform inputs):

- `GCP_PROJECT` (GCP project id)
- `SSH_PUBLIC_KEY` (an SSH public key in OpenSSH format for the Azure VPN VM)

## apply

Run:

- `./scripts/connect-networks-fullmesh.sh`

It applies both:

- `networking/terraform/us`
- `networking/terraform/eu`

## destroy

From each directory:

- `terraform destroy -auto-approve`
