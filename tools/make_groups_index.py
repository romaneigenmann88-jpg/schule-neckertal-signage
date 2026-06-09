#!/usr/bin/env python3
"""Erzeugt publish/groups.json – den Gruppen-Index für die Adminkonsole."""
import glob
import json
import os
import sys

ids = sorted(os.path.basename(p.rstrip("/")) for p in glob.glob("publish/groups/*/"))
generated = sys.argv[1] if len(sys.argv) > 1 else ""
with open("publish/groups.json", "w", encoding="utf-8") as f:
    json.dump({"generated": generated, "groups": ids}, f, indent=2)
print("groups.json:", ids)
