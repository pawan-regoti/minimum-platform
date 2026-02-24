#!/usr/bin/env bash
set -euo pipefail

# Deletes the local kind Cluster API management cluster created by create-management-plane-capi.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_LOCAL_FILE="$PROVIDERS_DIR/config.local.json"
CONFIG_FILE="$PROVIDERS_DIR/config.json"
CONFIG_READER="$PROVIDERS_DIR/utils/read-cluster-management-plane-name.py"

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

  local source_file=""
  if [[ -f "$CONFIG_LOCAL_FILE" ]]; then
    source_file="$CONFIG_LOCAL_FILE"
  elif [[ -f "$CONFIG_FILE" ]]; then
    source_file="$CONFIG_FILE"
  fi

  if [[ -n "$source_file" ]]; then
    require_cmd python3
    CLUSTER_MANAGEMENT_PLANE_NAME="$(python3 "$CONFIG_READER" "$source_file")"
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
