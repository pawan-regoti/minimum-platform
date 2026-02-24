#!/usr/bin/env bash
set -euo pipefail

# Deletes the managed clusters created by create-managed-clusters.sh from the management cluster.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"
JSON_ARRAY_TO_WORDS="$PROVIDERS_DIR/utils/json-array-to-words.py"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

json_array_to_words() {
  local json_array="${1:-}"

  if [[ -z "$json_array" ]]; then
    return 0
  fi

  python3 "$JSON_ARRAY_TO_WORDS" "$json_array"
}

render_name() {
  local pattern="$1"
  local region="$2"
  echo "${pattern//<region>/$region}"
}

delete_one() {
  local name="$1"
  echo "Deleting Cluster API object: $name"
  kubectl --context "$MGMT_CONTEXT" delete cluster "$name" --ignore-not-found
}

main() {
  require_cmd kubectl
  require_cmd python3

  if [[ ! -f "$JSON_ARRAY_TO_WORDS" ]]; then
    echo "Missing JSON helper: $JSON_ARRAY_TO_WORDS" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  MGMT_CONTEXT="kind-${CLUSTER_MANAGEMENT_PLANE_NAME:-${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}}"

  AWS_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AWS_REGIONS:-[]}")"
  AWS_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AWS_CLUSTER_NAME_PATTERN:-eks-<region>-1}"

  AZURE_LOCATIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AZURE_LOCATIONS:-[]}")"
  AZURE_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AZURE_CLUSTER_NAME_PATTERN:-aks-<region>-1}"

  GCP_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_GCP_REGIONS:-[]}")"
  GCP_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_GCP_CLUSTER_NAME_PATTERN:-gke-<region>-1}"

  for region in $AWS_REGIONS; do
    delete_one "$(render_name "$AWS_NAME_PATTERN" "$region")"
  done
  for location in $AZURE_LOCATIONS; do
    delete_one "$(render_name "$AZURE_NAME_PATTERN" "$location")"
  done
  for region in $GCP_REGIONS; do
    delete_one "$(render_name "$GCP_NAME_PATTERN" "$region")"
  done
}

main "$@"
