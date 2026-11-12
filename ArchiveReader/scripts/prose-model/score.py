#!/usr/bin/env python3
"""W40.reader-prose-model: score the rules and the on-device model against the blind drafts.

Truth is a row's label where both drafters (draft-qwen3-vl-8b, draft-gemma3-12b) agree; rows they dispute are left
out and counted. A page's first row labelled C counts as P (it starts something either way). Scored per arm:
  exact   the row's label, list level included;
  breaks  precision, recall and F1 of "a new unit starts here" (any label but C);
  H, I    recall of headings and of list-item starts (any level).
The deployable model arm is `fm+rules`: where the model refused or the word guard refused its result, the app
copies the rules' text, so the rules' labels stand there. The difference against the rules has a 95% interval
from 2,000 paired page resamples (seed 4011). Prints a markdown table; aggregates only, no page text.
usage: score.py CACHE_DIR
"""
import json
import random
import sys

d = sys.argv[1]


def load(name):
    try:
        return {r["id"]: r for r in map(json.loads, open(f"{d}/{name}.jsonl", encoding="utf-8"))}
    except FileNotFoundError:
        return {}


def norm(labels):
    labels = list(labels)
    if labels and labels[0] == "C":
        labels[0] = "P"
    return labels


rules = load("rules40")
ids = list(rules)
drafts = [load("draft-qwen3-vl-8b"), load("draft-gemma3-12b")]
arms = {"rules": {i: norm(rules[i]["labels"]) for i in ids}}
for name, f in [("fm", "fm40"), ("fm-image", "fm40-img"), ("fm-rerun", "fm40-rerun"),
                ("fm-permissive", "fm40-permissive"), ("fm-shot", "fm40-shot")]:
    recs = load(f)
    if not recs:
        continue
    answered = {i: norm(r["labels"]) for i, r in recs.items() if r.get("guardOK")}
    arms[name + " (answered)"] = answered
    arms[name + "+rules"] = {i: answered.get(i, arms["rules"][i]) for i in ids}
    refused = [r.get("error") or "word guard" for r in recs.values() if not r.get("guardOK")]
    print(f"{name}: {len(answered)}/{len(recs)} answered and passed the guard; not: {refused}")

truth, disputed, total = {}, 0, 0
for i in ids:
    ds = [x.get(i, {}).get("labels") for x in drafts]
    if not all(ds):
        continue
    a, b = norm(ds[0]), norm(ds[1])
    truth[i] = [x if x == y else None for x, y in zip(a, b)]
    total += len(a)
    disputed += sum(x != y for x, y in zip(a, b))
print(f"truth: {len(truth)} pages with both drafts, {total} rows, {disputed} disputed "
      f"({100 * disputed / max(total, 1):.0f}%), {total - disputed} agreed")
for k, x in enumerate(drafts):
    print(f"draft {k}: {sum(1 for r in x.values() if r.get('labels'))}/{len(x)} parsed")


def counts(arm, pages):
    c = dict(n=0, exact=0, tp=0, fp=0, fn=0, h=0, hn=0, it=0, itn=0)
    for i in pages:
        if i not in arm:
            continue
        for t, g in zip(truth[i], arm[i]):
            if t is None:
                continue
            c["n"] += 1
            c["exact"] += t == g
            tb, gb = t != "C", g != "C"
            c["tp"] += tb and gb
            c["fp"] += gb and not tb
            c["fn"] += tb and not gb
            if t == "H":
                c["hn"] += 1
                c["h"] += g == "H"
            if t.startswith("I"):
                c["itn"] += 1
                c["it"] += g.startswith("I")
    return c


def summary(c):
    p = c["tp"] / max(c["tp"] + c["fp"], 1)
    r = c["tp"] / max(c["tp"] + c["fn"], 1)
    return dict(exact=c["exact"] / max(c["n"], 1), p=p, r=r, f1=2 * p * r / max(p + r, 1e-9),
                h=c["h"] / max(c["hn"], 1), it=c["it"] / max(c["itn"], 1), n=c["n"], hn=c["hn"], itn=c["itn"])


def interval(arm, metric):
    pages = sorted(truth)
    rnd = random.Random(4011)
    diffs = []
    for _ in range(2000):
        s = [rnd.choice(pages) for _ in pages]
        diffs.append(summary(counts(arms[arm], s))[metric] - summary(counts(arms["rules"], s))[metric])
    diffs.sort()
    return diffs[50], diffs[1949]


pages = sorted(truth)
print("\n| arm | pages | rows | exact | break P | break R | break F1 | heading recall | item recall |")
print("|---|---|---|---|---|---|---|---|---|")
for name, arm in arms.items():
    on = [i for i in pages if i in arm]
    s = summary(counts(arm, on))
    print(f"| {name} | {len(on)} | {s['n']} | {s['exact']:.3f} | {s['p']:.3f} | {s['r']:.3f} | {s['f1']:.3f} | "
          f"{s['h']:.2f} of {s['hn']} | {s['it']:.2f} of {s['itn']} |")
print()
for name in arms:
    if name.endswith("+rules"):
        for m in ("exact", "f1"):
            d0 = summary(counts(arms[name], pages))[m] - summary(counts(arms["rules"], pages))[m]
            lo, hi = interval(name, m)
            print(f"{name} minus rules, {m}: {d0:+.3f} (95% {lo:+.3f} to {hi:+.3f})")
# Each drafter alone as truth, for the sensitivity of the verdict to the truth.
for k, x in enumerate(drafts):
    for name in ("rules", "fm+rules", "fm-image+rules", "fm-shot+rules"):
        if name not in arms:
            continue
        n = e = 0
        for i in pages:
            for t, g in zip(norm(x[i]["labels"]), arms[name][i]):
                if t is None:
                    continue
                n += 1
                e += t == g
        print(f"against draft {k} alone, {name}: exact {e / max(n, 1):.3f} over {n} rows")
# How far the two model arms and the rules agree with each other, truth aside.
for a, b in (("rules", "fm+rules"), ("rules", "fm-image+rules"), ("fm+rules", "fm-rerun+rules"),
             ("fm+rules", "fm-permissive+rules")):
    if a in arms and b in arms:
        n = sum(len(arms[a][i]) for i in ids)
        same = sum(x == y for i in ids for x, y in zip(arms[a][i], arms[b][i]))
        print(f"{a} vs {b}: {same}/{n} rows the same")
