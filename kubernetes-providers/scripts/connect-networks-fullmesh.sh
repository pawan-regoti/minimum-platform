#!/usr/bin/env bash
set -euo pipefail

# Provisions full-mesh private connectivity between AWS/Azure/GCP using Terraform.
#
# This reads secrets from config.local.json via utils/emit-envs.py.
# Secrets expected (as exports):
# - WG_* keys described in networking/README.md
# - AWS/Azure/GCP provider credentials (or provide them via your shell environment)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

apply_dir() {
  local dir="$1"
  echo
  echo "==> Applying terraform: $dir"
  pushd "$dir" >/dev/null
  terraform init -upgrade
  terraform validate
  terraform plan
  terraform apply -auto-approve
  popd >/dev/null
}

main() {
  require_cmd terraform
  require_cmd python3

  if [[ -f "$ENV_EMITTER" ]]; then
    # shellcheck disable=SC1090
    eval "$(python3 "$ENV_EMITTER")"
  fi

  # Map common Azure env vars (CAPZ-style) to what the Terraform azurerm provider expects.
  if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" && -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"; fi
  if [[ -n "${AZURE_TENANT_ID:-}" && -z "${ARM_TENANT_ID:-}" ]]; then export ARM_TENANT_ID="$AZURE_TENANT_ID"; fi
  if [[ -n "${AZURE_CLIENT_ID:-}" && -z "${ARM_CLIENT_ID:-}" ]]; then export ARM_CLIENT_ID="$AZURE_CLIENT_ID"; fi
  if [[ -n "${AZURE_CLIENT_SECRET:-}" && -z "${ARM_CLIENT_SECRET:-}" ]]; then export ARM_CLIENT_SECRET="$AZURE_CLIENT_SECRET"; fi

  # Map WireGuard secrets to Terraform variables.
  if [[ -n "${WG_AWS_PRIVATE_KEY:-}" ]]; then export TF_VAR_wg_aws_private_key="$WG_AWS_PRIVATE_KEY"; fi
  if [[ -n "${WG_AWS_PUBLIC_KEY:-}" ]]; then export TF_VAR_wg_aws_public_key="$WG_AWS_PUBLIC_KEY"; fi
  if [[ -n "${WG_AZURE_PRIVATE_KEY:-}" ]]; then export TF_VAR_wg_azure_private_key="$WG_AZURE_PRIVATE_KEY"; fi
  if [[ -n "${WG_AZURE_PUBLIC_KEY:-}" ]]; then export TF_VAR_wg_azure_public_key="$WG_AZURE_PUBLIC_KEY"; fi
  if [[ -n "${WG_GCP_PRIVATE_KEY:-}" ]]; then export TF_VAR_wg_gcp_private_key="$WG_GCP_PRIVATE_KEY"; fi
  if [[ -n "${WG_GCP_PUBLIC_KEY:-}" ]]; then export TF_VAR_wg_gcp_public_key="$WG_GCP_PUBLIC_KEY"; fi
  if [[ -n "${WG_PSK_AWS_AZURE:-}" ]]; then export TF_VAR_wg_psk_aws_azure="$WG_PSK_AWS_AZURE"; fi
  if [[ -n "${WG_PSK_AWS_GCP:-}" ]]; then export TF_VAR_wg_psk_aws_gcp="$WG_PSK_AWS_GCP"; fi
  if [[ -n "${WG_PSK_AZURE_GCP:-}" ]]; then export TF_VAR_wg_psk_azure_gcp="$WG_PSK_AZURE_GCP"; fi

  # Required Terraform vars: GCP project + an SSH public key for the Azure VM.
  if [[ -n "${GCP_PROJECT:-}" && -z "${TF_VAR_gcp_project:-}" ]]; then export TF_VAR_gcp_project="$GCP_PROJECT"; fi
  if [[ -n "${SSH_PUBLIC_KEY:-}" && -z "${TF_VAR_ssh_public_key:-}" ]]; then export TF_VAR_ssh_public_key="$SSH_PUBLIC_KEY"; fi

  apply_dir "$PROVIDERS_DIR/networking/terraform/us"
  apply_dir "$PROVIDERS_DIR/networking/terraform/eu"
}

main "$@"
