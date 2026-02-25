#!/usr/bin/env bash
set -euo pipefail

# Merge the management cluster kubeconfig (from `kind get kubeconfig`) into the
# user's default kubeconfig at ~/.kube/config.
#
# This avoids naive appends and produces a single flattened config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
PROVIDERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_EMITTER="$PROVIDERS_DIR/utils/emit-envs.py"
MERGE_HELPER="$PROVIDERS_DIR/scripts/merge-kubeconfigs-into-home.sh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

main() {
  require_cmd kind
  require_cmd kubectl
  require_cmd python3

  if [[ ! -f "$ENV_EMITTER" ]]; then
    echo "Missing env emitter: $ENV_EMITTER" >&2
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

  local tmp_kind_kubeconfig
  tmp_kind_kubeconfig="$(mktemp)"
  trap "rm -f '$tmp_kind_kubeconfig'" EXIT
  kind get kubeconfig --name "$mgmt_name" >"$tmp_kind_kubeconfig"

  bash "$MERGE_HELPER" "$tmp_kind_kubeconfig"
}

main "$@"
