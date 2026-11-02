#!/usr/bin/env python3
"""Check the VFD settings files for formatting and range errors.

Run from anywhere:  python3 VFD/tools/check.py
Exits with status 1 (and lists the problems) if anything is wrong.
GitHub runs this automatically on every change to the VFD folder.
"""
import csv
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent  # the VFD folder
errors = []


def load(name):
    with open(HERE / name, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def decimals(text):
    return len(text.split(".")[1]) if "." in text else 0


def enum_values(options):
    """Allowed integers from text like '0=Off; 1=On; 11–12=Reserved'."""
    allowed = set()
    for part in options.split(";"):
        key = part.split("=", 1)[0].strip()
        m = re.fullmatch(r"(\d+)\s*[–-]\s*(\d+)", key)
        if m:
            allowed.update(range(int(m.group(1)), int(m.group(2)) + 1))
        elif key.isdigit():
            allowed.add(int(key))
    return allowed


def check_value(p, value, where):
    if value == "":
        return
    typ, factory = p["type"], p["factory"]
    if value == "machine-type":
        if not where.endswith("factory"):
            errors.append(f"{where}: 'machine-type' is only allowed in the factory column — record the actual value")
        return
    if typ == "number":
        if not re.fullmatch(r"-?\d+(\.\d+)?", value):
            errors.append(f"{where}: '{value}' is not a number")
            return
        ref = p["min"] or factory
        rng = p["range"]
        is_freq = (" Hz" in rng or "frequency" in rng.lower()) and "kHz" not in rng and "Hz/s" not in rng
        if is_freq and decimals(value) in (1, 2):
            pass  # the keypad shows frequencies with 1 or 2 decimals depending on max frequency
        elif decimals(value) != decimals(ref):
            errors.append(f"{where}: '{value}' should have {decimals(ref)} decimal place(s), like the keypad shows "
                          f"(was it opened and saved in Excel?)")
        if p["min"] and float(value) < float(p["min"]):
            errors.append(f"{where}: {value} is below the minimum {p['min']}")
        if p["max"] and float(value) > float(p["max"]):
            errors.append(f"{where}: {value} is above the maximum {p['max']}")
    elif typ == "enum":
        if not value.isdigit() or int(value) not in enum_values(p["range"]):
            errors.append(f"{where}: '{value}' is not one of the allowed options ({p['range']})")
    elif typ == "digits":
        if not re.fullmatch(r"b\d+", value):
            errors.append(f"{where}: digit fields must start with 'b', e.g. '{factory}' (got '{value}')")
        elif len(value) != len(factory):
            errors.append(f"{where}: '{value}' should have {len(factory) - 1} digits, like '{factory}'")
    elif typ == "hex":
        if not re.fullmatch(r"H\.[0-9A-F]+", value):
            errors.append(f"{where}: hex fields are written like '{factory}' (got '{value}')")
        elif len(value) != len(factory):
            errors.append(f"{where}: '{value}' should have {len(factory) - 2} hex digits, like '{factory}'")
    elif typ == "ref":
        if not re.fullmatch(r"U\d\.\d\.\d\d", value):
            errors.append(f"{where}: parameter references are written like 'U0.0.02' (got '{value}')")


def main():
    # Plain ASCII only: Excel misreads other characters in CSV files (e.g. an en dash shows as "â€“").
    for path in sorted(HERE.glob("*.csv")):
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            bad = sorted({ch for ch in line if ord(ch) > 127})
            if bad:
                errors.append(f"{path.name} line {n}: non-ASCII character(s) {' '.join(bad)} - "
                              f"use plain characters (e.g. '-' instead of a long dash) so Excel can read the file")

    params = load("parameters.csv")
    settings = load("settings.csv")
    configs = load("configurations.csv")
    by_code = {p["code"]: p for p in params}

    # Every parameter's own factory value must be well formed.
    for p in params:
        check_value(p, p["factory"], f"parameters.csv {p['code']} factory")

    # Same parameters, same order, in both files.
    s_codes = [s["code"] for s in settings]
    p_codes = [p["code"] for p in params]
    if s_codes != p_codes:
        missing = set(p_codes) - set(s_codes)
        extra = set(s_codes) - set(p_codes)
        if missing:
            errors.append(f"settings.csv is missing rows: {', '.join(sorted(missing))}")
        if extra:
            errors.append(f"settings.csv has unknown codes: {', '.join(sorted(extra))}")
        if not missing and not extra:
            errors.append("settings.csv rows are not in the same order as parameters.csv")

    # Columns must match configurations.csv: factory, then <key>, <key>_note for each configuration.
    keys = [c["key"] for c in configs]
    if not keys or keys[0] != "factory":
        errors.append("configurations.csv: the first configuration must be 'factory'")
    expected = ["code", "factory"]
    for k in keys[1:]:
        if not re.fullmatch(r"[a-z][a-z0-9_]*", k):
            errors.append(f"configurations.csv: key '{k}' should be lowercase letters, digits and underscores")
        expected += [k, f"{k}_note"]
    actual = list(settings[0].keys()) if settings else []
    if actual != expected:
        errors.append(f"settings.csv columns are {actual}; expected {expected} to match configurations.csv")

    for s in settings:
        p = by_code.get(s["code"])
        if not p:
            continue
        if s.get("factory") != p["factory"]:
            errors.append(f"settings.csv {s['code']}: factory '{s.get('factory')}' differs from parameters.csv '{p['factory']}'")
        for k in keys[1:]:
            v = s.get(k, "")
            check_value(p, v, f"settings.csv {s['code']} {k}")
            if s.get(f"{k}_note") and not v:
                errors.append(f"settings.csv {s['code']}: {k}_note is filled in but {k} is empty")

    if errors:
        print(f"{len(errors)} problem(s) found:\n")
        for e in errors:
            print(" -", e)
        sys.exit(1)
    print(f"OK: {len(params)} parameters, configurations: {', '.join(keys)}")


if __name__ == "__main__":
    main()
