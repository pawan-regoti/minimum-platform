#!/usr/bin/env bash
set -euo pipefail

# Merge one or more kubeconfig files into the user's home kubeconfig (~/.kube/config).
#
# - Creates a timestamped backup of ~/.kube/config if it exists.
# - Uses `kubectl config view --merge --flatten` to produce a single flattened config.
#
# Usage:
#   ./scripts/merge-kubeconfigs-into-home.sh /path/to/kubeconfig1 [/path/to/kubeconfig2 ...]

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

main() {
  require_cmd kubectl

  if (( $# == 0 )); then
    echo "Usage: $0 <kubeconfig1> [kubeconfig2 ...]" >&2
    exit 2
  fi

  local kube_dir="$HOME/.kube"
  local target="$kube_dir/config"
  mkdir -p "$kube_dir"

  if [[ -f "$target" ]]; then
    local backup="$target.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$target" "$backup"
    echo "Backed up existing kubeconfig to: $backup" >&2
  fi

  local merged
  merged="$(mktemp)"

  local kubeconfig_list=""
  if [[ -f "$target" ]]; then
    kubeconfig_list="$target"
  fi

  local k
  for k in "$@"; do
    if [[ ! -f "$k" ]]; then
      echo "Kubeconfig file not found: $k" >&2
      exit 1
    fi
    if [[ -n "$kubeconfig_list" ]]; then
      kubeconfig_list+=":$k"
    else
      kubeconfig_list="$k"
    fi
  done

  KUBECONFIG="$kubeconfig_list" kubectl config view --merge --flatten >"$merged"

  mv "$merged" "$target"
  chmod 600 "$target" || true

  echo "Merged kubeconfigs into: $target" >&2
  echo "Available contexts:" >&2
  kubectl config get-contexts
}

main "$@"
