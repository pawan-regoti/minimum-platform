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
MERGE_WORKLOAD_KUBECONFIG_SCRIPT="$SCRIPT_DIR/merge-workload-kubeconfig.sh"

find_cluster_namespace() {
  local mgmt_kubeconfig="$1"
  local name="$2"

  kubectl --kubeconfig "$mgmt_kubeconfig" get clusters -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
    | awk -v n="$name" '$2==n{print $1; exit}'
}

print_docker_desktop_inotify_help() {
  cat >&2 <<'EOF'
Likely Docker Desktop VM resource exhaustion (inotify / file descriptors).

Mitigations (try in order):
  1) Reduce the number of local workload clusters (fewer regions in config.local.json).
  2) Keep workers disabled (default): LOCAL_WORKER_MACHINE_COUNT=0
  3) Restart Docker Desktop (clears leaked resources).
  4) (Advanced) Temporarily raise inotify limits inside the Docker Desktop VM:
       docker run --rm --privileged alpine:3.19 sh -c \
         'sysctl -w fs.inotify.max_user_instances=8192; sysctl -w fs.inotify.max_user_watches=1048576'

Note: Docker Desktop may reset these limits on restart.
EOF
}

check_for_exited_workload_node_containers() {
  local mgmt_kubeconfig="$1"
  local namespace="$2"
  local cluster_name="$3"

  command -v docker >/dev/null 2>&1 || return 0

  local dm_names
  dm_names="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get dockermachines \
    -l "cluster.x-k8s.io/cluster-name=$cluster_name" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  [[ -z "${dm_names:-}" ]] && return 0

  local dm
  while IFS= read -r dm; do
    [[ -z "${dm:-}" ]] && continue

    local status
    status="$(docker inspect -f '{{.State.Status}}' "$dm" 2>/dev/null || true)"
    [[ -z "${status:-}" ]] && continue

    if [[ "$status" == "exited" ]]; then
      local exit_code
      exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$dm" 2>/dev/null || true)"
      [[ -z "${exit_code:-}" ]] && exit_code="?"

      echo "Workload node container exited: $dm (exitCode=$exit_code)" >&2

      local tail_logs
      tail_logs="$(docker logs --tail 120 "$dm" 2>&1 | tail -n 60 || true)"
      if [[ -n "${tail_logs:-}" ]]; then
        echo "--- docker logs (tail) ---" >&2
        printf '%s\n' "$tail_logs" >&2
        echo "--------------------------" >&2
      fi

      if printf '%s\n' "$tail_logs" | grep -qiE 'too many open files|inotify'; then
        print_docker_desktop_inotify_help
      fi

      return 1
    fi
  done <<<"$dm_names"

  return 0
}

wait_for_cluster_ready() {
  local mgmt_kubeconfig="$1"
  local name="$2"

  local timeout_seconds="${LOCAL_CLUSTER_READY_TIMEOUT_SECONDS:-900}"

  local namespace
  namespace="$(find_cluster_namespace "$mgmt_kubeconfig" "$name")"
  if [[ -z "$namespace" ]]; then
    namespace="default"
  fi

  local api_version
  api_version="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.apiVersion}' 2>/dev/null || true)"

  # CAPI v1beta2 Cluster does not expose a Ready condition; it uses Available.
  local success_condition_type="Ready"
  if [[ "$api_version" == *"/v1beta2" ]]; then
    success_condition_type="Available"
  fi

  echo "Waiting for cluster ${success_condition_type}=True: $namespace/$name (timeout=${timeout_seconds}s)" >&2

  local start
  start="$(date +%s)"
  local poll=0

  while true; do
    poll=$((poll + 1))

    local success_status
    success_status="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" \
      -o jsonpath="{.status.conditions[?(@.type==\"$success_condition_type\")].status}" 2>/dev/null || true)"

    if [[ "$success_status" == "True" ]]; then
      return 0
    fi

    # Fail fast if the Cluster has surfaced a terminal error.
    local failure_reason failure_message
    failure_reason="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.failureReason}' 2>/dev/null || true)"
    failure_message="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.failureMessage}' 2>/dev/null || true)"
    if [[ -n "${failure_reason:-}" || -n "${failure_message:-}" ]]; then
      echo "Cluster reported a failure: $namespace/$name" >&2
      [[ -n "${failure_reason:-}" ]] && echo "  failureReason: $failure_reason" >&2
      [[ -n "${failure_message:-}" ]] && echo "  failureMessage: $failure_message" >&2
      return 1
    fi

    # Fail fast if CAPD has already reported a bootstrap exec failure on any node.
    if (( poll % 3 == 0 )); then
      local dm_lines dm_failure
      dm_lines="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get dockermachines \
        -l "cluster.x-k8s.io/cluster-name=$name" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="BootstrapExecSucceeded")].status}{"\t"}{.status.conditions[?(@.type=="BootstrapExecSucceeded")].reason}{"\t"}{.status.conditions[?(@.type=="BootstrapExecSucceeded")].message}{"\n"}{end}' 2>/dev/null || true)"
      # CAPD can temporarily report BootstrapExecSucceeded=False while it retries by
      # recreating the node container. Only fail fast when CAPD provides an actual
      # error message.
      dm_failure="$(printf '%s\n' "$dm_lines" | awk -F '\t' '$2=="False" && $4!=""{print; exit}')"
      if [[ -n "${dm_failure:-}" ]]; then
        echo "Bootstrap failed (DockerMachine BootstrapExecSucceeded=False):" >&2
        echo "  $dm_failure" >&2
        return 1
      fi

      # If the underlying node container disappeared, the cluster will not recover.
      local dm_container_lines dm_container_failure
      dm_container_lines="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get dockermachines \
        -l "cluster.x-k8s.io/cluster-name=$name" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="ContainerProvisioned")].status}{"\t"}{.status.conditions[?(@.type=="ContainerProvisioned")].reason}{"\t"}{.status.conditions[?(@.type=="ContainerProvisioned")].message}{"\n"}{end}' 2>/dev/null || true)"
      dm_container_failure="$(printf '%s\n' "$dm_container_lines" | awk -F '\t' '$2=="False" && ($3=="ContainerDeleted" || $4 ~ /does not exist/){print; exit}')"
      if [[ -n "${dm_container_failure:-}" ]]; then
        echo "Workload node container missing (DockerMachine ContainerProvisioned=False):" >&2
        echo "  $dm_container_failure" >&2
        echo "Tip: check Docker Desktop resources and Docker events; rerun after ./scripts/delete-local-clusters.sh" >&2
        return 1
      fi

      # CAPD can get stuck retrying when the underlying kind node container is
      # repeatedly crashing (e.g., Docker Desktop inotify/file descriptor exhaustion).
      if ! check_for_exited_workload_node_containers "$mgmt_kubeconfig" "$namespace" "$name"; then
        return 1
      fi
    fi

    if (( poll % 6 == 0 )); then
      local phase infra cpinit workers remote cpavail
      phase="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      infra="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="InfrastructureReady")].status}' 2>/dev/null || true)"
      cpinit="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="ControlPlaneInitialized")].status}' 2>/dev/null || true)"
      workers="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="WorkersAvailable")].status}' 2>/dev/null || true)"

      # v1beta2 adds more granular conditions.
      remote="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="RemoteConnectionProbe")].status}' 2>/dev/null || true)"
      cpavail="$(kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o jsonpath='{.status.conditions[?(@.type=="ControlPlaneAvailable")].status}' 2>/dev/null || true)"

      echo "  status: phase=${phase:-?} ${success_condition_type}=${success_status:-?} Infra=${infra:-?} CPInit=${cpinit:-?} Workers=${workers:-?} Remote=${remote:-?} CPAvail=${cpavail:-?}" >&2
    fi

    local now
    now="$(date +%s)"
    if (( now - start > timeout_seconds )); then
      echo "Timed out waiting for ${success_condition_type}=True: $namespace/$name (timeout=${timeout_seconds}s)" >&2
      echo "Debug:" >&2
      kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get cluster "$name" -o yaml >&2 || true
      kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get kubeadmcontrolplanes -o wide >&2 || true
      kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get machines -o wide >&2 || true
      kubectl --kubeconfig "$mgmt_kubeconfig" -n "$namespace" get dockermachines -o wide >&2 || true
      return 1
    fi

    sleep 5
  done
}

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
  local worker_count="$4"

  echo "Applying local cluster: $name (infrastructure=docker, version=$kube_version, workers=$worker_count)"
  clusterctl generate cluster "$name" \
    --from "$CAPD_TEMPLATE" \
    --kubeconfig "$mgmt_kubeconfig" \
    --kubernetes-version "$kube_version" \
    --control-plane-machine-count 1 \
    --worker-machine-count "$worker_count" \
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
  require_cmd bash

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

  # Default to control-plane-only clusters for reliability on Docker Desktop.
  # Opt in to workers with: LOCAL_WORKER_MACHINE_COUNT=1
  WORKER_COUNT="${LOCAL_WORKER_MACHINE_COUNT:-0}"

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

  local created=()

  # CAPD creates kind clusters (node containers). Creating too many clusters at
  # once can exhaust file descriptors inside the Docker Desktop VM, causing
  # systemd/inotify failures like "Too many open files" and preventing kubeadm
  # from completing.
  local wait_each_cluster
  wait_each_cluster="${LOCAL_CLUSTERS_WAIT_EACH_CLUSTER:-true}"

  for region in $AWS_REGIONS; do
    local name
    name="$(render_name "$AWS_NAME_PATTERN" "$region")"
    create_one "$name" "$KUBE_VERSION" "$tmp_kubeconfig" "$WORKER_COUNT"
    created+=("$name")

    if [[ "$wait_each_cluster" == "true" ]]; then
      wait_for_cluster_ready "$tmp_kubeconfig" "$name"
    fi
  done

  for location in $AZURE_LOCATIONS; do
    local name
    name="$(render_name "$AZURE_NAME_PATTERN" "$location")"
    create_one "$name" "$KUBE_VERSION" "$tmp_kubeconfig" "$WORKER_COUNT"
    created+=("$name")

    if [[ "$wait_each_cluster" == "true" ]]; then
      wait_for_cluster_ready "$tmp_kubeconfig" "$name"
    fi
  done

  for region in $GCP_REGIONS; do
    local name
    name="$(render_name "$GCP_NAME_PATTERN" "$region")"
    create_one "$name" "$KUBE_VERSION" "$tmp_kubeconfig" "$WORKER_COUNT"
    created+=("$name")

    if [[ "$wait_each_cluster" == "true" ]]; then
      wait_for_cluster_ready "$tmp_kubeconfig" "$name"
    fi
  done

  if (( ${#created[@]} > 0 )); then
    if [[ -f "$MERGE_WORKLOAD_KUBECONFIG_SCRIPT" ]]; then
      echo "Merging workload kubeconfigs into ~/.kube/config (waits for workload availability)..." >&2
      bash "$MERGE_WORKLOAD_KUBECONFIG_SCRIPT" "${created[@]}"
    else
      echo "Warning: merge script not found: $MERGE_WORKLOAD_KUBECONFIG_SCRIPT" >&2
      echo "You can merge manually with: ./scripts/merge-workload-kubeconfig.sh ${created[*]}" >&2
    fi
  fi

  echo "Submitted all local clusters. Watch provisioning with:"
  echo "  kind get kubeconfig --name $MGMT_NAME > /tmp/mgmt.kubeconfig"
  echo "  kubectl --kubeconfig /tmp/mgmt.kubeconfig get clusters -A"
  echo "  kubectl --kubeconfig /tmp/mgmt.kubeconfig get machines -A"
  echo "Get a workload kubeconfig (once ready) with:"
  echo "  clusterctl get kubeconfig <cluster-name> --kubeconfig /tmp/mgmt.kubeconfig > <cluster-name>.kubeconfig"
}

main "$@"
