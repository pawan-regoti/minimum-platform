#!/usr/bin/env bash
set -euo pipefail

# Installs Cluster API infrastructure providers for managed clusters:
# - CAPA (AWS/EKS)
# - CAPZ (Azure/AKS)
# - CAPG (GCP/GKE)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

main() {
  require_cmd kind
  require_cmd kubectl
  require_cmd clusterctl
  require_cmd python3

  if [[ ! -f "$ENV_EMITTER" ]]; then
    echo "Missing env emitter: $ENV_EMITTER" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  # Canonical config comes from CONFIG_*; keep old env override compatible.
  MGMT_NAME="${CLUSTER_MANAGEMENT_PLANE_NAME:-${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}}"
  MGMT_CONTEXT="kind-${MGMT_NAME}"

  preflight_missing=0

  check_required() {
    local provider="$1"
    shift
    local missing=()
    local var
    for var in "$@"; do
      # Indirect expansion; treat unset as empty.
      if [[ -z "${!var:-}" ]]; then
        missing+=("$var")
      fi
    done

    if (( ${#missing[@]} > 0 )); then
      preflight_missing=1
      echo "" >&2
      echo "Missing required credentials for $provider:" >&2
      for var in "${missing[@]}"; do
        echo "  - $var" >&2
      done
    fi
  }

  echo "Preflight: checking provider credentials (from env or config.local.json secrets)" >&2
  check_required "CAPA (aws)" AWS_B64ENCODED_CREDENTIALS
  check_required "CAPZ (azure)" AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET
  check_required "CAPG (gcp)" GCP_B64ENCODED_CREDENTIALS GCP_PROJECT

  if (( preflight_missing != 0 )); then
    echo "" >&2
    echo "Set the missing variables as environment variables, or put them under 'secrets' in config.local.json so utils/emit-envs.py exports them." >&2
    echo "Examples:" >&2
    echo "  AWS_B64ENCODED_CREDENTIALS: base64 of your AWS credentials file" >&2
    echo "    macOS:  base64 -i ~/.aws/credentials" >&2
    echo "    Linux:  base64 -w0 ~/.aws/credentials" >&2
    echo "  GCP_B64ENCODED_CREDENTIALS: base64 of a service account JSON key" >&2
    echo "    macOS:  base64 -i /path/to/key.json" >&2
    echo "    Linux:  base64 -w0 /path/to/key.json" >&2
    echo "" >&2
    exit 1
  fi

  if ! kind get clusters 2>/dev/null | grep -qx "$MGMT_NAME"; then
    echo "Management kind cluster not found: $MGMT_NAME" >&2
    echo "Create it first: ./scripts/create-management-plane-capi.sh" >&2
    exit 1
  fi

  local tmp_kubeconfig
  tmp_kubeconfig="$(mktemp)"
  kind get kubeconfig --name "$MGMT_NAME" >"$tmp_kubeconfig"

  echo "Installing managed-cluster infrastructure providers into $MGMT_CONTEXT"
  echo "  - aws (CAPA)"
  echo "  - azure (CAPZ)"
  echo "  - gcp (CAPG)"

  # This may re-apply core providers; clusterctl is generally safe to re-run.
  clusterctl init \
    --kubeconfig "$tmp_kubeconfig" \
    --infrastructure aws \
    --infrastructure azure \
    --infrastructure gcp

  rm -f "$tmp_kubeconfig"

  echo "Providers installed. You can list flavors with: clusterctl generate cluster --list-flavors"
}

main "$@"
