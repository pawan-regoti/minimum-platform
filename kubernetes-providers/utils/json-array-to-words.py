#!/usr/bin/env python3
"""Convert a JSON array string to space-separated words.

Used by bash scripts so they don't need inline Python heredocs.

Behavior:
- Invalid/missing JSON -> prints nothing, exits 0.
- Non-list JSON -> prints nothing, exits 0.
- List items are stringified, stripped; empty items are dropped.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    if not raw:
        return 0

    try:
        data = json.loads(raw)
    except Exception:
        return 0

    if not isinstance(data, list):
        return 0

    parts = [str(x).strip() for x in data]
    parts = [p for p in parts if p]

    if parts:
        sys.stdout.write(" ".join(parts))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
