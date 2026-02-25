#!/usr/bin/env bash
set -euo pipefail

# Deletes LOCAL workload clusters created by create-local-clusters.sh.

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

find_cluster_namespace() {
  local mgmt_kubeconfig="$1"
  local name="$2"

  kubectl --kubeconfig "$mgmt_kubeconfig" get clusters -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
    | awk -v n="$name" '$2==n{print $1; exit}'
}

delete_one() {
  local name="$1"
  local mgmt_kubeconfig="$2"

  local ns
  ns="$(find_cluster_namespace "$mgmt_kubeconfig" "$name")"
  if [[ -z "$ns" ]]; then
    return 0
  fi

  echo "Deleting Cluster API object: $ns/$name"
  kubectl --kubeconfig "$mgmt_kubeconfig" -n "$ns" delete cluster "$name" --ignore-not-found
}

delete_kind_cluster_if_exists() {
  local name="$1"

  if kind get clusters 2>/dev/null | grep -qx "$name"; then
    echo "Deleting kind workload cluster: $name" >&2
    kind delete cluster --name "$name" >/dev/null
  fi
}

delete_stale_kind_clusters_by_prefixes() {
  local mgmt_name="$1"
  shift || true

  local prefixes=()
  local p
  for p in "$@"; do
    [[ -z "${p:-}" ]] && continue
    prefixes+=("$p")
  done

  if (( ${#prefixes[@]} == 0 )); then
    return 0
  fi

  # Best-effort: delete any kind cluster (except the management plane) whose
  # name starts with one of the known workload prefixes (e.g. eks-/aks-/gke-).
  local clusters
  clusters="$(kind get clusters 2>/dev/null || true)"
  [[ -z "${clusters:-}" ]] && return 0

  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$name" == "$mgmt_name" ]] && continue

    local match="false"
    for p in "${prefixes[@]}"; do
      if [[ "$name" == "${p}"* ]]; then
        match="true"
        break
      fi
    done

    if [[ "$match" == "true" ]]; then
      delete_kind_cluster_if_exists "$name"
    fi
  done <<<"$clusters"
}

list_docker_backed_clusters_from_mgmt() {
  local mgmt_kubeconfig="$1"

  # Print names of Cluster API Clusters which use DockerCluster infrastructure.
  kubectl --kubeconfig "$mgmt_kubeconfig" get clusters -A \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.infrastructureRef.kind}{"\n"}{end}' \
    | awk -F '\t' '$2=="DockerCluster"{print $1}'
}

main() {
  require_cmd kind
  require_cmd kubectl
  require_cmd python3

  if [[ ! -f "$JSON_ARRAY_TO_WORDS" ]]; then
    echo "Missing JSON helper: $JSON_ARRAY_TO_WORDS" >&2
    exit 1
  fi

  if [[ ! -f "$ENV_EMITTER" ]]; then
    echo "Missing env emitter: $ENV_EMITTER" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  MGMT_NAME="${CLUSTER_MANAGEMENT_PLANE_NAME:-${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}}"

  AWS_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AWS_REGIONS:-[]}")"
  AWS_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AWS_CLUSTER_NAME_PATTERN:-eks-<region>-1}"
  AWS_PREFIX="${AWS_NAME_PATTERN%%<region>*}"

  AZURE_LOCATIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_AZURE_LOCATIONS:-[]}")"
  AZURE_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_AZURE_CLUSTER_NAME_PATTERN:-aks-<region>-1}"
  AZURE_PREFIX="${AZURE_NAME_PATTERN%%<region>*}"

  GCP_REGIONS="$(json_array_to_words "${CONFIG_MANAGED_CLUSTERS_GCP_REGIONS:-[]}")"
  GCP_NAME_PATTERN="${CONFIG_MANAGED_CLUSTERS_GCP_CLUSTER_NAME_PATTERN:-gke-<region>-1}"
  GCP_PREFIX="${GCP_NAME_PATTERN%%<region>*}"

  if ! kind get clusters 2>/dev/null | grep -qx "$MGMT_NAME"; then
    echo "Management kind cluster not found: $MGMT_NAME" >&2
    echo "Deleting kind workload clusters derived from config (best-effort)..." >&2

    for region in $AWS_REGIONS; do
      delete_kind_cluster_if_exists "$(render_name "$AWS_NAME_PATTERN" "$region")"
    done
    for location in $AZURE_LOCATIONS; do
      delete_kind_cluster_if_exists "$(render_name "$AZURE_NAME_PATTERN" "$location")"
    done
    for region in $GCP_REGIONS; do
      delete_kind_cluster_if_exists "$(render_name "$GCP_NAME_PATTERN" "$region")"
    done

    delete_stale_kind_clusters_by_prefixes "$MGMT_NAME" "$AWS_PREFIX" "$AZURE_PREFIX" "$GCP_PREFIX"

    exit 0
  fi

  local tmp_kubeconfig
  tmp_kubeconfig="$(mktemp)"
  # Don't reference a local var in an EXIT trap under `set -u`.
  trap "rm -f '$tmp_kubeconfig'" EXIT
  kind get kubeconfig --name "$MGMT_NAME" >"$tmp_kubeconfig"

  # Delete the union of:
  # - Docker-backed clusters currently known to the management plane
  # - clusters derived from config patterns (helps delete stale kind clusters)
  local docker_backed config_derived all_names
  docker_backed="$(list_docker_backed_clusters_from_mgmt "$tmp_kubeconfig" || true)"

  config_derived=""
  for region in $AWS_REGIONS; do
    config_derived+="$(render_name "$AWS_NAME_PATTERN" "$region")"$'\n'
  done
  for location in $AZURE_LOCATIONS; do
    config_derived+="$(render_name "$AZURE_NAME_PATTERN" "$location")"$'\n'
  done
  for region in $GCP_REGIONS; do
    config_derived+="$(render_name "$GCP_NAME_PATTERN" "$region")"$'\n'
  done

  all_names="${docker_backed:-}$'\n'${config_derived:-}"

  printf '%s\n' "$all_names" \
    | sed '/^$/d' \
    | sort -u \
    | while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        delete_one "$name" "$tmp_kubeconfig"
        delete_kind_cluster_if_exists "$name"
      done

  # Also delete any leftover kind workload clusters matching the known prefixes.
  delete_stale_kind_clusters_by_prefixes "$MGMT_NAME" "$AWS_PREFIX" "$AZURE_PREFIX" "$GCP_PREFIX"

  exit 0
}

main "$@"
