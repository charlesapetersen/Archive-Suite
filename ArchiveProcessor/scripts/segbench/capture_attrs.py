"""Join the truth set's per-page capture attributes (private pages.tsv) with the per-route page scores
(segbench-results/ocr-pages.csv) and report, per route: NES on typed/printed originals versus typed/printed PDF
images; Spearman rank correlation of NES with sharpness and long side within originals of one kind; camera means.
Read-only. Usage: python3 -I capture_attrs.py <pages.tsv> <ocr-pages.csv>
"""
import csv, sys
from collections import defaultdict
from statistics import mean, median


def rank(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    r = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        avg = (i + j) / 2 + 1
        for k in range(i, j + 1):
            r[order[k]] = avg
        i = j + 1
    return r


def spearman(x, y):
    if len(x) < 4:
        return float("nan")
    rx, ry = rank(x), rank(y)
    mx, my = mean(rx), mean(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return num / den if den else float("nan")


pages = {}
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        pages[row["page"]] = row

scores = defaultdict(dict)  # route -> page -> (ok, nes)
with open(sys.argv[2], newline="") as f:
    for row in csv.DictReader(f):
        try:
            nes = float(row["nes"]) * 100
        except ValueError:
            continue
        scores[row["route"]][row["page"]] = (row["ok"] == "True", nes, row["kind"])

# Page attribute summary
src = defaultdict(list)
for p, r in pages.items():
    src[(r["source"], r["kind"])].append(p)
print("pages by source and kind:")
for k in sorted(src):
    print(f"  {k[0]:28s} {k[1]:12s} {len(src[k])}")
orig = [r for r in pages.values() if r["source"] == "original"]
print(f"\noriginals: {len(orig)}; long side median {median(int(r['long_side']) for r in orig)}; "
      f"sharpness median {median(float(r['sharpness']) for r in orig):.0f}")
cams = defaultdict(list)
for r in orig:
    cams[r["camera"]].append(int(r["long_side"]))
for c, v in sorted(cams.items(), key=lambda kv: -len(kv[1])):
    print(f"  camera {c:22s} n={len(v):2d} long side {min(v)}-{max(v)}")

print("\nSharpness by kind among originals (median variance of Laplacian):")
sk = defaultdict(list)
for r in orig:
    sk[r["kind"]].append(float(r["sharpness"]))
for k, v in sk.items():
    print(f"  {k:12s} n={len(v):2d} median {median(v):.0f} min {min(v):.0f} max {max(v):.0f}")

print("\nPer route. 'typed+printed': kinds typewritten and printed. NES means over pages the route answered (ok)."
      " Spearman within typed+printed originals (ok pages). Columns: orig n/mean | pdf n/mean | diff | "
      "rho(sharp) | rho(long) | hand orig n/mean")
rows = []
for route in sorted(scores):
    s = scores[route]
    tp_orig, tp_pdf, hand = [], [], []
    xs_sharp, xs_long, ys = [], [], []
    fails_orig = fails_pdf = 0
    for p, (ok, nes, kind) in s.items():
        r = pages.get(p)
        if not r or r["status"] != "done":
            continue
        k = r["kind"]
        if k in ("typewritten", "printed"):
            if r["source"] == "original":
                if ok:
                    tp_orig.append(nes)
                    xs_sharp.append(float(r["sharpness"])); xs_long.append(int(r["long_side"])); ys.append(nes)
                else:
                    fails_orig += 1
            elif r["source"].startswith("pdf image (no"):
                if ok:
                    tp_pdf.append(nes)
                else:
                    fails_pdf += 1
        elif k in ("handwritten", "mixed") and r["source"] == "original" and ok:
            hand.append(nes)
    if not tp_orig or not tp_pdf:
        continue
    rows.append((route, len(tp_orig), mean(tp_orig), fails_orig, len(tp_pdf), mean(tp_pdf), fails_pdf,
                 spearman(xs_sharp, ys), spearman(xs_long, ys), len(hand), mean(hand) if hand else float("nan")))
for row in rows:
    (route, n1, m1, f1, n2, m2, f2, rs, rl, nh, mh) = row
    print(f"  {route:24s} {n1:2d}/{m1:5.1f} (fail {f1}) | {n2:2d}/{m2:5.1f} (fail {f2}) | {m2-m1:+5.1f} | "
          f"{rs:+.2f} | {rl:+.2f} | {nh:2d}/{mh:5.1f}")

# Sharpness tertiles within typed+printed originals, for a few routes, to see whether the global measure orders them
print("\nTyped+printed originals: NES by sharpness tertile (cuts within this subset) and by long-side bin")
tp = [r for r in orig if r["kind"] in ("typewritten", "printed")]
sh = sorted(float(r["sharpness"]) for r in tp)
c1, c2 = sh[len(sh) // 3], sh[2 * len(sh) // 3]
print(f"  cuts {c1:.0f} / {c2:.0f}, n={len(tp)}")
for route in sorted(scores):
    s = scores[route]
    b = defaultdict(list); lb = defaultdict(list)
    for r in tp:
        if r["page"] in s and s[r["page"]][0]:
            v = float(r["sharpness"]); nes = s[r["page"]][1]
            b["low" if v < c1 else "mid" if v < c2 else "high"].append(nes)
            ls = int(r["long_side"]); lb["<=2592" if ls <= 2592 else "2593-3500" if ls <= 3500 else ">3500"].append(nes)
    if b:
        print(f"  {route:24s} sharp low {mean(b['low']):5.1f}({len(b['low'])}) mid {mean(b['mid']):5.1f}({len(b['mid'])}) "
              f"high {mean(b['high']):5.1f}({len(b['high'])}) | long <=2592 {mean(lb['<=2592']) if lb['<=2592'] else float('nan'):5.1f}({len(lb['<=2592'])}) "
              f"2593-3500 {mean(lb['2593-3500']) if lb['2593-3500'] else float('nan'):5.1f}({len(lb['2593-3500'])}) >3500 {mean(lb['>3500']) if lb['>3500'] else float('nan'):5.1f}({len(lb['>3500'])})")

# Worst typed originals across routes: candidates for defect tagging
print("\nTyped+printed originals ranked by mean NES across routes (worst 12): page, mean, n routes, sharpness, long side, camera")
agg = defaultdict(list)
for route, s in scores.items():
    for p, (ok, nes, kind) in s.items():
        r = pages.get(p)
        if r and r["source"] == "original" and r["kind"] in ("typewritten", "printed") and ok:
            agg[p].append(nes)
worst = sorted(agg.items(), key=lambda kv: mean(kv[1]))[:12]
for p, v in worst:
    r = pages[p]
    print(f"  {p} {mean(v):5.1f} n={len(v):2d} sharp {float(r['sharpness']):6.0f} long {r['long_side']} {r['camera']} {r['kind']}")
