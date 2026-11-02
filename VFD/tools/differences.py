#!/usr/bin/env python3
"""Write VFD/differences.md: every parameter that is not at its factory value,
plus a change list for each step from one configuration to the next.

Run from anywhere:  python3 VFD/tools/differences.py
GitHub runs this automatically and commits the result, so you normally
don't need to run it yourself.
"""
import csv
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def load(name):
    with open(HERE / name, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def cell(v):
    return v if v else "—"


def esc(v):
    return v.replace("|", "\\|")


def main():
    params = {p["code"]: p for p in load("parameters.csv")}
    settings = load("settings.csv")
    configs = load("configurations.csv")
    keys = [c["key"] for c in configs[1:]]
    names = {c["key"]: c["name"] for c in configs}

    out = ["# VFD settings — differences", "",
           "_Generated from settings.csv by tools/differences.py. Do not edit by hand._", "",
           "A dash (—) means the value has not been recorded for that configuration.", ""]

    # 1. Everything not at factory, in any configuration.
    out += ["## Parameters changed from factory", ""]
    hdr = "| Code | Parameter | Factory | " + " | ".join(keys) + " | Notes |"
    out += [hdr, "|" + "---|" * (4 + len(keys))]
    count = 0
    for s in settings:
        vals = [s[k] for k in keys]
        if any(v and v != s["factory"] for v in vals):
            notes = "; ".join(f"{k}: {s[k + '_note']}" for k in keys if s.get(k + "_note"))
            out.append(f"| {s['code']} | {esc(params[s['code']]['name'])} | {cell(s['factory'])} | "
                       + " | ".join(cell(v) for v in vals) + f" | {esc(notes)} |")
            count += 1
    if not count:
        out.append("| | _No differences recorded yet._ | | " + " | " * len(keys) + " |")
    out.append("")

    # 2. Change list for each consecutive pair of configurations.
    for a, b in zip(keys, keys[1:]):
        out += [f"## Changing from {a} to {b}", "",
                f"{names[a]} → {names[b]}. These are the parameters to change at the start of each "
                f"{b} session and restore at the end.", "",
                f"| Code | Parameter | {a} | {b} | Can change while running? | Why ({b}) |",
                "|---|---|---|---|---|---|"]
        n = 0
        for s in settings:
            va, vb = s[a], s[b]
            if vb and va != vb:
                p = params[s["code"]]
                out.append(f"| {s['code']} | {esc(p['name'])} | {cell(va)} | {vb} | "
                           f"{'yes' if p['change'] == 'any time' else 'no — stop the spindle'} | "
                           f"{esc(s.get(b + '_note', ''))} |")
                n += 1
        if not n:
            out.append("| | _No changes recorded yet._ | | | | |")
        out.append("")

    (HERE / "differences.md").write_text("\n".join(out), encoding="utf-8")
    print(f"Wrote differences.md ({count} parameter(s) differ from factory)")


if __name__ == "__main__":
    main()
