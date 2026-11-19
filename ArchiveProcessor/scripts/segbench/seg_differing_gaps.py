#!/usr/bin/env python3
"""W46.seg-differing-gaps-sheet: an owner sheet for the gaps no one re-judged that decide the differing segmentation pairs.

seg-pair-ties.md §SEG-11 (owner, 2026-11-19 walkthrough: confirm the differing pairs): of the 16 route pairs the paired
interval separates, the documents right in one route only are decided at five Stanton gaps the owner never looked at
again since his capture labels (Stanton 20|21 in the pairs against the 27B teacher and in those against the 2B; 12|13,
170|171, 227|228 and 232|233 in the pairs against the 2B), every one for the winner. Neutralised, 7 of the 16 would tie.
This asks the owner about those gaps, blind to the routes' calls and to the truth at the asked gap.

  python3 seg_differing_gaps.py sheet              # the gaps from seg-pair-ties.json, the sheet in the bench cache
  python3 seg_differing_gaps.py fold ANSWERS.json  # his answers beside the truth (bench cache), nothing written to it
  python3 seg_differing_gaps.py apply              # the ruled changes into the Stanton truth CSV (copied first)

Run each under the heavy lock (`ops/autonomous/heavy-run.py run -- ...`; `sheet` runs Apple Vision's orientation check
and loads the boxes). No model call, upload or key. Owner images stay on this Mac: the key, pack and sheet are in
~/Library/Caches/ArchiveSuiteRehearsal/seg-differing-gaps/, never in git. The committed record
(segbench-results/seg-differing-gaps.json) holds page numbers and counts only. After `apply`, rerun seg_pair_ties.py
and settings_routes.py --check and compare each pair's verdict with the record's `before`.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import data  # noqa: E402
import seg_truth_audit as A  # noqa: E402

TAG = "W46.seg-differing-gaps-sheet"
OUT = A.REH / "seg-differing-gaps"
KEY = OUT / "key.json"              # the asked gaps' truth, never shown on the sheet
SHEET = OUT / "index.html"
RULINGS = OUT / "rulings.json"
BACKUP = OUT / "truth-before-fold"
TIES = A.RESULTS / "seg-pair-ties.json"
RECORD = A.RESULTS / "seg-differing-gaps.json"
STORE = "seg-differing-gaps-answers"
TITLE = "Segmentation truth: the gaps that decide the differing routes"
INTRO = """{n} gaps from the Stanton test box. They decide whether some segmentation routes really beat others, and
no one has looked at them again since the first labels."""
# The owner's answers once checked, box -> {right page: "New" | "Cont"} for every answer that differs from the truth,
# so a misread file cannot fold silently. None until the answers arrive: apply refuses.
EXPECTED: dict[str, dict[int, str]] | None = None


def asked() -> tuple[list[dict], dict]:
    """[{key, box, i, truth, pairs}] for every SEG-11 gap, in box order, and each differing pair's verdict now."""
    ties = json.loads(TIES.read_text())
    by_gap: dict[str, list[str]] = {}
    before = {}
    for p in ties["pairs"]:
        s = p.get("seg11")
        if not s:
            continue
        before[f"{p['a']} | {p['b']}"] = {"delta": p["delta"], "lo": p["lo"], "hi": p["hi"], "tie": p["tie"],
                                         "neutral_tie": s["neutral"]["tie"]}
        for g in s["gaps"]:
            by_gap.setdefault(g, []).append(f"{p['a']} | {p['b']}")
    from score import segment_ids
    cols = {n: data.load(n, with_exif=False) for n in data.TEST}
    out = []
    for g, pairs in by_gap.items():
        box, gap = g.split()
        left, right = (int(x) for x in gap.split("|"))
        col = cols[box]
        i = next(k for k, p in enumerate(col.pages) if p.n == left)
        assert col.pages[i + 1].n == right, g
        ids = segment_ids(col.labels)
        out.append({"key": g, "box": box, "i": i, "truth": "new" if ids[i] != ids[i + 1] else "continue",
                    "pairs": sorted(pairs)})
    out.sort(key=lambda g: (data.TEST.index(g["box"]), g["i"]))
    return out, before


def cmd_sheet(_a):
    key, before = asked()
    import seg_pair_ties as P
    if P.rejudged() & {g["key"] for g in key}:
        raise SystemExit("a SEG-11 gap is already re-judged: seg-pair-ties.json is stale, rerun seg_pair_ties.py")
    OUT.mkdir(parents=True, exist_ok=True)
    KEY.write_text(json.dumps({"tag": TAG, "items": key}, indent=1) + "\n")
    items, turned, close = A.build_sheet(key, OUT, unchecked_ok=True, tag=TAG)
    keys = {g["key"] for g in key}
    for it in items:   # an asked gap must never show as another card's unasked mark, which carries the truth
        shown = {f"{it['box']} {x['n']}|{y['n']}" for x, y in zip(it["strip"], it["strip"][1:]) if x["sep"] != "ask"}
        assert not shown & keys, (it["key"], shown & keys)
    unchecked = [c for c in close if c not in A.EYE_UPRIGHT]
    SHEET.write_text(A.render_sheet(items, turned, close, title=TITLE, intro=INTRO, store=STORE, unchecked=unchecked))
    RECORD.write_text(json.dumps({"tag": TAG, "date": dt.date.today().isoformat(), "asked": [g["key"] for g in key],
                                  "pairs_per_gap": {g["key"]: len(g["pairs"]) for g in key},
                                  "pages": sorted({p["n"] for it in items for p in it["strip"]}),
                                  "turned": turned, "close_calls": close, "unchecked_close_calls": unchecked,
                                  "before": before}, indent=1) + "\n")
    print(f"{len(items)} gaps, {len({p['path'] for it in items for p in it['strip']})} pages, {len(turned)} turned "
          f"upright {turned}, close calls {close} (unchecked {unchecked}); {SHEET}")


def cmd_fold(a):
    answers = json.loads(Path(a.answers).read_text())
    key = [g | {"stratum": "differing", "weight": 1.0, "consensus": None} for g in json.loads(KEY.read_text())["items"]]
    ids = answers.get("_keys") or {f"a{k + 1:02d}": g["key"] for k, g in enumerate(key)}
    saved, A.LATER = A.LATER, {}    # the audit's later rulings are other gaps
    try:
        out = A.fold(answers, key, ids)
    finally:
        A.LATER = saved
    RULINGS.write_text(json.dumps(out, indent=1) + "\n")
    print(f"{out['ruled']} ruled of {len(key)}, {out['differs']} differ from the truth; {RULINGS}")
    for r in out["rows"]:
        print(f"  {r['key']}: truth {r['truth']}, answer {r['answer']}{'  DIFFERS' if r['differs'] else ''}"
              f"{'  note: ' + r['note'] if r['note'] else ''}")
    if out["sheet_note"]:
        print(f"  sheet note: {out['sheet_note']}")


def cmd_apply(_a):
    from seg_truth_owner_fixes import fold_csv
    folded = json.loads(RULINGS.read_text())
    want = A.flips(folded["rows"])
    if EXPECTED is None or want != EXPECTED:
        raise SystemExit(f"set EXPECTED to the owner's checked answers first (folded: {want})")
    for box, flips in want.items():
        folder = data.DATA_DIR / data.COLLECTIONS[box]
        (csv_path,) = [p for p in folder.iterdir() if p.suffix.lower() == ".csv"]
        raw = csv_path.read_bytes()
        bom = raw.startswith(b"\xef\xbb\xbf")
        text = raw.decode("utf-8-sig")
        keep = BACKUP / f"{box}-{csv_path.name}"
        after = fold_csv(text, flips)
        if after != text and not keep.exists():
            BACKUP.mkdir(parents=True, exist_ok=True)
            shutil.copy2(csv_path, keep)
        if after != text:
            csv_path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + after.encode("utf-8"))
        got = {p.n: p.label for p in data.load(box, with_exif=False).pages}
        assert all(got[n] == lab for n, lab in flips.items()), (box, flips)
    record = json.loads(RECORD.read_text())
    record["fold"] = {"date": dt.date.today().isoformat(), "ruled": folded["ruled"], "differs": folded["differs"],
                      "changed": [{"key": r["key"], "truth_before": r["truth"], "answer": r["answer"]}
                                  for r in folded["rows"] if r["differs"]]}
    RECORD.write_text(json.dumps(record, indent=1) + "\n")
    print(f"folded {want}; now rerun seg_pair_ties.py and settings_routes.py --check; {RECORD}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sheet")
    f = sub.add_parser("fold")
    f.add_argument("answers")
    sub.add_parser("apply")
    a = ap.parse_args()
    {"sheet": cmd_sheet, "fold": cmd_fold, "apply": cmd_apply}[a.cmd](a)


if __name__ == "__main__":
    main()
