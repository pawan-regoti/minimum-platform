#!/usr/bin/env python3
"""Read the Cluster API management plane name from a JSON config file.

Primary key: clusterManagementPlaneName
Legacy fallback: CLUSTER_MANAGEMENT_PLANE_NAME

Usage:
  python3 read-cluster-management-plane-name.py /path/to/config.json

Prints the resolved name to stdout (may be empty).
"""

from __future__ import annotations

import json
import sys
from typing import Any


def _get_str(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: read-cluster-management-plane-name.py <config.json>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        data = {}

    if not isinstance(data, dict):
        data = {}

    value = _get_str(data.get("clusterManagementPlaneName"))
    if not value:
        value = _get_str(data.get("CLUSTER_MANAGEMENT_PLANE_NAME"))

    print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
