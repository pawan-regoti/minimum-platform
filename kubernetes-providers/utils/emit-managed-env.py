#!/usr/bin/env python3
"""Emit environment variables for managed cluster scripts.

Reads and merges (in order):
  1) config.json (committed defaults)
  2) config.local.json (local overrides, gitignored)

Prints `export ...` lines safe to `eval` in bash.

Secrets: If you put secrets in config.local.json, they will be emitted as exports.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Dict, List


def _read_json(path: str) -> Dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    result: Dict[str, Any] = dict(base)
    for key, value in override.items():
        if (
            key in result
            and isinstance(result[key], dict)
            and isinstance(value, dict)
        ):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def _as_list(value: Any) -> List[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(x).strip() for x in value if str(x).strip()]
    text = str(value).strip()
    return [text] if text else []


def _get_str(data: Dict[str, Any], path: str, default: str = "") -> str:
    cur: Any = data
    for part in path.split("."):
        if not isinstance(cur, dict):
            return default
        cur = cur.get(part)
    if cur is None:
        return default
    return str(cur).strip() or default


def _get_obj(data: Dict[str, Any], path: str) -> Dict[str, Any]:
    cur: Any = data
    for part in path.split("."):
        if not isinstance(cur, dict):
            return {}
        cur = cur.get(part)
    return cur if isinstance(cur, dict) else {}


def _emit(name: str, value: str) -> None:
    safe = value.replace("\\", "\\\\").replace('"', '\\"')
    print(f'export {name}="{safe}"')


def main() -> int:
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    config_path = os.path.join(repo_dir, "config.json")
    local_path = os.path.join(repo_dir, "config.local.json")

    base = _read_json(config_path)
    local = _read_json(local_path)
    merged = _deep_merge(base, local)

    mgmt = _get_str(merged, "clusterManagementPlaneName", "capi-mgmt-1")
    _emit("CLUSTER_MANAGEMENT_PLANE_NAME", mgmt)
    _emit("CAPI_MGMT_CONTEXT", f"kind-{mgmt}")

    managed = _get_obj(merged, "managedClusters")
    _emit("MANAGED_KUBERNETES_VERSION", str(managed.get("kubernetesVersion", "v1.29.0")).strip())

    aws = managed.get("aws", {}) if isinstance(managed.get("aws"), dict) else {}
    azure = managed.get("azure", {}) if isinstance(managed.get("azure"), dict) else {}
    gcp = managed.get("gcp", {}) if isinstance(managed.get("gcp"), dict) else {}

    _emit("MANAGED_AWS_FLAVOR", str(aws.get("flavor", "CHANGE_ME")).strip())
    _emit("MANAGED_AWS_REGIONS", " ".join(_as_list(aws.get("regions"))))
    _emit("MANAGED_AWS_NAME_PATTERN", str(aws.get("clusterNamePattern", "eks-<region>-1")).strip())

    _emit("MANAGED_AZURE_FLAVOR", str(azure.get("flavor", "CHANGE_ME")).strip())
    _emit("MANAGED_AZURE_LOCATIONS", " ".join(_as_list(azure.get("locations"))))
    _emit("MANAGED_AZURE_NAME_PATTERN", str(azure.get("clusterNamePattern", "aks-<region>-1")).strip())

    _emit("MANAGED_GCP_FLAVOR", str(gcp.get("flavor", "CHANGE_ME")).strip())
    _emit("MANAGED_GCP_REGIONS", " ".join(_as_list(gcp.get("regions"))))
    _emit("MANAGED_GCP_NAME_PATTERN", str(gcp.get("clusterNamePattern", "gke-<region>-1")).strip())

    # Optional secrets (you asked to keep them in config.local.json). These keys are intentionally
    # simple and map 1:1 to common env var names used by provider templates.
    secrets = _get_obj(merged, "secrets")
    for key, value in secrets.items():
        if value is None:
            continue
        if isinstance(value, (dict, list)):
            continue
        v = str(value).strip()
        if v:
            _emit(key, v)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
