#!/usr/bin/env python3
"""jget.py <file.json> <key> -- print one scalar from a JSON object (exit 1 if absent/unparseable)."""
import json
import sys

try:
    with open(sys.argv[1]) as f:
        v = json.load(f)[sys.argv[2]]
except Exception as e:  # noqa: BLE001
    print("jget: %s" % e, file=sys.stderr)
    sys.exit(1)
print(v if not isinstance(v, bool) else str(v).lower())
