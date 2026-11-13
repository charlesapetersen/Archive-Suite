#!/usr/bin/env python3
"""How long a person takes to check a flagged gap on the app's review screen (W46.seg-check-time).

  <torch-env python> check_time.py pack     # the flagged gaps of Stanton + RG165 at the app's level, their pages
                                            # copied into the bench cache and turned upright (no call, $0)
  <torch-env python> check_time.py score RUN.json [--notes NOTES.txt] [--preview]
                                            # -> segbench-results/seg-check-time.{json,md}

The settings sheet prices the user's own checking at 20 s a flagged boundary, a guess nobody had timed
(12-settings-design.md §3.9; 07-segmentation.md §7 call 6). This measures it: `pack` takes the gaps the app's Gemini
route flags on the two test boxes (prompt g2, Gemini 3.7's cached gateway answers, the shipped level <= 0.965, rule
min: seg-magazine-rule-app.md, 92 gaps), with the proposal, confidence and model cues the app would show, and the
owner checks them on the app's own "Check Flagged Boundaries" sheet (`scripts/time-flagged-checks.sh`, the Debug-only
FlaggedCheckTimingTestDriver). The driver logs every focus change and answer with its time; `score` turns that log into
seconds a boundary with n, and scores the answers against the boxes' truth.

Owner images stay on this Mac: the pack is in the bench cache, never in git (the repo is public). Truth is kept in a
file the app never reads, so the sheet shows exactly what a run would.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import random
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

TAG = "W46.seg-check-time"
REH = Path.home() / "Library/Caches/ArchiveSuiteRehearsal"
OUT = REH / "seg-check-time"
PACK = OUT / "pack.json"
TRUTH = OUT / "truth.json"          # never read by the app
PAGES = OUT / "pages"
RESULTS = HERE.parents[1] / "segbench-results"
HEAVY = HERE.parents[2] / "ops/autonomous/heavy-run.py"
ORIENT_BIN = REH / "segbench/bin/segbench-ocr-orient"
BOXES = ("Stanton", "RG165")
ASSUMED = 20.0                      # the settings sheet's assumption, seconds a flagged boundary
PAUSE = 120.0                       # a stay on one gap longer than this is reported as a likely pause
# Vision's best turn was not upright but not a clear win; each was looked at (2026-11-12) and is upright as taken
# (a folded clipping's sideways columns, a card with little text).
EYE_UPRIGHT = {"Stanton-059", "Stanton-091", "Stanton-197", "Stanton-198"}
TURN_RATIO, TURN_MIN = 2.0, 20.0    # item_fields_retruth: a turn wins only by twice every other and 20 characters


# --- pack ---------------------------------------------------------------------------------------------------------

def flagged(name, level):
    """[(gap index, proposal, confidence, cue, truth)] for the gaps the app's Gemini route flags on box `name`."""
    import data
    import ensemble as E
    import options as O
    import seg_magazine_rule_app as A
    col = data.load(name, with_exif=False)
    with A.arm(name) as (_, W, _, M):
        comb = M.combine_units(col, W.windows(len(col.pages)), A.answer)
    box = A.g2_box(name)
    with O.rule("min"):
        j = E.judge(box, ("G",), level)
    out = []
    for i in sorted(j):
        auto, flag, lo, _ = j[i]
        if flag:
            out.append((i, auto, lo, comb["gaps"][i]["cue"], box.truth[i], i in box.unsure))
    return col, out


def clear_turn(sc):
    """Degrees clockwise that show the page upright, from ocr_orient's (up, right, down, left) scores; 0 unless clear."""
    best = max(range(4), key=lambda k: sc[k])
    rest = [sc[k] for k in range(4) if k != best]
    if best and all(sc[best] >= TURN_RATIO * x for x in rest) and sc[best] - max(rest) >= TURN_MIN:
        return 90 * best
    return 0


def orient(paths):
    """{path: degrees clockwise}, Apple Vision at four turns, through the heavy lock."""
    if not ORIENT_BIN.exists():
        raise SystemExit(f"{ORIENT_BIN} is missing: swiftc -O {HERE / 'ocr_orient.swift'} -o {ORIENT_BIN}")
    lst = OUT / "orient-list.txt"
    lst.write_text("".join(f"{p}\n" for p in paths))
    r = subprocess.run(["python3", str(HEAVY), "run", "--", str(ORIENT_BIN), str(lst)], capture_output=True, text=True)
    scores = {}
    for line in r.stdout.splitlines():
        f = line.split("\t")
        if len(f) == 5 and f[0] in paths:
            scores[f[0]] = [float(x) for x in f[1:]]
    if r.returncode or len(scores) != len(paths):
        raise SystemExit(f"orient: rc {r.returncode}, {len(scores)} of {len(paths)} scored\n{r.stderr[-2000:]}")
    (OUT / "orient-scores.json").write_text(json.dumps(scores, indent=1))
    return {p: clear_turn(s) for p, s in scores.items()}


def cmd_pack(_a):
    level = json.loads((RESULTS / "seg-magazine-rule-app.json").read_text())["level"]
    OUT.mkdir(parents=True, exist_ok=True)
    PAGES.mkdir(exist_ok=True)
    items, truth = [], []
    for name in BOXES:
        col, gaps = flagged(name, level)
        for i, proposal, conf, cue, t, unsure in gaps:
            pair = []
            for p in (col.pages[i], col.pages[i + 1]):
                dest = PAGES / f"{name}-{p.n:03d}{p.path.suffix.lower()}"
                if not dest.exists():
                    shutil.copyfile(p.path, dest)   # read the box's image, write only the bench cache
                pair.append(str(dest))
            key = f"{name} {col.pages[i].n}|{col.pages[i + 1].n}"
            items.append({"key": key, "left": pair[0], "right": pair[1], "proposal": proposal,
                          "confidence": round(conf, 6), "cue": cue})
            truth.append({"key": key, "truth": t, "proposal": proposal, "unsure": unsure})
    turns = orient(sorted({x for it in items for x in (it["left"], it["right"])}))
    scores = json.loads((OUT / "orient-scores.json").read_text())
    close = sorted(Path(p).stem for p, sc in scores.items() if max(range(4), key=lambda k: sc[k]) and not turns[p])
    unchecked = [c for c in close if c not in EYE_UPRIGHT]
    if unchecked:
        raise SystemExit(f"close orientation calls not checked by eye: {unchecked}; look, then add to EYE_UPRIGHT")
    for it in items:
        it["left_rotation"], it["right_rotation"] = turns[it["left"]], turns[it["right"]]
    meta = {"tag": TAG, "date": dt.date.today().isoformat(), "boxes": list(BOXES), "level": level,
            "approach": "Gemini", "evidence": "prompt g2, Gemini 3.7 Flash's cached gateway answers, rule min "
            "(seg-magazine-rule-app.md)", "turned_pages": sum(v != 0 for v in turns.values()),
            "close_calls_upright_by_eye": close}
    PACK.write_text(json.dumps({**meta, "items": items}, indent=1) + "\n")
    TRUTH.write_text(json.dumps({**meta, "items": truth}, indent=1) + "\n")
    print(f"{len(items)} flagged gaps ({', '.join(f'{b} {sum(i['key'].startswith(b + ' ') for i in items)}' for b in BOXES)}),"
          f" {len(turns)} pages, {meta['turned_pages']} turned upright; {PACK}")


# --- score --------------------------------------------------------------------------------------------------------

def dwell(run):
    """{key: seconds the gap was in view} and the run's span, from the driver's event log. A gap is in view from the
    event that focused it to the next event that moved focus away, or to Done."""
    ev, keys = run["events"], [it["key"] for it in run["items"]]
    stay = {k: 0.0 for k in keys}
    focus, since = None, None
    for e in ev:
        if e["kind"] in ("focus", "done", "cancel"):
            if focus is not None:
                stay[keys[focus]] += e["t"] - since
            focus, since = (e.get("index"), e["t"]) if e["kind"] == "focus" else (None, None)
    start = next(e["t"] for e in ev if e["kind"] == "focus")
    end = next(e["t"] for e in ev if e["kind"] in ("done", "cancel"))
    return stay, end - start


def mean_ci(xs, reps=10000, seed=46):
    rnd = random.Random(seed)
    ms = sorted(statistics.fmean(rnd.choices(xs, k=len(xs))) for _ in range(reps))
    return statistics.fmean(xs), ms[int(0.025 * reps)], ms[int(0.975 * reps) - 1]


def cmd_score(a):
    run = json.loads(Path(a.run).read_text())
    truth = {t["key"]: t for t in json.loads(TRUTH.read_text())["items"]}
    notes = Path(a.notes).read_text().strip() if a.notes and Path(a.notes).exists() else ""
    if not run.get("done"):
        raise SystemExit("the run was cancelled before Done; score a finished run")
    stay, span = dwell(run)
    keys = [it["key"] for it in run["items"]]
    xs = [stay[k] for k in keys]
    pauses = [k for k in keys if stay[k] > PAUSE]
    kept = [stay[k] for k in keys if k not in pauses]
    q = statistics.quantiles(xs, n=4)
    m, lo, hi = mean_ci(xs)
    mk, lok, hik = mean_ci(kept) if kept else (None, None, None)
    ans = {it["key"]: it["answer"] for it in run["items"]}
    # The sheet asks only Split or Join (W46.seg-check-blind); a log with any other answer is not from that sheet.
    odd = sorted({ans[k] for k in keys} - {"split", "join"})
    if odd:
        raise SystemExit(f"the log holds answers the sheet no longer offers: {odd}; rerun on the current app")
    decision = {k: {"split": "new", "join": "continue"}[ans[k]] for k in keys}
    scored = [k for k in keys if not truth[k]["unsure"]]
    wrong = [k for k in scored if decision[k] != truth[k]["truth"]]
    prop_wrong = [k for k in scored if truth[k]["proposal"] != truth[k]["truth"]]
    first10 = statistics.median(xs[:10]); rest = statistics.median(xs[10:]) if len(xs) > 10 else None
    figure = mk if pauses and mk is not None else m
    out = {"tag": TAG, "date": dt.date.today().isoformat(), "run": str(a.run), "n": len(xs), "figure_s": figure,
           "figure_n": len(kept) if pauses else len(xs),
           "span_s": span, "per_boundary_s": span / len(xs), "mean_s": m, "mean_ci95": [lo, hi],
           "median_s": statistics.median(xs), "quartiles_s": [q[0], q[2]], "max_s": max(xs),
           "pauses_over_s": PAUSE, "pauses": {k: stay[k] for k in pauses},
           "mean_without_pauses_s": mk, "mean_without_pauses_ci95": [lok, hik],
           "median_first10_s": first10, "median_after10_s": rest,
           "changed": sum(decision[k] != truth[k]["proposal"] for k in keys),
           "proposal_wrong": len(prop_wrong), "answers_wrong": wrong, "scored": len(scored),
           "unsure": len(keys) - len(scored), "assumed_s": ASSUMED, "display": run.get("display"),
           "notes": notes, "per_gap_s": stay}
    if not a.preview:
        (RESULTS / "seg-check-time.json").write_text(json.dumps(out, indent=1) + "\n")
        (RESULTS / "seg-check-time.md").write_text(render(out, json.loads(TRUTH.read_text())))
    print(json.dumps({k: out[k] for k in ("n", "figure_s", "figure_n", "per_boundary_s", "mean_s", "mean_ci95", "median_s", "pauses",
                                          "answers_wrong")}, indent=1))


def render(o, pack):
    f = lambda x: "—" if x is None else f"{x:.1f} s"
    L = [f"# How long a flagged gap takes to check ({TAG})", "",
         "Generated by `ArchiveProcessor/scripts/segbench/check_time.py score` from the timing log of one owner session "
         "on the app's own review screen (`scripts/time-flagged-checks.sh`). No model call.", "",
         f"**{f(o['figure_s'])} a flagged boundary, n = {o['figure_n']}** (the mean time a gap was in view"
         + (f", {len(o['pauses'])} stays over {o['pauses_over_s']:.0f} s left out as pauses" if o["pauses"] else "")
         + f"), against the settings sheet's assumed {o['assumed_s']:.0f} s.", "",
         "| | seconds |", "|---|---:|",
         f"| span from the first gap to Done, / n, pauses included | {o['per_boundary_s']:.1f} |",
         f"| mean time in view, 95% bootstrap interval | {o['mean_s']:.1f} ({o['mean_ci95'][0]:.1f}–{o['mean_ci95'][1]:.1f}) |",
         f"| median, quartiles | {o['median_s']:.1f} ({o['quartiles_s'][0]:.1f}–{o['quartiles_s'][1]:.1f}) |",
         f"| longest | {o['max_s']:.1f} |",
         f"| mean without stays over {o['pauses_over_s']:.0f} s ({len(o['pauses'])} left out) | {f(o['mean_without_pauses_s'])} |",
         f"| median of the first 10, of the rest | {f(o['median_first10_s'])}, {f(o['median_after10_s'])} |", "",
         f"Answers against the boxes' truth: {o['scored']} gaps scored ({o['unsure']} the owner left unsure), the "
         f"proposal wrong on {o['proposal_wrong']}, the owner's answer wrong on {len(o['answers_wrong'])}"
         + (f" ({', '.join(o['answers_wrong'])})" if o["answers_wrong"] else "") + ".", ""]
    if o["notes"]:
        L += ["## The owner's notes", "", o["notes"], ""]
    L += ["## Measurement card", "",
          f"- **Truth.** The times are the owner's own, logged by the Debug-only FlaggedCheckTimingTestDriver on the app's "
          "Check Flagged Boundaries sheet (each focus change and answer, monotonic clock). The answers are scored "
          "against the owner's truth for Stanton and RG165, which the owner made earlier: he has seen these pages "
          "before, so the times may be lower than a user's on unseen material.",
          f"- **Selection.** Every gap the app's Gemini route flags on the two test boxes at the shipped level "
          f"({pack['evidence']}, level <= {pack['level']}), {o['n']} gaps in run order; nothing chosen by the time "
          f"it takes or by ABBYY text. {pack['turned_pages']} pages turned upright by Apple Vision's clear wins; "
          f"{len(pack['close_calls_upright_by_eye'])} close calls looked at and upright as taken.",
          "- **Comparison.** One reader, one session, one screen" + (f" ({o['display']})" if o.get("display") else "")
          + "; the 20 s it replaces was an assumption, not a measurement.",
          "- **Noise.** n as above; the interval is a bootstrap over gaps within this one session. Between-session "
          "and between-reader spread are not measured.",
          "- **Scope.** The time to answer a gap the app flagged, on letters and office files (Stanton) and typed "
          "government files (RG165). It does not cover the skim after the flagged pass, other readers, or material "
          "the reader has not seen.", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("pack").set_defaults(fn=cmd_pack)
    s = sub.add_parser("score")
    s.add_argument("run")
    s.add_argument("--notes")
    s.add_argument("--preview", action="store_true", help="print the figures, write nothing")
    s.set_defaults(fn=cmd_score)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
