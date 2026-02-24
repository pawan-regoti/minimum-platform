#!/usr/bin/env bash
set -euo pipefail

# Creates a local Cluster API (CAPI) management cluster and installs
# Cluster API components into it.
#
# This uses:
# - kind for the management cluster
# - clusterctl to install CAPI controllers
# - Docker infrastructure provider (CAPD) so the mgmt cluster can create "Docker clusters"
#
# Prereqs:
# - Docker runtime (Docker Desktop or Colima)
# - kubectl, kind, clusterctl
#
# Install (macOS):
#   brew install kubectl kind clusterctl
#
# Usage:
#   ./scripts/create-management-plane-capi.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_LOCAL_FILE="$PROVIDERS_DIR/config.local.json"
CONFIG_FILE="$PROVIDERS_DIR/config.json"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

load_config_if_needed() {
  # Prefer an already-exported env var; otherwise fall back to config.json.
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
    CLUSTER_MANAGEMENT_PLANE_NAME="$(python3 - "$source_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
  with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
except Exception:
  data = {}

value = data.get('clusterManagementPlaneName', '')
if not value:
  value = data.get('CLUSTER_MANAGEMENT_PLANE_NAME', '')
if value is None:
  value = ''
print(str(value))
PY
)"
  fi
}

load_config_if_needed

MGMT_CLUSTER_NAME="${CLUSTER_MANAGEMENT_PLANE_NAME:-capi-mgmt-1}"

kctx() {
  echo "kind-$1"
}

kind_cluster_exists() {
  local name="$1"
  kind get clusters 2>/dev/null | grep -qx "$name"
}

create_kind_cluster_with_docker_sock() {
  local name="$1"

  if kind_cluster_exists "$name"; then
    echo "Cluster already exists: $name (delete it first to recreate)" >&2
    exit 1
  fi

  echo "Creating kind management cluster: $name"

  # CAPD controllers need to reach the local Docker daemon. The simplest approach is
  # mounting /var/run/docker.sock into the kind node container.
  local cfg
  cfg="$(mktemp)"
  cat >"$cfg" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
YAML

  kind create cluster --name "$name" --config "$cfg"
  rm -f "$cfg"
}

install_capi_docker_provider() {
  local ctx="$1"
  local cluster_name="$2"

  echo "Installing Cluster API (Docker provider) into $ctx"

  # clusterctl will install:
  # - Cluster API core
  # - kubeadm bootstrap + control plane
  # - Docker infrastructure provider (CAPD)
  # clusterctl doesn't support a --context flag, so use a kubeconfig that targets
  # the specific kind cluster.
  local tmp_kubeconfig
  tmp_kubeconfig="$(mktemp)"
  kind get kubeconfig --name "$cluster_name" >"$tmp_kubeconfig"

  clusterctl init \
    --kubeconfig "$tmp_kubeconfig" \
    --infrastructure docker

  rm -f "$tmp_kubeconfig"
}

wait_for_capi() {
  local ctx="$1"

  # Keep it intentionally light: just ensure the core controller manager is up.
  # clusterctl may return before all objects appear, so wait for them to exist first.
  for _ in {1..60}; do
    if kubectl --context "$ctx" get ns capi-system >/dev/null 2>&1 && \
       kubectl --context "$ctx" -n capi-system get deploy capi-controller-manager >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  kubectl --context "$ctx" -n capi-system rollout status deploy/capi-controller-manager --timeout=300s
}

main() {
  require_cmd docker
  require_cmd kubectl
  require_cmd kind
  require_cmd clusterctl

  create_kind_cluster_with_docker_sock "$MGMT_CLUSTER_NAME"

  ctx="$(kctx "$MGMT_CLUSTER_NAME")"

  install_capi_docker_provider "$ctx" "$MGMT_CLUSTER_NAME"
  wait_for_capi "$ctx"

  echo "Ready management plane: $MGMT_CLUSTER_NAME"
  echo "Context: $ctx"
  echo

  echo "Next steps (optional):"
  echo "  Create a workload cluster from the management plane:"
  echo "    clusterctl generate cluster wc-1 --kubernetes-version v1.29.0 --control-plane-machine-count 1 --worker-machine-count 1 | kubectl --context $ctx apply -f -"
  echo "  Get its kubeconfig:"
  echo "    clusterctl --context $ctx get kubeconfig wc-1 > wc-1.kubeconfig"
}

main "$@"
