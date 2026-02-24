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

  echo "Applying cluster: $name (flavor=$flavor, version=$kube_version)"
  clusterctl generate cluster "$name" \
    --flavor "$flavor" \
    --kubernetes-version "$kube_version" \
    | kubectl --context "$CAPI_MGMT_CONTEXT" apply -f -
}

main() {
  require_cmd kubectl
  require_cmd clusterctl
  require_cmd python3

  if [[ ! -f "$ENV_EMITTER" ]]; then
    echo "Missing env emitter: $ENV_EMITTER" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  ensure_flavor_set "$MANAGED_AWS_FLAVOR" "AWS"
  ensure_flavor_set "$MANAGED_AZURE_FLAVOR" "Azure"
  ensure_flavor_set "$MANAGED_GCP_FLAVOR" "GCP"

  # EKS
  for region in $MANAGED_AWS_REGIONS; do
    export AWS_REGION="$region"
    name="$(render_name "$MANAGED_AWS_NAME_PATTERN" "$region")"
    create_one "$name" "$MANAGED_AWS_FLAVOR" "$MANAGED_KUBERNETES_VERSION"
  done

  # AKS
  for location in $MANAGED_AZURE_LOCATIONS; do
    export AZURE_LOCATION="$location"
    name="$(render_name "$MANAGED_AZURE_NAME_PATTERN" "$location")"
    create_one "$name" "$MANAGED_AZURE_FLAVOR" "$MANAGED_KUBERNETES_VERSION"
  done

  # GKE
  for region in $MANAGED_GCP_REGIONS; do
    export GCP_REGION="$region"
    name="$(render_name "$MANAGED_GCP_NAME_PATTERN" "$region")"
    create_one "$name" "$MANAGED_GCP_FLAVOR" "$MANAGED_KUBERNETES_VERSION"
  done

  echo "Submitted all managed clusters. Watch status with: kubectl --context $CAPI_MGMT_CONTEXT get clusters -A"
}

main "$@"
