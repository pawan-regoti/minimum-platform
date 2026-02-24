#!/usr/bin/env bash
set -euo pipefail

# Deletes the managed clusters created by create-managed-clusters.sh from the management cluster.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-managed-env.py"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

render_name() {
  local pattern="$1"
  local region="$2"
  echo "${pattern//<region>/$region}"
}

delete_one() {
  local name="$1"
  echo "Deleting Cluster API object: $name"
  kubectl --context "$CAPI_MGMT_CONTEXT" delete cluster "$name" --ignore-not-found
}

main() {
  require_cmd kubectl
  require_cmd python3

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  for region in $MANAGED_AWS_REGIONS; do
    delete_one "$(render_name "$MANAGED_AWS_NAME_PATTERN" "$region")"
  done
  for location in $MANAGED_AZURE_LOCATIONS; do
    delete_one "$(render_name "$MANAGED_AZURE_NAME_PATTERN" "$location")"
  done
  for region in $MANAGED_GCP_REGIONS; do
    delete_one "$(render_name "$MANAGED_GCP_NAME_PATTERN" "$region")"
  done
}

main "$@"
