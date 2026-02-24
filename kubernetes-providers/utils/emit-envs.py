#!/usr/bin/env python3
"""Emit environment variables for scripts.

Reads and merges (in order):
  1) config.json (committed defaults)
  2) config.local.json (local overrides, gitignored)

Prints `export ...` lines safe to `eval` in bash.

Secrets: If you put secrets in config.local.json, they will be emitted as exports.
"""

from __future__ import annotations

import json
import os
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
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
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


def _to_env_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list, bool, int, float)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return str(value)


def _normalize_env_segment(segment: str) -> str:
    # Turn camelCase / kebab-case / weird keys into ENV_SAFE uppercase.
    out: List[str] = []
    prev_underscore = False
    for idx, ch in enumerate(segment):
        if "a" <= ch <= "z":
            out.append(ch.upper())
            prev_underscore = False
            continue
        if "A" <= ch <= "Z":
            # Insert underscore for camelCase boundaries.
            if idx > 0 and not prev_underscore and out and out[-1] != "_":
                out.append("_")
            out.append(ch)
            prev_underscore = False
            continue
        if "0" <= ch <= "9":
            out.append(ch)
            prev_underscore = False
            continue
        if not prev_underscore:
            out.append("_")
            prev_underscore = True

    normalized = "".join(out).strip("_")
    while "__" in normalized:
        normalized = normalized.replace("__", "_")
    return normalized or "KEY"


def _emit_all_config(prefix: str, value: Any, path: List[str] | None = None) -> None:
    path = [] if path is None else path

    # Dict: recurse
    if isinstance(value, dict):
        for k, v in value.items():
            seg = _normalize_env_segment(str(k))
            _emit_all_config(prefix, v, [*path, seg])
        return

    # List: emit as JSON for the whole list
    if isinstance(value, list):
        name = prefix + ("_" + "_".join(path) if path else "")
        _emit(name, _to_env_value(value))
        return

    # Scalar: emit
    if value is None:
        return
    name = prefix + ("_" + "_".join(path) if path else "")
    _emit(name, _to_env_value(value))


def main() -> int:
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    config_path = os.path.join(repo_dir, "config.json")
    local_path = os.path.join(repo_dir, "config.local.json")

    base = _read_json(config_path)
    local = _read_json(local_path)
    merged = _deep_merge(base, local)

    # Emit full merged config as flattened CONFIG_* variables.
    _emit_all_config("CONFIG", merged)

    # Optional convenience export: lets users override scripts by exporting a single var.
    # Scripts no longer rely on this being present.
    mgmt = _get_str(merged, "clusterManagementPlaneName", "")
    if mgmt:
        _emit("CLUSTER_MANAGEMENT_PLANE_NAME", mgmt)

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
