#!/usr/bin/env bash
set -euo pipefail

# Creates LOCAL workload clusters using the CAPI management plane + CAPD (Docker).
#
# This is a stand-in for EKS/AKS/GKE when you don't have cloud accounts.
# Clusters are named using the same patterns from config.json, e.g.:
#   eks-us-east-1-1, aks-eastus-1, gke-us-east4-1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"
CAPD_TEMPLATE="$PROVIDERS_DIR/manifests/capd/cluster-template.yaml"
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

create_one() {
  local name="$1"
  local kube_version="$2"
  local mgmt_kubeconfig="$3"

  echo "Applying local cluster: $name (infrastructure=docker, version=$kube_version)"
  clusterctl generate cluster "$name" \
    --from "$CAPD_TEMPLATE" \
    --kubeconfig "$mgmt_kubeconfig" \
    --kubernetes-version "$kube_version" \
    --control-plane-machine-count 1 \
    --worker-machine-count 1 \
    | kubectl --kubeconfig "$mgmt_kubeconfig" apply -f -
}

wait_for_webhooks() {
  local mgmt_kubeconfig="$1"

  # Creating workload objects can trigger conversion/admission webhooks.
  # If we race them, the API server returns connection refused.
  local urls=(
    "https://capi-webhook-service.capi-system.svc:443/"
    "https://capi-kubeadm-bootstrap-webhook-service.capi-kubeadm-bootstrap-system.svc:443/"
    "https://capi-kubeadm-control-plane-webhook-service.capi-kubeadm-control-plane-system.svc:443/"
    "https://capd-webhook-service.capd-system.svc:443/"
  )

  echo "Waiting for CAPI/CAPD webhooks to be reachable..." >&2

  local attempt
  for attempt in {1..30}; do
    if kubectl --kubeconfig "$mgmt_kubeconfig" run capi-webhook-check \
      --rm -i --restart=Never \
      --image=curlimages/curl:8.5.0 \
      --command -- sh -c "set -e; for u in ${urls[*]}; do curl -sk -m 5 -o /dev/null \"\$u\"; done" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Timed out waiting for webhooks. Check provider pods:" >&2
  echo "  kubectl --kubeconfig $mgmt_kubeconfig -n capd-system get pods" >&2
  echo "  kubectl --kubeconfig $mgmt_kubeconfig -n capi-system get pods" >&2
  echo "  kubectl --kubeconfig $mgmt_kubeconfig -n capi-kubeadm-bootstrap-system get pods" >&2
  echo "  kubectl --kubeconfig $mgmt_kubeconfig -n capi-kubeadm-control-plane-system get pods" >&2
  return 1
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

  if [[ ! -f "$JSON_ARRAY_TO_WORDS" ]]; then
    echo "Missing JSON helper: $JSON_ARRAY_TO_WORDS" >&2
    exit 1
  fi

  if [[ ! -f "$CAPD_TEMPLATE" ]]; then
    echo "Missing CAPD workload cluster template: $CAPD_TEMPLATE" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  MGMT_NAME="${CLUSTER_MANAGEMENT_PLANE_NAME:-${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}}"
  KUBE_VERSION="${CONFIG_MANAGED_CLUSTERS_KUBERNETES_VERSION:-v1.29.0}"

  AWS_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AWS_REGIONS:-[]}")"
  AWS_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AWS_CLUSTER_NAME_PATTERN:-eks-<region>-1}"

  AZURE_LOCATIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AZURE_LOCATIONS:-[]}")"
  AZURE_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AZURE_CLUSTER_NAME_PATTERN:-aks-<region>-1}"

  GCP_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_GCP_REGIONS:-[]}")"
  GCP_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_GCP_CLUSTER_NAME_PATTERN:-gke-<region>-1}"

  if ! kind get clusters 2>/dev/null | grep -qx "$MGMT_NAME"; then
    echo "Management kind cluster not found: $MGMT_NAME" >&2
    echo "Create it first: ./scripts/create-management-plane-capi.sh" >&2
    exit 1
  fi

  local tmp_kubeconfig
  tmp_kubeconfig="$(mktemp)"
  # Don't reference a local var in an EXIT trap under `set -u`.
  trap "rm -f '$tmp_kubeconfig'" EXIT
  kind get kubeconfig --name "$MGMT_NAME" >"$tmp_kubeconfig"

  wait_for_webhooks "$tmp_kubeconfig"

  echo "Creating local workload clusters from management plane: kind-$MGMT_NAME"

  for region in $AWS_REGIONS; do
    name="$(render_name "$AWS_NAME_PATTERN" "$region")"
    create_one "$name" "$KUBE_VERSION" "$tmp_kubeconfig"
  done

  for location in $AZURE_LOCATIONS; do
    name="$(render_name "$AZURE_NAME_PATTERN" "$location")"
    create_one "$name" "$KUBE_VERSION" "$tmp_kubeconfig"
  done

  for region in $GCP_REGIONS; do
    name="$(render_name "$GCP_NAME_PATTERN" "$region")"
    create_one "$name" "$KUBE_VERSION" "$tmp_kubeconfig"
  done

  echo "Submitted all local clusters. Watch provisioning with:"
  echo "  kind get kubeconfig --name $MGMT_NAME > /tmp/mgmt.kubeconfig"
  echo "  kubectl --kubeconfig /tmp/mgmt.kubeconfig get clusters -A"
  echo "  kubectl --kubeconfig /tmp/mgmt.kubeconfig get machines -A"
  echo "Get a workload kubeconfig (once ready) with:"
  echo "  clusterctl get kubeconfig <cluster-name> --kubeconfig /tmp/mgmt.kubeconfig > <cluster-name>.kubeconfig"
}

main "$@"
