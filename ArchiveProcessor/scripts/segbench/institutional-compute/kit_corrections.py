#!/usr/bin/env python3
"""W46.kit-corrections-store. Read the review records the Processor keeps with each collection, and count them per
material toward the kit's thresholds.

  kit_corrections.py count  DIR [DIR ...] [--pool NAME] [--json]   # gaps per material, lines per hand, against the floors
  kit_corrections.py export DIR [DIR ...] [--pool NAME] --out FILE # every recorded gap, one JSON object a line

DIR is a collection's output folder, or a folder above several (Live Capture files each collection into its own
subfolder): every `.archivesuite/corrections/` below it is read. Links are never followed, and a file over 8 MB or of a
newer format is skipped. The format is SPEC/collection-settings.md §"The review records"; the writer is the
Processor's `Settings/ReviewCorrections.swift`.

The floors (14-owner-calls.md call 7; execution-plans/processing-review/13-stage-rules/12-training-kit.md §7.4, §7.5):
- the segmentation continuation (`seg-2b-lora-k200`) once 200 gaps of one material were ruled on by a person: checked
  in the flagged pass or changed in the skim. A gap left as proposed through the skim (`accepted`) is known but not
  counted. The gate then needs a further box of the same material with at least 267 known gaps in 10 documents,
  which this count does not check (`train_seg.py check` does).
- the handwriting fine-tune (`kit-hands-ppocrv6-ft`) from 80 corrected lines of one hand, 160 the target.

The material is the collection (its id in the collection's settings document). Several collections of one material
are counted together with `--pool NAME`, which the user decides: nothing in the records says two boxes are one
material. A page pair reviewed in more than one run is counted once, from the newest record; so is a line.
"""
from __future__ import annotations
import argparse
import json
import os
import stat
import sys
from pathlib import Path

GAPS_FLOOR = 200
LINES_FLOOR = 80
LINES_TARGET = 160
MAX_BYTES = 8 * 1024 * 1024
SCHEMA = 1


def corrections_dirs(root: Path):
    """Every `.archivesuite/corrections` at or below root, without following a link."""
    for top, dirs, _files in os.walk(root, followlinks=False):
        here = Path(top)
        if here.name == ".archivesuite":
            dirs[:] = []
            c = here / "corrections"
            try:
                if stat.S_ISDIR(os.lstat(c).st_mode):
                    yield here.parent, c
            except FileNotFoundError:
                pass


def read_records(roots):
    """(folder, name, record) for every readable record below the roots, oldest first by recordedAt then file name.
    A file that is not an ordinary file, is too large, is not JSON, is of a newer format or has the wrong shape is
    skipped."""
    out = []
    for root in roots:
        for folder, cdir in corrections_dirs(Path(root).resolve()):
            try:
                names = sorted(os.listdir(cdir))
            except OSError:
                continue
            for name in names:
                if not (name.startswith(("gaps-", "lines-")) and name.endswith(".json")):
                    continue
                try:
                    p = cdir / name
                    st = os.lstat(p)
                    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_BYTES:
                        continue
                    with open(p, "rb") as f:
                        r = json.load(f)
                except (OSError, ValueError):
                    continue
                if not (isinstance(r, dict) and isinstance(r.get("schemaVersion"), int) and r["schemaVersion"] <= SCHEMA
                        and r.get("kind") in ("gaps", "lines") and isinstance(r.get("recordedAt"), str)
                        and isinstance(r.get("owner", {}), dict)
                        and isinstance(r.get("gaps" if r.get("kind") == "gaps" else "lines"), list)):
                    continue
                out.append((str(folder), name, r))
    out.sort(key=lambda x: (x[2]["recordedAt"], x[1]))
    return out


def page_key(p, folder):
    """A page by its hash when it has one, else by its name in its own folder (camera names repeat across boxes)."""
    if not isinstance(p, dict) or not isinstance(p.get("name"), str):
        raise ValueError("not a page")
    return ("sha", p["sha256"]) if isinstance(p.get("sha256"), str) and p["sha256"] else ("name", folder, p["name"])


def gather(roots, pool=None):
    """Per material: its name, the newest call on each page pair, and the newest text of each line. The material is
    the record's collection id; a record without one joins the id other records of its folder carry, else the folder."""
    records = read_records(roots)
    folder_ids = {}
    for folder, _name, r in records:
        cid = (r.get("owner") or {}).get("collectionID")
        if isinstance(cid, str) and cid:
            folder_ids[folder] = (cid, (r.get("owner") or {}).get("collectionName") or Path(folder).name)
    mats = {}
    for folder, _name, r in records:
        if pool:
            mid, mname = pool, pool
        else:
            owner = r.get("owner") or {}
            cid = owner.get("collectionID")
            if isinstance(cid, str) and cid:
                mid, mname = cid, owner.get("collectionName") or Path(folder).name
            else:
                mid, mname = folder_ids.get(folder, (folder, Path(folder).name))
        m = mats.setdefault(mid, {"name": mname, "gaps": {}, "lines": {}, "folders": set()})
        m["folders"].add(folder)
        for item in r["gaps"] if r["kind"] == "gaps" else r["lines"]:
            try:
                if r["kind"] == "gaps":
                    l, rt = page_key(item["left"], folder), page_key(item["right"], folder)
                    # Both pages by hash, or both by name: a pair is never keyed half one way.
                    if l[0] != rt[0]:
                        l, rt = ("name", folder, item["left"]["name"]), ("name", folder, item["right"]["name"])
                    m["gaps"][(l, rt)] = dict(item, runID=r.get("runID"), folder=folder)   # newer overwrites older
                else:
                    if not isinstance(item.get("line"), int):
                        continue
                    m["lines"][(page_key(item["page"], folder), item["line"])] = dict(item, runID=r.get("runID"),
                                                                                       folder=folder)
            except (KeyError, TypeError, ValueError, AttributeError):
                continue
    return mats


def summary(mats):
    rows = []
    for mid, m in sorted(mats.items(), key=lambda x: x[1]["name"]):
        gaps = list(m["gaps"].values())
        ruled = sum(g.get("ruling") in ("checked", "changed") for g in gaps)
        hands = {}
        for ln in m["lines"].values():
            hand = ln.get("hand") if isinstance(ln.get("hand"), str) else ""
            hands[hand] = hands.get(hand, 0) + 1
        rows.append({
            "material": mid, "name": m["name"], "folders": sorted(m["folders"]),
            "gaps": {"ruled": ruled, "known": len(gaps), "changed_from_proposal":
                     sum(g.get("final") != g.get("proposed") for g in gaps),
                     "floor": GAPS_FLOOR, "continuation_offered": ruled >= GAPS_FLOOR},
            "lines": [{"hand": h, "lines": n, "floor": LINES_FLOOR, "target": LINES_TARGET,
                       "fine_tune_offered": n >= LINES_FLOOR} for h, n in sorted(hands.items())],
        })
    return rows


def cmd_count(a):
    rows = summary(gather(a.dirs, a.pool))
    if a.json:
        print(json.dumps(rows, indent=1))
        return
    if not rows:
        print("No review records found.")
        return
    for r in rows:
        g = r["gaps"]
        state = "the continuation can be offered" if g["continuation_offered"] else f"{GAPS_FLOOR - g['ruled']} more to go"
        print(f"{r['name']}: {g['ruled']} gaps ruled on by a person ({g['known']} known); {state}.")
        for h in r["lines"]:
            who = h["hand"] or "an unnamed hand"
            line_state = (f"the fine-tune can be offered (target {LINES_TARGET})" if h["fine_tune_offered"]
                          else f"{LINES_FLOOR - h['lines']} more to go")
            print(f"  {who}: {h['lines']} corrected lines; {line_state}.")


def cmd_export(a):
    n = 0
    with open(a.out, "w") as f:
        for mid, m in gather(a.dirs, a.pool).items():
            for g in m["gaps"].values():
                f.write(json.dumps(dict(g, material=mid, materialName=m["name"])) + "\n")
                n += 1
    print(f"{n} gaps written to {a.out}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, fn in (("count", cmd_count), ("export", cmd_export)):
        s = sub.add_parser(name)
        s.add_argument("dirs", nargs="+", help="collection output folders, or folders above them")
        s.add_argument("--pool", help="count every folder given as one material, under this name")
        if name == "count":
            s.add_argument("--json", action="store_true")
        else:
            s.add_argument("--out", required=True)
        s.set_defaults(fn=fn)
    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
