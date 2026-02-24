#!/usr/bin/env bash
set -euo pipefail

# Deletes the local kind Cluster API management cluster created by create-management-plane-capi.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

load_config_if_needed() {
  if [[ -n "${CLUSTER_MANAGEMENT_PLANE_NAME:-}" ]]; then
    return 0
  fi

  if [[ ! -f "$ENV_EMITTER" ]]; then
    echo "Missing env emitter: $ENV_EMITTER" >&2
    exit 1
  fi

  require_cmd python3
  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  if [[ -z "${CLUSTER_MANAGEMENT_PLANE_NAME:-}" ]]; then
    CLUSTER_MANAGEMENT_PLANE_NAME="${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-}"
  fi
}

load_config_if_needed

MGMT_CLUSTER_NAME="${CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}"

kind_cluster_exists() {
  local name="$1"
  kind get clusters 2>/dev/null | grep -qx "$name"
}

main() {
  require_cmd kind

  if kind_cluster_exists "$MGMT_CLUSTER_NAME"; then
    echo "Deleting kind cluster: $MGMT_CLUSTER_NAME"
    kind delete cluster --name "$MGMT_CLUSTER_NAME"
  else
    echo "Skipping (not found): $MGMT_CLUSTER_NAME"
  fi
}

main "$@"
