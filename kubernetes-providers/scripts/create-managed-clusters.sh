#!/usr/bin/env bash
set -euo pipefail

# Creates managed workload clusters in EKS, AKS, and GKE from the local CAPI management cluster.
#
# IMPORTANT:
# - You must run ./scripts/init-managed-providers.sh first.
# - You must set the managed flavors in config.local.json or config.json (default: CHANGE_ME).
# - You must provide cloud credentials. Per your preference, you can put secrets in config.local.json
#   under a `secrets` object with keys like AWS_ACCESS_KEY_ID, AZURE_SUBSCRIPTION_ID, etc.

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

ensure_flavor_set() {
  local value="$1"
  local label="$2"
  if [[ -z "$value" || "$value" == "CHANGE_ME" ]]; then
    echo "Missing $label flavor. Set it in config.local.json or config.json (managedClusters.*.flavor)." >&2
    echo "Tip: list available flavors with: clusterctl generate cluster --list-flavors" >&2
    exit 1
  fi
}

create_one() {
  local name="$1"
  local flavor="$2"
  local kube_version="$3"
  local mgmt_context="$4"

  echo "Applying cluster: $name (flavor=$flavor, version=$kube_version)"
  clusterctl generate cluster "$name" \
    --flavor "$flavor" \
    --kubernetes-version "$kube_version" \
    | kubectl --context "$mgmt_context" apply -f -
}

main() {
  require_cmd kubectl
  require_cmd clusterctl
  require_cmd python3

  if [[ ! -f "$ENV_EMITTER" ]]; then
    echo "Missing env emitter: $ENV_EMITTER" >&2
    exit 1
  fi

  if [[ ! -f "$JSON_ARRAY_TO_WORDS" ]]; then
    echo "Missing JSON helper: $JSON_ARRAY_TO_WORDS" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  MGMT_CONTEXT="kind-${CLUSTER_MANAGEMENT_PLANE_NAME:-${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}}"
  KUBE_VERSION="${CONFIG_MANAGED_CLUSTERS_KUBERNETES_VERSION:-v1.29.0}"

  AWS_FLAVOR="${CONFIG_MANAGED_CLUSTERS_AWS_FLAVOR:-CHANGE_ME}"
  AWS_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AWS_REGIONS:-[]}")"
  AWS_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AWS_CLUSTER_NAME_PATTERN:-eks-<region>-1}"

  AZURE_FLAVOR="${CONFIG_MANAGED_CLUSTERS_AZURE_FLAVOR:-CHANGE_ME}"
  AZURE_LOCATIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AZURE_LOCATIONS:-[]}")"
  AZURE_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AZURE_CLUSTER_NAME_PATTERN:-aks-<region>-1}"

  GCP_FLAVOR="${CONFIG_MANAGED_CLUSTERS_GCP_FLAVOR:-CHANGE_ME}"
  GCP_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_GCP_REGIONS:-[]}")"
  GCP_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_GCP_CLUSTER_NAME_PATTERN:-gke-<region>-1}"

  ensure_flavor_set "$AWS_FLAVOR" "AWS"
  ensure_flavor_set "$AZURE_FLAVOR" "Azure"
  ensure_flavor_set "$GCP_FLAVOR" "GCP"

  # EKS
  for region in $AWS_REGIONS; do
    export AWS_REGION="$region"
    name="$(render_name "$AWS_NAME_PATTERN" "$region")"
    create_one "$name" "$AWS_FLAVOR" "$KUBE_VERSION" "$MGMT_CONTEXT"
  done

  # AKS
  for location in $AZURE_LOCATIONS; do
    export AZURE_LOCATION="$location"
    name="$(render_name "$AZURE_NAME_PATTERN" "$location")"
    create_one "$name" "$AZURE_FLAVOR" "$KUBE_VERSION" "$MGMT_CONTEXT"
  done

  # GKE
  for region in $GCP_REGIONS; do
    export GCP_REGION="$region"
    name="$(render_name "$GCP_NAME_PATTERN" "$region")"
    create_one "$name" "$GCP_FLAVOR" "$KUBE_VERSION" "$MGMT_CONTEXT"
  done

  echo "Submitted all managed clusters. Watch status with: kubectl --context $MGMT_CONTEXT get clusters -A"
}

main "$@"
