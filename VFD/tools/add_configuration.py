#!/usr/bin/env python3
"""Add a new configuration column pair to settings.csv and a row to configurations.csv.

Usage:  python3 VFD/tools/add_configuration.py acorn "Acorn controller board"

The key must be lowercase letters, digits and underscores. Fill in the rest of the
configurations.csv row (status, date, who, description) by hand afterwards.
"""
import csv
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

if len(sys.argv) != 3 or not re.fullmatch(r"[a-z][a-z0-9_]*", sys.argv[1]):
    sys.exit(__doc__)
key, name = sys.argv[1], sys.argv[2]

with open(HERE / "configurations.csv", newline="", encoding="utf-8") as fh:
    configs = list(csv.DictReader(fh))
if any(c["key"] == key for c in configs):
    sys.exit(f"Configuration '{key}' already exists")
configs.append({"key": key, "name": name, "status": "planned", "in_service": "", "configured_by": "", "description": ""})
with open(HERE / "configurations.csv", "w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=list(configs[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(configs)

with open(HERE / "settings.csv", newline="", encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh))
fields = list(rows[0].keys()) + [key, f"{key}_note"]
with open(HERE / "settings.csv", "w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=fields, lineterminator="\n", restval="")
    w.writeheader()
    w.writerows(rows)

print(f"Added '{key}'. Now fill in its row in configurations.csv.")
