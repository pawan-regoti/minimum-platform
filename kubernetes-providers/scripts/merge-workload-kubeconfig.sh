#!/usr/bin/env bash
set -euo pipefail

# Merge one or more WORKLOAD cluster kubeconfigs (fetched via clusterctl) into
# the user's default kubeconfig at ~/.kube/config.
#
# Usage:
#   ./scripts/merge-workload-kubeconfig.sh                 # merges all workload cluster names from config.json patterns
#   ./scripts/merge-workload-kubeconfig.sh <name> [...]    # merges specific clusters

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"
JSON_ARRAY_TO_WORDS="$PROVIDERS_DIR/utils/json-array-to-words.py"
MERGE_HELPER="$PROVIDERS_DIR/scripts/merge-kubeconfigs-into-home.sh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

normalize_kubeconfig_context_name() {
  local kubeconfig_path="$1"
  local desired_context="$2"

  # clusterctl get kubeconfig often produces context names like:
  #   <cluster>-admin@<cluster>
  # but we want the merged context name to be exactly <cluster>.

  local contexts
  contexts="$(kubectl --kubeconfig "$kubeconfig_path" config get-contexts -o name 2>/dev/null || true)"
  [[ -z "${contexts:-}" ]] && return 0

  # If the desired context already exists, just make it current.
  if printf '%s\n' "$contexts" | grep -qx "$desired_context"; then
    kubectl --kubeconfig "$kubeconfig_path" config use-context "$desired_context" >/dev/null 2>&1 || true
    return 0
  fi

  # If there is exactly one context, rename it.
  local count
  count="$(printf '%s\n' "$contexts" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    local old
    old="$(printf '%s\n' "$contexts" | sed '/^$/d' | head -n 1)"
    if [[ -n "${old:-}" && "$old" != "$desired_context" ]]; then
      kubectl --kubeconfig "$kubeconfig_path" config rename-context "$old" "$desired_context" >/dev/null 2>&1 || true
      kubectl --kubeconfig "$kubeconfig_path" config use-context "$desired_context" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  # Multiple contexts: try to pick the one that targets this cluster.
  local match
  match="$(printf '%s\n' "$contexts" | grep -E "@${desired_context}$" | head -n 1 || true)"
  if [[ -n "${match:-}" ]]; then
    kubectl --kubeconfig "$kubeconfig_path" config rename-context "$match" "$desired_context" >/dev/null 2>&1 || true
    kubectl --kubeconfig "$kubeconfig_path" config use-context "$desired_context" >/dev/null 2>&1 || true
  fi
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

wait_for_workload_ready() {
  local mgmt_kubeconfig="$1"
  local name="$2"
  local namespace="$3"

  local timeout_seconds="${WORKLOAD_READY_TIMEOUT_SECONDS:-900}"
  local start
  start="$(date +%s)"

  local api_version
  api_version="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.apiVersion}' 2>/dev/null || true)"

  # CAPI v1beta2 Cluster uses Available instead of Ready.
  local success_condition_type="Ready"
  if [[ "$api_version" == *"/v1beta2" ]]; then
    success_condition_type="Available"
  fi

  echo "Waiting for workload cluster ${success_condition_type}=True: $namespace/$name" >&2

  local poll=0

  while true; do
    poll=$((poll + 1))
    # Cluster success condition
    local success_status
    success_status="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" \
      -o jsonpath="{.status.conditions[?(@.type==\"$success_condition_type\")].status}" 2>/dev/null || true)"

    # Fail fast if the Cluster has surfaced a terminal error.
    local failure_reason failure_message
    failure_reason="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.failureReason}' 2>/dev/null || true)"
    failure_message="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.failureMessage}' 2>/dev/null || true)"
    if [[ -n "${failure_reason:-}" || -n "${failure_message:-}" ]]; then
      echo "Workload cluster reported a failure: $namespace/$name" >&2
      [[ -n "${failure_reason:-}" ]] && echo "  failureReason: $failure_reason" >&2
      [[ -n "${failure_message:-}" ]] && echo "  failureMessage: $failure_message" >&2
      return 1
    fi

    # CAPD bootstrap errors can prevent Ready from ever becoming True.
    # Detect them early so the caller doesn't just wait for the full timeout.
    if (( poll % 3 == 0 )); then
      local dm_lines dm_failure
      dm_lines="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get dockermachines \
        -l "cluster.x-k8s.io/cluster-name=$name" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="BootstrapExecSucceeded")].status}{"\t"}{.status.conditions[?(@.type=="BootstrapExecSucceeded")].reason}{"\t"}{.status.conditions[?(@.type=="BootstrapExecSucceeded")].message}{"\n"}{end}' 2>/dev/null || true)"
      dm_failure="$(printf '%s\n' "$dm_lines" | awk -F '\t' '$2=="False"{print; exit}')"
      if [[ -n "${dm_failure:-}" ]]; then
        echo "Workload bootstrap failed (DockerMachine BootstrapExecSucceeded=False):" >&2
        echo "  $dm_failure" >&2
        return 1
      fi

      local dm_container_lines dm_container_failure
      dm_container_lines="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get dockermachines \
        -l "cluster.x-k8s.io/cluster-name=$name" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="ContainerProvisioned")].status}{"\t"}{.status.conditions[?(@.type=="ContainerProvisioned")].reason}{"\t"}{.status.conditions[?(@.type=="ContainerProvisioned")].message}{"\n"}{end}' 2>/dev/null || true)"
      dm_container_failure="$(printf '%s\n' "$dm_container_lines" | awk -F '\t' '$2=="False" && ($3=="ContainerDeleted" || $4 ~ /does not exist/){print; exit}')"
      if [[ -n "${dm_container_failure:-}" ]]; then
        echo "Workload node container missing (DockerMachine ContainerProvisioned=False):" >&2
        echo "  $dm_container_failure" >&2
        return 1
      fi
    fi

    # Emit a small progress line periodically so this doesn't look hung.
    if (( poll % 6 == 0 )); then
      local phase infra cpinit workers remote cpavail
      phase="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      infra="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="InfrastructureReady")].status}' 2>/dev/null || true)"
      cpinit="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="ControlPlaneInitialized")].status}' 2>/dev/null || true)"
      workers="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="WorkersAvailable")].status}' 2>/dev/null || true)"

      remote="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="RemoteConnectionProbe")].status}' 2>/dev/null || true)"
      cpavail="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="ControlPlaneAvailable")].status}' 2>/dev/null || true)"

      echo "  status: phase=${phase:-?} ${success_condition_type}=${success_status:-?} Infra=${infra:-?} CPInit=${cpinit:-?} Workers=${workers:-?} Remote=${remote:-?} CPAvail=${cpavail:-?}" >&2
    fi

    if [[ "$success_status" == "True" ]]; then
      # clusterctl get kubeconfig relies on a Secret named <cluster>-kubeconfig.
      if kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get secret "${name}-kubeconfig" >/dev/null 2>&1; then
        return 0
      fi
    fi

    local now
    now="$(date +%s)"
    if (( now - start > timeout_seconds )); then
      echo "Timed out waiting for ${success_condition_type}=True and ${name}-kubeconfig Secret (timeout=${timeout_seconds}s)." >&2
      echo "Debug:" >&2
      echo "  kubectl --kubeconfig $mgmt_kubeconfig -n $namespace get cluster $name -o yaml" >&2
      echo "  kubectl --kubeconfig $mgmt_kubeconfig -n $namespace get secret ${name}-kubeconfig" >&2
      return 1
    fi

    sleep 5
  done
}

compute_default_clusters() {
  local aws_regions azure_locations gcp_regions
  local aws_pattern azure_pattern gcp_pattern

  aws_regions="$(python3 "$JSON_ARRAY_TO_WORDS" "${CONFIG_MANAGED_CLUSTERS_AWS_REGIONS:-[]}")"
  azure_locations="$(python3 "$JSON_ARRAY_TO_WORDS" "${CONFIG_MANAGED_CLUSTERS_AZURE_LOCATIONS:-[]}")"
  gcp_regions="$(python3 "$JSON_ARRAY_TO_WORDS" "${CONFIG_MANAGED_CLUSTERS_GCP_REGIONS:-[]}")"

  aws_pattern="${CONFIG_MANAGED_CLUSTERS_AWS_CLUSTER_NAME_PATTERN:-eks-<region>-1}"
  azure_pattern="${CONFIG_MANAGED_CLUSTERS_AZURE_CLUSTER_NAME_PATTERN:-aks-<region>-1}"
  gcp_pattern="${CONFIG_MANAGED_CLUSTERS_GCP_CLUSTER_NAME_PATTERN:-gke-<region>-1}"

  local out=()
  local region
  for region in $aws_regions; do
    out+=("$(render_name "$aws_pattern" "$region")")
  done
  local loc
  for loc in $azure_locations; do
    out+=("$(render_name "$azure_pattern" "$loc")")
  done
  for region in $gcp_regions; do
    out+=("$(render_name "$gcp_pattern" "$region")")
  done

  printf '%s\n' "${out[@]}"
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
  if [[ ! -f "$MERGE_HELPER" ]]; then
    echo "Missing kubeconfig merge helper: $MERGE_HELPER" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  local mgmt_name
  mgmt_name="${CLUSTER_MANAGEMENT_PLANE_NAME:-${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}}"

  if ! kind get clusters 2>/dev/null | grep -qx "$mgmt_name"; then
    echo "Management kind cluster not found: $mgmt_name" >&2
    echo "Create it first: ./scripts/create-management-plane-capi.sh" >&2
    exit 1
  fi

  local clusters=()
  if (( $# > 0 )); then
    clusters=("$@")
  else
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      clusters+=("$name")
    done < <(compute_default_clusters)
  fi

  if (( ${#clusters[@]} == 0 )); then
    echo "No workload clusters found in config to merge." >&2
    exit 0
  fi

  local tmp_mgmt_kubeconfig
  tmp_mgmt_kubeconfig="$(mktemp)"
  trap "rm -f '$tmp_mgmt_kubeconfig'" EXIT
  kind get kubeconfig --name "$mgmt_name" >"$tmp_mgmt_kubeconfig"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" EXIT

  local name
  local kubeconfigs=()
  for name in "${clusters[@]}"; do
    local out="$tmp_dir/${name}.kubeconfig"

    local ns
    ns="$(find_cluster_namespace "$tmp_mgmt_kubeconfig" "$name")"
    if [[ -z "$ns" ]]; then
      echo "Workload cluster not found in management plane: $name" >&2
      echo "Tip: kubectl --kubeconfig $tmp_mgmt_kubeconfig get clusters -A" >&2
      exit 1
    fi

    wait_for_workload_ready "$tmp_mgmt_kubeconfig" "$name" "$ns"

    echo "Fetching kubeconfig for workload cluster: $name" >&2
    if ! clusterctl get kubeconfig "$name" --kubeconfig "$tmp_mgmt_kubeconfig" >"$out"; then
      echo "Failed to fetch kubeconfig for $name" >&2
      exit 1
    fi

    normalize_kubeconfig_context_name "$out" "$name"
    kubeconfigs+=("$out")
  done

  bash "$MERGE_HELPER" "${kubeconfigs[@]}"
}

main "$@"
