#!/usr/bin/env bash
set -euo pipefail

# Installs Cluster API infrastructure providers for managed clusters:
# - CAPA (AWS/EKS)
# - CAPZ (Azure/AKS)
# - CAPG (GCP/GKE)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-managed-env.py"

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

  if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_MANAGEMENT_PLANE_NAME"; then
    echo "Management kind cluster not found: $CLUSTER_MANAGEMENT_PLANE_NAME" >&2
    echo "Create it first: ./scripts/create-management-plane-capi.sh" >&2
    exit 1
  fi

  local tmp_kubeconfig
  tmp_kubeconfig="$(mktemp)"
  kind get kubeconfig --name "$CLUSTER_MANAGEMENT_PLANE_NAME" >"$tmp_kubeconfig"

  echo "Installing managed-cluster infrastructure providers into $CAPI_MGMT_CONTEXT"
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
