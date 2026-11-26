#!/usr/bin/env python3
"""coverage_gaps.py — normalise coverage runs and list the functions no run reached (W40.e4).

  coverage_gaps.py xcresult <bundle.xcresult> <run>   xccov's function report → $COV_OUT/<run>.json
  coverage_gaps.py llvm <export.json> <run>           `llvm-cov export` (the Processor drivers) → <run>.json
  coverage_gaps.py report                             union every <run>.json in $COV_OUT → never-reached.tsv
                                                      and summary.md beside them

A function is keyed by (repo-relative source path, first line), so the same function counts once whichever app,
VM guest or worktree compiled it. It is never-reached when its execution count is 0 in every run that compiled
it. Test sources, generated files and compiler-made functions (closures, default arguments, property
initialisers, thunks) are left out: an unreached closure inside a reached function is an untested branch, which
is a finer question than this item asks.
"""
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

OUT = os.environ.get("COV_OUT", "/tmp/coverage-gaps")
ROOTS = re.compile(r"/((?:ArchiveReader|ArchiveNotes|ArchiveProcessor|packages)/.*)$")
SKIP_PATH = re.compile(r"/build/|DerivedData|/\.build/|/Tests/|UITests/|Tests\.swift$|/UITestSupport/|/Tools/")
SKIP_NAME = re.compile(r"closure #|implicit closure|default argument|variable initialization expression|"
                       r"\bthunk\b|^\$|lazy property initializer|property wrapper backing initializer|"
                       r"autoclosure|__derived_|outlined ")


def rel(path):
    m = ROOTS.search(path)
    if not m or SKIP_PATH.search(path) or not path.endswith(".swift"):
        return None
    return m.group(1)


def save(run, funcs):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, run + ".json"), "w") as f:
        json.dump({"run": run, "functions": funcs}, f)
    reached = sum(1 for x in funcs if x["count"] > 0)
    print(f"[cov] {run}: {len(funcs)} functions, {reached} reached → {OUT}/{run}.json")


def from_xcresult(bundle, run):
    raw = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", bundle],
                         capture_output=True, text=True, check=True).stdout
    funcs = []
    for t in json.loads(raw).get("targets", []):
        for fl in t.get("files", []):
            r = rel(fl.get("path", ""))
            if not r:
                continue
            for fn in fl.get("functions", []):
                funcs.append({"file": r, "line": fn["lineNumber"], "name": fn["name"],
                              "count": fn["executionCount"], "lines": fn.get("executableLines", 0)})
    if not funcs:
        sys.exit(f"{bundle}: no source functions in the coverage report")
    save(run, funcs)


def demangle(names):
    out = subprocess.run(["xcrun", "swift-demangle", "--simplified", "--compact"], input="\n".join(names),
                         capture_output=True, text=True, check=True).stdout.split("\n")
    return out[:len(names)]


def from_llvm(path, run):
    data = json.load(open(path))["data"][0]
    rows = []
    for fn in data.get("functions", []):
        if not fn.get("regions") or not fn.get("filenames"):
            continue
        reg = fn["regions"][0]
        r = rel(fn["filenames"][reg[5]] if len(reg) > 5 else fn["filenames"][0])
        if not r:
            continue
        nlines = len({line for g in fn["regions"] for line in range(g[0], g[2] + 1)})
        rows.append((r, reg[0], fn["name"], fn["count"], nlines))
    names = demangle([x[2].split(":")[-1] for x in rows])
    funcs = [{"file": r, "line": ln, "name": nm, "count": c, "lines": n}
             for (r, ln, _, c, n), nm in zip(rows, names)]
    if not funcs:
        sys.exit(f"{path}: no source functions in the export")
    save(run, funcs)


def area(path):
    p = path.split("/")
    if p[0] == "packages":
        return p[1]
    if p[0] == "ArchiveProcessor" and len(p) > 1 and p[1] != "macOS":
        return "ArchiveProcessor/" + p[1]
    return p[0]


def report():
    runs, agg = [], {}
    for fn in sorted(os.listdir(OUT)):
        if not fn.endswith(".json"):
            continue
        d = json.load(open(os.path.join(OUT, fn)))
        runs.append((d["run"], len(d["functions"])))
        for x in d["functions"]:
            k = (x["file"], x["line"])
            a = agg.setdefault(k, {"name": x["name"], "count": 0, "lines": x["lines"], "runs": set()})
            a["count"] += x["count"]
            a["runs"].add(d["run"])
            if x["count"] > 0:
                a.setdefault("hit", set()).add(d["run"])
    if not runs:
        sys.exit(f"no runs in {OUT}")
    named = {k: v for k, v in agg.items() if not SKIP_NAME.search(v["name"])}
    gaps = sorted(k for k, v in named.items() if v["count"] == 0)
    with open(os.path.join(OUT, "never-reached.tsv"), "w") as f:
        f.write("area\tfile\tline\tfunction\texecutable_lines\tcompiled_in\n")
        for k in gaps:
            v = named[k]
            f.write(f"{area(k[0])}\t{k[0]}\t{k[1]}\t{v['name']}\t{v['lines']}\t{','.join(sorted(v['runs']))}\n")
    per_area = defaultdict(lambda: [0, 0, 0, 0])   # functions, unreached, lines, unreached lines
    per_file = defaultdict(lambda: [0, 0, 0])      # functions, unreached, unreached lines
    for k, v in named.items():
        a = per_area[area(k[0])]
        a[0] += 1; a[2] += v["lines"]
        pf = per_file[k[0]]
        pf[0] += 1
        if v["count"] == 0:
            a[1] += 1; a[3] += v["lines"]
            pf[1] += 1; pf[2] += v["lines"]
    with open(os.path.join(OUT, "summary.md"), "w") as f:
        f.write("Runs: " + ", ".join(f"{r} ({n})" for r, n in runs) + "\n\n")
        f.write("| Area | Functions | Never reached | Executable lines | In never-reached functions |\n|---|---:|---:|---:|---:|\n")
        for a in sorted(per_area):
            n, u, ln, ul = per_area[a]
            f.write(f"| {a} | {n} | {u} ({100 * u // max(n, 1)}%) | {ln} | {ul} |\n")
        f.write("\nFiles with no reached function at all:\n\n")
        for p in sorted(per_file):
            n, u, ul = per_file[p]
            if u == n:
                f.write(f"- `{p}` — {n} function(s), {ul} lines\n")
    print(f"[cov] {len(gaps)} never-reached functions of {len(named)} across {len(runs)} runs → "
          f"{OUT}/never-reached.tsv, {OUT}/summary.md")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "xcresult" and len(sys.argv) == 4:
        from_xcresult(sys.argv[2], sys.argv[3])
    elif cmd == "llvm" and len(sys.argv) == 4:
        from_llvm(sys.argv[2], sys.argv[3])
    elif cmd == "report":
        report()
    else:
        sys.exit(__doc__)
