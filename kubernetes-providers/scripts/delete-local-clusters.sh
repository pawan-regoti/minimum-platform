#!/usr/bin/env bash
set -euo pipefail

# Deletes LOCAL workload clusters created by create-local-clusters.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"

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

  python3 - <<'PY' "$json_array"
import json
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    data = []

if isinstance(data, list):
    parts = [str(x).strip() for x in data if str(x).strip()]
    if parts:
        sys.stdout.write(" ".join(parts))
PY
}

render_name() {
  local pattern="$1"
  local region="$2"
  echo "${pattern//<region>/$region}"
}

delete_one() {
  local name="$1"
  local mgmt_kubeconfig="$2"

  echo "Deleting Cluster API object: $name"
  kubectl --kubeconfig "$mgmt_kubeconfig" delete cluster "$name" --ignore-not-found
}

main() {
  require_cmd kind
  require_cmd kubectl
  require_cmd python3

  if [[ ! -f "$ENV_EMITTER" ]]; then
    echo "Missing env emitter: $ENV_EMITTER" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  MGMT_NAME="${CLUSTER_MANAGEMENT_PLANE_NAME:-${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}}"

  AWS_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AWS_REGIONS:-[]}")"
  AWS_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AWS_CLUSTER_NAME_PATTERN:-eks-<region>-1}"

  AZURE_LOCATIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AZURE_LOCATIONS:-[]}")"
  AZURE_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AZURE_CLUSTER_NAME_PATTERN:-aks-<region>-1}"

  GCP_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_GCP_REGIONS:-[]}")"
  GCP_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_GCP_CLUSTER_NAME_PATTERN:-gke-<region>-1}"

  if ! kind get clusters 2>/dev/null | grep -qx "$MGMT_NAME"; then
    echo "Management kind cluster not found: $MGMT_NAME" >&2
    echo "Nothing to delete (management plane is missing)." >&2
    exit 0
  fi

  local tmp_kubeconfig
  tmp_kubeconfig="$(mktemp)"
  trap 'rm -f "$tmp_kubeconfig"' EXIT
  kind get kubeconfig --name "$MGMT_NAME" >"$tmp_kubeconfig"

  for region in $AWS_REGIONS; do
    delete_one "$(render_name "$AWS_NAME_PATTERN" "$region")" "$tmp_kubeconfig"
  done
  for location in $AZURE_LOCATIONS; do
    delete_one "$(render_name "$AZURE_NAME_PATTERN" "$location")" "$tmp_kubeconfig"
  done
  for region in $GCP_REGIONS; do
    delete_one "$(render_name "$GCP_NAME_PATTERN" "$region")" "$tmp_kubeconfig"
  done
}

main "$@"
