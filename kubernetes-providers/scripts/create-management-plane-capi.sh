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
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"
KIND_CONFIG_FILE="$PROVIDERS_DIR/manifests/kind-management-cluster.yml"
MERGE_MGMT_KUBECONFIG_SCRIPT="$SCRIPT_DIR/merge-management-kubeconfig.sh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

load_config_if_needed() {
  # Prefer an already-exported env var; otherwise fall back to the merged config
  # emitted by utils/emit-envs.py.
  if [[ -n "${CLUSTER_MANAGEMENT_PLANE_NAME:-}" ]]; then
    return 0
  fi

  if [[ ! -f "$ENV_EMITTER" ]]; then
    echo "Missing env emitter: $ENV_EMITTER" >&2
    exit 1
  fi

  require_cmd python3
  # shellcheck disable=SC1090
  eval "$(python3 "$ENV_EMITTER")"

  # If we ever stop emitting the curated CLUSTER_* variables, fall back to CONFIG_*.
  if [[ -z "${CLUSTER_MANAGEMENT_PLANE_NAME:-}" ]]; then
    CLUSTER_MANAGEMENT_PLANE_NAME="${CONFIG_CLUSTER_MANAGEMENT_PLANE_NAME:-}"
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
  if [[ ! -f "$KIND_CONFIG_FILE" ]]; then
    echo "Missing kind config file: $KIND_CONFIG_FILE" >&2
    exit 1
  fi

  kind create cluster --name "$name" --config "$KIND_CONFIG_FILE"
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

  # Creating workload clusters triggers admission webhooks. Ensure all provider
  # deployments (including webhooks) are ready before returning.
  local namespaces=(
    cert-manager
    capi-system
    capi-kubeadm-bootstrap-system
    capi-kubeadm-control-plane-system
    capd-system
  )

  local ns
  for ns in "${namespaces[@]}"; do
    for _ in {1..60}; do
      if kubectl --context "$ctx" get ns "$ns" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done

    # Wait for deployments (including webhook deployments) in the namespace.
    # We can't rely on `kubectl rollout status --all` across kubectl versions.
    local deployments=""
    for _ in {1..60}; do
      deployments="$(kubectl --context "$ctx" -n "$ns" get deploy -o name 2>/dev/null || true)"
      if [[ -n "$deployments" ]]; then
        break
      fi
      sleep 2
    done

    if [[ -n "$deployments" ]]; then
      local d
      while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        kubectl --context "$ctx" -n "$ns" rollout status "$d" --timeout=300s
      done <<<"$deployments"
    fi
  done
}

main() {
  require_cmd docker
  require_cmd kubectl
  require_cmd kind
  require_cmd clusterctl
  require_cmd bash

  create_kind_cluster_with_docker_sock "$MGMT_CLUSTER_NAME"

  ctx="$(kctx "$MGMT_CLUSTER_NAME")"

  install_capi_docker_provider "$ctx" "$MGMT_CLUSTER_NAME"
  wait_for_capi "$ctx"

  if [[ -f "$MERGE_MGMT_KUBECONFIG_SCRIPT" ]]; then
    echo "Merging management kubeconfig into ~/.kube/config" >&2
    bash "$MERGE_MGMT_KUBECONFIG_SCRIPT"
  else
    echo "Warning: merge script not found: $MERGE_MGMT_KUBECONFIG_SCRIPT" >&2
    echo "You can merge manually with: ./scripts/merge-management-kubeconfig.sh" >&2
  fi

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
