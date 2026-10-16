"""W41.bench-difficulty: page difficulty, failures apart from accuracy, and cascades, from the per-page tables.

Reads ../ArchiveProcessor/segbench-results/ocr-pages.csv and ocr-pages-agree.csv (written by
scripts/segbench/ocr_pages_export.py from the panels' private caches) and FarmShare's bulk summary.json. build.py
calls analyse() with each route's bench price and name, embeds the result in the page, and writes report() to
difficulty.md. Standard library only; deterministic (the split-half check uses a fixed seed).
"""
import csv
import itertools
import json
import math
import random
import statistics
from collections import defaultdict
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "ArchiveProcessor" / "segbench-results"
PAGES_CSV = RESULTS / "ocr-pages.csv"
AGREE_CSV = RESULTS / "ocr-pages-agree.csv"
BULK = RESULTS / "farmshare" / "bulk" / "summary.json"
BULK_PAGES = RESULTS / "farmshare" / "bulk" / "pages.csv"
BULK_VISION = RESULTS / "farmshare" / "bulk" / "vision-kind.csv"   # W41.bench-vision-kind
VISION_KINDS = ("newspaper", "photograph", "handwriting", "other")

WRONG = 0.90            # an answered page below this NES counts as a poor reading (answered but wrong)
TIERS = ("easy", "middle", "hard")
FLAG_KINDS = {"handwritten", "mixed"}
CHEAP_PRICE = 1.0       # $ per 1,000 pages: a first stage or a disagreement reader must cost no more than this
THRESHOLDS = (0.80, 0.85, 0.90, 0.95)
BUDGETS = (0, 0.5, 1, 2, 5, 25)
SPLITS = 200


def load():
    with PAGES_CSV.open(newline="") as f:
        rows = list(csv.DictReader(f))
    with AGREE_CSV.open(newline="") as f:
        agree = {}
        for r in csv.DictReader(f):
            agree[(r["a"], r["b"], r["page"])] = agree[(r["b"], r["a"], r["page"])] = float(r["nes"])
    return rows, agree


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else None


def r2(x):
    return None if x is None else round(100 * x, 2)


def auc(pos, neg):
    """Chance a random positive scores above a random negative (ties half): 0.5 is no signal."""
    if not pos or not neg:
        return None
    return sum((p > n) + 0.5 * (p == n) for p in pos for n in neg) / (len(pos) * len(neg))


def two_way(nes, ok, routes, pages):
    """NES = mu + ability[route] + easiness[page], fitted on answered readings only by alternating means.
    A route's mu + ability is its NES on a page of average difficulty, whichever pages it happened to answer."""
    a = {r: 0.0 for r in routes}
    e = {p: 0.0 for p in pages}
    cells = [(r, p) for r in routes for p in pages if ok[r][p]]
    mu = mean(nes[r][p] for r, p in cells)
    for _ in range(200):
        for r in routes:
            a[r] = mean(nes[r][p] - mu - e[p] for p in pages if ok[r][p])
        m = mean(a.values())
        a = {r: v - m for r, v in a.items()}
        for p in pages:
            e[p] = mean(nes[r][p] - mu - a[r] for r in routes if ok[r][p])
        m = mean(e.values())
        e = {p: v - m for p, v in e.items()}
    return mu, a, e


def tiers_of(score):
    """Thirds of the pages by a difficulty score (higher = harder): 32 easy, 32 middle, 32 hard."""
    order = sorted(score, key=lambda p: (score[p], p))
    n = len(order)
    return {p: TIERS[min(2, 3 * i // n)] for i, p in enumerate(order)}


def analyse(prices, names, app_routes):
    """prices: route -> standard $ per 1,000 pages (the bench's); names: route -> display name; app_routes: the
    routes a user of the app could run (hosted, Apple Vision, the Mac), against which cascades are built."""
    rows, agree = load()
    routes = list(dict.fromkeys(r["route"] for r in rows))
    pages = sorted({r["page"] for r in rows})
    nes, ok, kind, said, cost, words, hyp = (defaultdict(dict) for _ in range(7))
    vkind = {}  # Vision OCR's page kind (W41.bench-vision-kind), the same for every route; "" where not measured
    for r in rows:
        x, p = r["route"], r["page"]
        nes[x][p], ok[x][p] = float(r["nes"]), r["ok"] == "True"
        kind[p], said[x][p], words[p], hyp[x][p] = r["kind"], r["said_kind"], int(r["words"]), int(r["hyp_words"])
        vkind[p] = r.get("vision_kind") or ""
        cost[x][p] = float(r["cost"])
    # Each page's price: the route's bench price shared out by its measured per-page cost where it has one, so a
    # cascade that escalates long pages pays for long pages; a route with no per-page record pays its average.
    for x in routes:
        total = sum(cost[x].values())
        per = prices[x] / 1000
        cost[x] = {p: (per * len(pages) * cost[x][p] / total if total else per) for p in pages}

    # (2) difficulty: leave-one-out mean answered NES of the other routes, and the two-way fit.
    loo = {x: {p: 1 - mean(nes[y][p] for y in routes if y != x and ok[y][p]) for p in pages} for x in routes}
    all_diff = {p: 1 - mean(nes[y][p] for y in routes if ok[y][p]) for p in pages}
    fails_on = {p: sum(not ok[y][p] for y in routes) for p in pages}
    mu, ability, easiness = two_way(nes, ok, routes, pages)
    tier_all = tiers_of(all_diff)

    # (1) and (3) per route
    per_route = []
    for x in routes:
        ans = [p for p in pages if ok[x][p]]
        failed = [p for p in pages if not ok[x][p]]
        t = tiers_of(loo[x])
        rank = {p: i for i, p in enumerate(sorted(pages, key=lambda p: (loo[x][p], p)))}
        by_tier = {}
        for tier in TIERS:
            pp = [p for p in pages if t[p] == tier]
            aa = [p for p in pp if ok[x][p]]
            by_tier[tier] = {"answered_nes": r2(mean(nes[x][p] for p in aa)), "failed": len(pp) - len(aa), "n": len(pp),
                             "wrong": sum(nes[x][p] < WRONG for p in aa)}
        by_kind = {}
        for k in sorted(set(kind.values())):
            pp = [p for p in pages if kind[p] == k]
            aa = [p for p in pp if ok[x][p]]
            by_kind[k] = {"answered_nes": r2(mean(nes[x][p] for p in aa)), "failed": len(pp) - len(aa), "n": len(pp)}
        expected = mean(mu + ability[x] + easiness[p] for p in ans)  # what an average route would score on these pages
        per_route.append({
            "id": x, "name": names[x], "price": prices[x], "app": x in app_routes,
            "strict": r2(mean(nes[x].values())), "answered": len(ans), "failed": len(failed),
            "answered_nes": r2(mean(nes[x][p] for p in ans)),
            "adjusted": r2(mu + ability[x]),
            "page_mix": r2(mean(mu + easiness[p] for p in ans) - mu),  # + = it answered easier pages than average
            "wrong": sum(nes[x][p] < WRONG for p in ans),
            "fail_pctile": round(100 * mean(rank[p] / (len(pages) - 1) for p in failed)) if failed else None,
            "fail_hard": sum(t[p] == "hard" for p in failed),
            "fail_kinds": {k: sum(kind[p] == k for p in failed) for k in sorted({kind[p] for p in failed})},
            "by_tier": by_tier, "by_kind": by_kind})
    per_route.sort(key=lambda r: -r["answered_nes"])

    # difficulty curves: pages sorted by the all-route difficulty, in six bins of 16
    order = sorted(pages, key=lambda p: (all_diff[p], p))
    bins = [order[i * len(order) // 6:(i + 1) * len(order) // 6] for i in range(6)]
    curves = {"bins": [{"n": len(b), "difficulty": r2(mean(all_diff[p] for p in b)),
                        "kinds": {k: sum(kind[p] == k for p in b) for k in sorted(set(kind.values()))},
                        "route_failures": sum(fails_on[p] for p in b)} for b in bins],
              "routes": {x: [{"nes": r2(mean(nes[x][p] for p in b if ok[x][p])), "failed": sum(not ok[x][p] for p in b)}
                             for b in bins] for x in routes}}

    # (4) cascades. A candidate is a list of stages; each page goes to the first stage, and on to the next when the
    # trigger fires. Its NES on a page is the last stage it reached (0 if that stage failed too).
    cheap = [x for x in app_routes if prices[x] <= CHEAP_PRICE]

    def run(stages, trigger, skip=None):
        """skip(i, x, p): send the page past stage i unread and unpaid (a routing rule that needs no reading)."""
        out_n, out_c, out_esc, out_f = [], [], 0, 0
        for p in pages:
            c, got = 0.0, None
            for i, x in enumerate(stages):
                if skip and i < len(stages) - 1 and skip(i, x, p):
                    out_esc += i == 0
                    continue
                c += cost[x][p]
                if i == len(stages) - 1 or not trigger(i, x, p):
                    got = nes[x][p] if ok[x][p] else 0.0
                    out_f += not ok[x][p]
                    break
                out_esc += i == 0
            out_n.append(got); out_c.append(c)
        return out_n, out_c, out_esc, out_f

    cands = []

    def add(label, stages, trigger, kind_="fail", extra_cost=None, skip=None):
        n_, c_, esc, failed = run(stages, trigger, skip)
        if extra_cost:
            c_ = [c + extra_cost[p] for c, p in zip(c_, pages)]
        cands.append({"label": label, "stages": stages, "trigger": kind_, "nes_pages": n_, "cost_pages": c_,
                      "escalated": esc, "failed": failed})

    fail = lambda i, x, p: not ok[x][p]
    for x in app_routes:
        add(names[x], [x], fail, "single")
    for a, b in itertools.permutations(app_routes, 2):
        add(f"{names[a]} → {names[b]}", [a, b], fail)  # any route, with its failures sent on
        if prices[a] <= CHEAP_PRICE:
            if any(said[a].values()):
                add(f"{names[a]} → {names[b]} (and its handwritten or mixed pages)", [a, b],
                    lambda i, x, p: not ok[x][p] or said[x][p] in FLAG_KINDS, "fail+kind")
            # Vision's page sorter routes before any reading: its handwriting pages go straight to b, unpaid at a.
            if all(vkind.values()):
                add(f"{names[a]} → {names[b]} (Vision's handwriting pages straight to {names[b]})", [a, b], fail,
                    "fail+vision", skip=lambda i, x, p: vkind[p] == "handwriting")
    for a, b in itertools.permutations(cheap, 2):
        for c in app_routes:
            if c not in (a, b):
                add(f"{names[a]} → {names[b]} → {names[c]}", [a, b, c], fail)
    # two cheap readers: keep a's text when it agrees with b's, else escalate to c; b's reading is paid on every page
    for a, b in itertools.permutations([x for x in cheap if any((x, y, pages[0]) in agree for y in cheap)], 2):
        if not any((a, b, p) in agree for p in pages):
            continue
        for t in THRESHOLDS:
            for c in app_routes:
                if c in (a, b):
                    continue
                trig = (lambda t: lambda i, x, p: not ok[x][p] or agree.get((a, b, p), 0.0) < t)(t)
                add(f"{names[a]}, checked against {names[b]} at {t:.2f} → {names[c]}", [a, c], trig,
                    f"disagree@{t:.2f}", extra_cost=cost[b])
    for cd in cands:
        cd["nes"] = mean(cd["nes_pages"])
        cd["usd"] = 1000 * mean(cd["cost_pages"])

    def frontier(cs):
        best, out = -1, []
        for cd in sorted(cs, key=lambda c: (c["usd"], -c["nes"])):
            if cd["nes"] > best + 1e-12:
                out.append(cd); best = cd["nes"]
        return out

    front = frontier(cands)
    singles = frontier([c for c in cands if c["trigger"] == "single"])

    # split-half check: choose the best candidate under a budget on half the pages, score it on the other half
    # Picking the best of thousands of candidates on 96 pages flatters the pick, so each family (one route; escalate
    # on failure; on failure or a hard kind; on disagreement) is also chosen on a random half and scored on the other.
    for cd in cands:
        cd["family"] = cd["trigger"].split("@")[0]
    families = list(dict.fromkeys(cd["family"] for cd in cands))
    near = {}
    for fam in families:
        fc = [c for c in cands if c["family"] == fam]
        ff = frontier(fc)
        near[fam] = [c for c in fc if c["nes"] >= max(f["nes"] for f in ff if f["usd"] <= c["usd"] + 1e-9) - 0.02]
    rng = random.Random(41)
    idx = list(range(len(pages)))
    split = {(fam, b): {"in": [], "out": []} for fam in families for b in BUDGETS}
    for _ in range(SPLITS):
        rng.shuffle(idx)
        A, B = idx[:len(idx) // 2], idx[len(idx) // 2:]
        for fam in families:
            for b in BUDGETS:
                pool = [c for c in near[fam] if c["usd"] <= b + 1e-9]
                if not pool:
                    continue
                pick = max(pool, key=lambda c: (sum(c["nes_pages"][i] for i in A), -c["usd"]))
                split[(fam, b)]["in"].append(mean(pick["nes_pages"][i] for i in A))
                split[(fam, b)]["out"].append(mean(pick["nes_pages"][i] for i in B))
    budgets = []
    for b in BUDGETS:
        row = {"budget": b, "families": {}}
        for fam in families:
            pool = [c for c in cands if c["family"] == fam and c["usd"] <= b + 1e-9]
            if pool:
                s = split[(fam, b)]
                row["families"][fam] = {"best": slim(max(pool, key=lambda c: (c["nes"], -c["usd"]))),
                                        "split_in": r2(mean(s["in"])), "split_out": r2(mean(s["out"]))}
        budgets.append(row)

    # (5) what flags an answered-but-wrong page, for each cheap reader
    flags = []
    vision = "apple-vision"
    for x in cheap:
        ans = [p for p in pages if ok[x][p]]
        wrong = {p for p in ans if nes[x][p] < WRONG}
        if not wrong:
            continue
        sig = {}
        if any(said[x].values()):
            sig["said handwritten or mixed"] = {p: float(said[x][p] in FLAG_KINDS) for p in ans}
        if all(vkind.values()):
            sig["Vision: handwriting"] = {p: float(vkind[p] == "handwriting") for p in ans}
        if x != vision:
            sig["length against Apple Vision's"] = {p: abs(math.log((hyp[x][p] + 1) / (hyp[vision][p] + 1))) for p in ans}
        partners = []
        for y in cheap:
            if y != x and all((x, y, p) in agree for p in ans):
                s = {p: 1 - agree[(x, y, p)] for p in ans}
                partners.append((auc([s[p] for p in wrong], [s[p] for p in ans if p not in wrong]), y, s))
        if partners:
            a_, y, s = max(partners, key=lambda t: (t[0] or 0, t[1]))
            sig[f"disagrees with {names[y]}"] = s
        out = {}
        for label, s in sig.items():
            top = sorted(ans, key=lambda p: (-s[p], p))[:max(1, round(0.2 * len(ans)))]
            out[label] = {"auc": round(auc([s[p] for p in wrong], [s[p] for p in ans if p not in wrong]), 3),
                          "caught_at_20": sum(p in wrong for p in top)}
        flags.append({"id": x, "name": names[x], "answered": len(ans), "wrong": len(wrong),
                      "wrong_kinds": {k: sum(kind[p] == k for p in wrong) for k in sorted({kind[p] for p in wrong})},
                      "signals": out})

    bulk = json.loads(BULK.read_text()) if BULK.exists() else None
    vision_kind = vision_kinds(pages, kind, vkind, all_diff, fails_on, tier_all, said, routes) if all(vkind.values()) else None
    hardest = sorted(pages, key=lambda p: -all_diff[p])[:10]
    return {
        "pages": len(pages), "routes_n": len(routes), "wrong_bar": r2(WRONG), "mu": r2(mu),
        "routes": per_route,
        "difficulty": {"tier_kinds": {t: {k: sum(kind[p] == k and tier_all[p] == t for p in pages)
                                          for k in sorted(set(kind.values()))} for t in TIERS},
                       "tier_mean": {t: r2(1 - mean(all_diff[p] for p in pages if tier_all[p] == t)) for t in TIERS},
                       "hardest": [{"kind": kind[p], "mean_nes": r2(1 - all_diff[p]), "failed_by": fails_on[p]} for p in hardest],
                       "fail_corr": round(statistics.correlation([all_diff[p] for p in pages], [fails_on[p] for p in pages]), 2)},
        "curves": curves,
        "cascades": {"n": len(cands), "frontier": [slim(c) for c in front], "singles": [slim(c) for c in singles],
                     "budgets": budgets,
                     "family_frontiers": {fam: [slim(c) for c in frontier([c for c in cands if c["family"] == fam])]
                                          for fam in families}},
        "flags": flags,
        "bulk": {k: bulk["by_kind"][k] for k in bulk["by_kind"]} if bulk else None,
        "bulk_total": {"pages": bulk["pages"], "failed": bulk["failed"]} if bulk else None,
        "bulk_failures": bulk["failures"] if bulk else None,
        "vision_kind": vision_kind,
    }


def vision_kinds(pages, kind, vkind, all_diff, fails_on, tier_all, said, routes):
    """W41.bench-vision-kind: Vision OCR's page kind against the truth's kind and the models' labels, on the panel's
    pages, and against the bulk model's label and its failures on the 2,000 bulk pages."""
    present = [k for k in VISION_KINDS if any(vkind[p] == k for p in pages)]
    truth_kinds = sorted(set(kind.values()))
    panel = {v: {"n": sum(vkind[p] == v for p in pages),
                 "truth": {k: sum(vkind[p] == v and kind[p] == k for p in pages) for k in truth_kinds},
                 "tiers": {t: sum(vkind[p] == v and tier_all[p] == t for p in pages) for t in TIERS},
                 "mean_nes": r2(1 - mean(all_diff[p] for p in pages if vkind[p] == v)),
                 "route_failures": sum(fails_on[p] for p in pages if vkind[p] == v)} for v in present}
    hand = [p for p in pages if kind[p] == "handwritten"]
    called = [p for p in pages if vkind[p] == "handwriting"]
    # The models' own labels on the same pages, for comparison: how often each says handwritten on a handwritten page.
    said_hand = [r for r in routes if any(said[r].values())]
    model_recall = {r: sum(said[r][p] == "handwritten" for p in hand) for r in said_hand}
    model_prec = {r: (sum(kind[p] == "handwritten" for p in pages if said[r][p] == "handwritten"),
                      sum(said[r][p] == "handwritten" for p in pages)) for r in said_hand}
    out = {"panel": panel, "present": present, "truth_kinds": truth_kinds,
           "hand": {"truth": len(hand), "called": len(called), "both": sum(kind[p] == "handwritten" for p in called),
                    "called_kinds": {k: sum(kind[p] == k for p in called) for k in truth_kinds}},
           "model_hand": {"routes": len(said_hand),
                          "recall": [min(model_recall.values()), max(model_recall.values())] if said_hand else None,
                          "precision": [min(a / b for a, b in model_prec.values() if b),
                                        max(a / b for a, b in model_prec.values() if b)] if said_hand else None}}
    if BULK_VISION.exists() and BULK_PAGES.exists():
        with BULK_VISION.open(newline="") as f:
            bv = {r["page"]: r for r in csv.DictReader(f)}
        with BULK_PAGES.open(newline="") as f:
            bp = {r["page"]: r for r in csv.DictReader(f)}
        both = sorted(set(bv) & set(bp))
        labels = sorted({bp[p]["kind"] for p in both if bp[p]["kind"]})
        failed = lambda p: bp[p]["status"] != "ok"  # noqa: E731
        out["bulk"] = {
            "pages": len(both), "unread": len(set(bp) - set(bv)),
            "by_kind": {v: {"pages": sum(bv[p]["vision_kind"] == v for p in both),
                            "failed": sum(bv[p]["vision_kind"] == v and failed(p) for p in both),
                            "labels": {k: sum(bv[p]["vision_kind"] == v and bp[p]["kind"] == k for p in both)
                                       for k in labels},
                            "unlabelled": sum(bv[p]["vision_kind"] == v and not bp[p]["kind"] for p in both)}
                        for v in VISION_KINDS if any(bv[p]["vision_kind"] == v for p in both)},
            "labels": labels,
            "hand_signal": sum(bv[p]["hand"] == "1" for p in both),
            "photo_signal": sum(bv[p]["photo"] == "1" for p in both)}
    return out


def slim(c):
    return {"label": c["label"], "stages": c["stages"], "trigger": c["trigger"], "nes": r2(c["nes"]),
            "family": c["trigger"].split("@")[0], "usd": round(c["usd"], 2), "escalated": c["escalated"],
            "failed": c["failed"]}


FAMILY = {"single": "one route", "fail": "escalate on failure", "fail+kind": "on failure or a handwritten/mixed label",
          "disagree": "on failure or two cheap readers disagreeing",
          "fail+vision": "on failure, Vision's handwriting pages sent straight on"}


def f2(x, signed=False):
    return "–" if x is None else (f"{x:+.2f}" if signed else f"{x:.2f}")


def money(x):
    return "free" if x == 0 else f"${x:.2f}"


def vision_verdict(d):
    """Whether routing Vision's handwriting pages straight to the stronger route held up on unseen pages."""
    v = d.get("vision_kind")
    if not v:
        return "unmeasured"
    out = {b["budget"]: b["families"] for b in d["cascades"]["budgets"]}
    gains = [out[b]["fail+vision"]["split_out"] - out[b]["fail"]["split_out"]
             for b in out if 0 < b <= 5 and "fail+vision" in out[b] and "fail" in out[b]]
    return "gain" if gains and min(gains) > 0.25 else "none"


VISION_RULE = {
    "unmeasured": "A page sorter that does not depend on the model being judged (the Vision OCR lab's `pageKind`) "
                  "could route handwriting before any paid call; it has not been run on these pages.",
    "gain": "5. Before step 1, send the pages Vision OCR's page sorter calls handwriting straight to the stronger "
            "route: it needs no model and no paid call, and on unseen pages it added to escalation on failure at "
            "every paid budget up to $5 (part 6).",
    "none": "Vision OCR's page sorter (part 6) is not part of the rule: sending its handwriting pages straight to the "
            "stronger route did not gain at every paid budget on unseen pages, so on these 96 pages it is a free "
            "label and a predictor of difficulty rather than a routing step.",
}


def vision_report(d):
    """Part 6: Vision OCR's page kind, a label that does not depend on the model being judged."""
    v = d.get("vision_kind")
    if not v:
        return []
    P, tk = v["panel"], v["truth_kinds"]
    L = ["## 6. Vision OCR's page kind, a label no model gives", "",
         "The Vision OCR lab's page sorter (`Recogniser.pageKind` in its `Sources/Recogniser.swift`) calls a page "
         "newspaper, photograph, handwriting or other from Apple Vision's reading of it: the number and width of its "
         "lines, the colour and lighting of the paper, and the shape of the ink along each line. It runs on the Mac, "
         "with no model and no paid call, so it can route a page before anything reads it, and it does not depend on "
         "the route being judged. Run with `scripts/segbench/vision_kind/run.sh` on the panel's originals and the "
         "bulk pilot's pages, as the app judges a page (the differences are in that tool's header); a newspaper or "
         "handwritten page outranks a photograph, so a photographed letter in a hand is handwriting.", "",
         f"On the {d['pages']} accuracy pages, against the truth's kind:", "",
         "| Vision's kind | pages | " + " | ".join(tk) + " | easy | middle | hard | mean NES of all routes | route failures |",
         "|---|---:|" + "---:|" * len(tk) + "---:|---:|---:|---:|---:|"]
    for k in v["present"]:
        r = P[k]
        L.append(f"| {k} | {r['n']} | " + " | ".join(str(r["truth"][t]) for t in tk) + " | "
                 + " | ".join(str(r["tiers"][t]) for t in TIERS) + f" | {f2(r['mean_nes'])} | {r['route_failures']} |")
    h, mh = v["hand"], v["model_hand"]
    typed = lambda k: sum(P[k]["truth"].get(t, 0) for t in ("typewritten", "printed")) if k in P else 0  # noqa: E731
    L += ["", f"It calls {h['called']} pages handwriting, {h['both']} of them handwritten in the truth "
          f"({', '.join(f'{n} {k}' for k, n in h['called_kinds'].items() if n and k != 'handwritten') or 'no others'}), "
          f"and finds {h['both']} of the truth's {h['truth']} handwritten pages. "
          + (f"The models' own labels, for comparison: the {mh['routes']} routes that label a page say handwritten on "
             f"{mh['recall'][0]} to {mh['recall'][1]} of those {h['truth']} pages, and are right {100 * mh['precision'][0]:.0f}% "
             f"to {100 * mh['precision'][1]:.0f}% of the times they say it. " if mh["recall"] else "")
          + f"Typed and printed pages are photograph ({typed('photograph')}) or other ({typed('other')}, a page whose "
          "light reads as a scan's): the sorter separates handwriting and newspapers from the rest and says nothing "
          "about typewritten against printed."
          + (f" The pages it calls handwriting are hard ones, {P['handwriting']['tiers']['hard']} of "
             f"{P['handwriting']['n']} in the hard third, so it predicts difficulty before anything reads the page."
             if "handwriting" in P else ""), ""]
    out = {b["budget"]: b["families"] for b in d["cascades"]["budgets"]}
    paid = [b for b in out if 0 < b <= 5 and "fail+vision" in out[b]]
    vis = [s for f in d["flags"] for k, s in f["signals"].items() if k == "Vision: handwriting"]
    if vis:
        L += [f"**As a flag for a poor reading** (part 5), Vision's handwriting call has AUC {min(s['auc'] for s in vis):.2f} "
              f"to {max(s['auc'] for s in vis):.2f} across the cheap readers, against {min(s['auc'] for f in d['flags'] for k, s in f['signals'].items() if k.startswith('said')):.2f} "
              f"to {max(s['auc'] for f in d['flags'] for k, s in f['signals'].items() if k.startswith('said')):.2f} for the readers' own labels. "
              "Poor readings are spread over typed and printed pages too, so no kind label can find most of them.", ""]
    if paid:
        L += ["**As a routing rule** (part 4's cascades, with a fifth family): the pages Vision calls handwriting go "
              "straight to the second route, unread and unpaid by the first, and the first route's failures follow "
              "them. Chosen on half the pages and scored on the other half, against escalation on failure alone: "
              + ", ".join(f"{out[b]['fail+vision']['split_out'] - out[b]['fail']['split_out']:+.2f} at ${b}" for b in paid)
              + f" NES. The best such cascade on all pages at $1 per 1,000: {out[1]['fail+vision']['best']['label']}, "
              f"{f2(out[1]['fail+vision']['best']['nes'])} NES for {money(out[1]['fail+vision']['best']['usd'])}.", ""]
    b = v.get("bulk")
    if b:
        labels = b["labels"]
        L += ["### On the real corpus", "",
              f"FarmShare's bulk pilot pages ({b['pages']:,} random corpus pages; the model's kind label is Qwen3.6 "
              "27B's own, and a failure is a reply that ran to the token cap). There is no truth here, so this says "
              "how the two labels relate and where failures fall, not which label is right.", "",
              "| Vision's kind | pages | " + " | ".join(f"model said {k}" for k in labels) + " | failed | failure rate |",
              "|---|---:|" + "---:|" * len(labels) + "---:|---:|"]
        for k, r in b["by_kind"].items():
            L.append(f"| {k} | {r['pages']:,} | " + " | ".join(f"{r['labels'][x]:,}" for x in labels)
                     + f" | {r['failed']} | {100 * r['failed'] / r['pages']:.1f}% |")
        mh_ = sum(r["labels"].get("handwritten", 0) for r in b["by_kind"].values())
        both = b["by_kind"].get("handwriting", {}).get("labels", {}).get("handwritten", 0)
        vh = b["by_kind"].get("handwriting", {}).get("pages", 0)
        L += ["", f"Vision calls {vh:,} pages handwriting and the model says handwritten on {mh_:,}; they agree on "
              f"{both:,}. {b['photo_signal']:,} of the {b['pages']:,} pages read as photographs by their light and "
              "colour (a handwritten or newspaper page is counted under its own kind above). Failures are too few "
              "(one page in about 150) to say whether any kind fails more often. Vision's pass took about 30 minutes "
              "for the 2,000 pages and the panel's 99 together, five processes at once on the 18 GB M3 Pro."
              + (f" {b['unread']:,} pages Vision could not read are left out." if b["unread"] else ""), ""]
    return L


def report(d):
    """difficulty.md: the analysis as a readable report. Every figure comes from analyse()'s result."""
    R = d["routes"]
    L = ["# Page difficulty, failures and cascades (W41.bench-difficulty)", "",
         "Built by `ArchiveOCRBench/build.py` from `segbench-results/ocr-pages.csv` and `ocr-pages-agree.csv` "
         "(`scripts/segbench/ocr_pages_export.py` writes them from the panels' private caches); edit `difficulty.py`, "
         "not this file. No new calls were made: every figure is the panel's measured reading of its "
         f"{d['pages']} accuracy pages, by {d['routes_n']} routes.", "",
         "The owner's framing (2026-10-15): what matters most is that the text that comes back is accurate. A page "
         "that fails goes on to another model; it is not inaccurate text. So accuracy on answered pages and failures "
         "are ranked apart, with page difficulty in the picture so that a route that fails only hard pages is not "
         "flattered, and cascades are simulated to see whether cheap readers can take the easy pages.", "",
         "## 1. Two rankings: accuracy on the pages answered, and failures", "",
         "**NES at average difficulty** fits NES = route ability + page easiness to every answered reading, so a "
         "route that skipped hard pages is not credited for it: it is the route's expected NES on a page of average "
         f"difficulty. **Page mix** is how much easier than average the pages it answered were, in NES points (a "
         "positive figure is what answered-only accuracy flatters). The bench's strict NES, which scores a failure "
         f"0, is beside them. A poor reading is an answered page under {d['wrong_bar']:.0f} NES.", "",
         "| route | $ / 1,000 | answered | NES on answered | NES at average difficulty | page mix | poor readings | "
         "failed | failed pages that are hard | strict NES (bench) |",
         "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in R:
        L.append(f"| {r['name']} | {money(r['price'])} | {r['answered']} | {f2(r['answered_nes'])} | "
                 f"{f2(r['adjusted'])} | {f2(r['page_mix'], True)} | {r['wrong']} | {r['failed']} | "
                 f"{r['fail_hard'] if r['failed'] else '–'} | {f2(r['strict'])} |")
    flat = sorted(R, key=lambda r: -r["page_mix"])[:3]
    L += ["", f"Answered-only accuracy flatters most the routes that fail often: {', '.join(f'{r['name']} ({f2(r['page_mix'], True)}, {r['failed']} failed)' for r in flat)}. "
          "For the routes that answer everything the adjustment is a constant shift. Failures are a separate count; a "
          "cascade turns them into money, not into lost text (part 4).", "",
          "## 2. Page difficulty", "",
          "A page's difficulty is one minus the mean NES of the other routes' answered readings of it (leave one out: "
          "the route being judged never sets its own pages' difficulty). Thirds of the pages by that measure:", "",
          "| tier | mean NES of all routes | typewritten | printed | handwritten | mixed |", "|---|---:|---:|---:|---:|---:|"]
    dk = d["difficulty"]
    for t in TIERS:
        k = dk["tier_kinds"][t]
        L.append(f"| {t} | {f2(dk['tier_mean'][t])} | {k.get('typewritten', 0)} | {k.get('printed', 0)} | "
                 f"{k.get('handwritten', 0)} | {k.get('mixed', 0)} |")
    tk = dk["tier_kinds"]
    L += ["", f"Handwritten pages: {tk['easy'].get('handwritten', 0)} easy, {tk['middle'].get('handwritten', 0)} middle, "
          f"{tk['hard'].get('handwritten', 0)} hard; but {tk['hard'].get('typewritten', 0)} of the "
          f"{sum(tk['hard'].values())} hard pages are typewritten and {tk['hard'].get('printed', 0)} printed. "
          f"The ten hardest pages average {f2(mean(h['mean_nes'] for h in dk['hardest']))} NES across routes "
          f"({', '.join(h['kind'] for h in dk['hardest'])}). A page's difficulty and the number of routes that fail "
          f"it are only loosely related (correlation {dk['fail_corr']:.2f}): most failures are a call that errored, "
          "a reply that ran to the token limit or broke the reply format, or a refusal, not a reading that came out badly.", "",
          "### Accuracy on answered pages by difficulty and by kind", "",
          "Each route's own thirds, from its leave-one-out difficulty; failed pages in brackets.", "",
          "| route | easy | middle | hard | typewritten | printed | handwritten |", "|---|---:|---:|---:|---:|---:|---:|"]
    for r in R:
        cell = lambda v: f"{f2(v['answered_nes'])}" + (f" ({v['failed']})" if v["failed"] else "")
        L.append(f"| {r['name']} | " + " | ".join(cell(r["by_tier"][t]) for t in TIERS) + " | " +
                 " | ".join(cell(r["by_kind"][k]) for k in ("typewritten", "printed", "handwritten")) + " |")
    easy = sorted(R, key=lambda r: r["by_tier"]["easy"]["answered_nes"])
    hard = [r["by_tier"]["hard"]["answered_nes"] for r in R]
    L += ["", f"On its easy third every route but {easy[0]['name']} ({f2(easy[0]['by_tier']['easy']['answered_nes'])}) "
          f"reads {f2(easy[1]['by_tier']['easy']['answered_nes'])} or better; on the hard third the routes run from "
          f"{f2(min(hard))} to {f2(max(hard))}, which is where the ranking comes from.", "",
          "## 3. Do failures fall on hard pages?", "",
          "For each route that failed any page: where its failed pages sit in its own difficulty order (0 = the "
          "easiest page, 100 = the hardest; 50 is what failures at random would give) and how many are in the hard third.", "",
          "| route | failed | mean difficulty percentile | in the hard third | by kind |", "|---|---:|---:|---:|---|"]
    for r in sorted([r for r in R if r["failed"]], key=lambda r: -r["failed"]):
        L.append(f"| {r['name']} | {r['failed']} | {r['fail_pctile']} | {r['fail_hard']} | "
                 f"{', '.join(f'{k} {v}' for k, v in r['fail_kinds'].items())} |")
    fr = [r for r in R if r["failed"]]
    above = sum(r["fail_pctile"] > 50 for r in fr)
    easy_f = [r["name"] for r in fr if r["fail_pctile"] < 100 / 3]
    L += ["", f"Failures lean toward harder pages but are not confined to them: for {above} of the {len(fr)} routes "
          f"that failed, the failed pages sit above the median difficulty"
          + (f", while {' and '.join(easy_f)} failed only easier pages" if easy_f else "")
          + ". Most routes failed one to four pages, so these percentiles are anecdotes, not rates.", "",
          "## 4. Cascades", "",
          "Simulated from the measured readings: each page goes to the first stage, and on to the next when the "
          "trigger fires; the text kept is the last stage's. A cascade's cost is each stage's measured cost for the "
          "pages it read (a route's bench price shared out by its per-page cost, so escalated long pages cost what "
          "long pages cost), at standard prices. First stages and the second reader in a disagreement check are the "
          f"cheap routes ({money(CHEAP_PRICE)} per 1,000 pages or less, or free); later stages are any route a user "
          "of the app can run (FarmShare is left out). Triggers: the stage failed; it failed or labelled the page "
          "handwritten or mixed; it failed or its text and a second cheap reader's differ (NES between the two "
          f"under {', '.join(f'{t:.2f}' for t in THRESHOLDS)}). {d['cascades']['n']:,} candidates in all.", "",
          "The Mac routes are free in money but not in time: about 40 s a page on the 18 GB M3 Pro "
          "(`ocr-mac-local.md`), and a cascade with two Mac readers spends that twice.", "",
          "### The best candidate at each budget, and what choosing it from half the pages is worth", "",
          f"Choosing the best of thousands of candidates on {d['pages']} pages flatters the choice. So each family is "
          f"also chosen {SPLITS} times on a random half of the pages and scored on the other half: the last column "
          "is what that way of choosing delivers on pages it did not see.", "",
          "| budget, $ / 1,000 | family | best on all pages | NES | $ | escalated | chosen on half → other half |",
          "|---:|---|---|---:|---:|---:|---:|"]
    for b in d["cascades"]["budgets"]:
        for fam, v in b["families"].items():
            x = v["best"]
            L.append(f"| {b['budget']} | {FAMILY[fam]} | {x['label']} | {f2(x['nes'])} | {money(x['usd'])} | "
                     f"{x['escalated'] if fam != 'single' else '–'} | {f2(v['split_in'])} → {f2(v['split_out'])} |")
    out = {b["budget"]: {f: v["split_out"] for f, v in b["families"].items()} for b in d["cascades"]["budgets"]}
    paid = [b for b in out if 0 < b <= 5]
    gain = [out[b]["fail"] - out[b]["single"] for b in out if b <= 5]
    L += ["", "What holds up on pages the choice did not see:", "",
          f"- **Escalating on failure is the robust gain.** At every budget up to $5 per 1,000 pages, a cascade that "
          f"sends failures on, chosen on half the pages, beat one route chosen the same way by {min(gain):.1f} to "
          f"{max(gain):.1f} NES points on the other half. Much of that is simply the failed pages coming back: a "
          "failure scores 0, and a cascade turns it into a second reading.",
          "- **The disagreement check** finds answered-but-wrong pages (part 5) and tops most budgets on all pages, "
          "but it is the most flattered family. On unseen pages it is "
          + ", ".join(f"{out[b]['disagree'] - out[b]['fail']:+.2f} at ${b}" for b in paid)
          + " against escalation on failure alone.",
          "- **A hard-kind label** (the reader's own handwritten or mixed label) is "
          + ", ".join(f"{out[b]['fail+kind'] - out[b]['fail']:+.2f} at ${b}" for b in paid)
          + " against failure alone on unseen pages: no reliable gain. The labels are weak (part 5).",
          f"- **At the top, one strong reader still wins**: at $25 the single-route choice gives "
          f"{f2(out[25]['single'])} on unseen pages, the best cascade family {f2(max(v for f, v in out[25].items() if f != 'single'))}.", "",
          "### The frontier on all pages", "",
          "| cascade | NES | $ / 1,000 | escalated | failed |", "|---|---:|---:|---:|---:|"]
    for x in d["cascades"]["frontier"]:
        L.append(f"| {x['label']} | {f2(x['nes'])} | {money(x['usd'])} | {x['escalated']} | {x['failed']} |")
    L += ["", "## 5. What flags an answered page that is wrong", "",
          "A cascade sees a failure; it does not see a poor reading. For each cheap first reader, how well its "
          f"signals pick out its answered pages under {d['wrong_bar']:.0f} NES: AUC (0.5 is chance, 1 is perfect) "
          "and how many of the poor readings fall in the fifth of its pages the signal ranks most suspect. "
          "**Length** compares its word count with Apple Vision's on the same page (free, on the device). "
          "**Disagreement** is one minus the NES between its text and a second cheap reader's; the partner shown is "
          "the best of the cheap readers, itself chosen on these pages. **Kind** is its own label, and **Vision** "
          "is whether Vision OCR's page sorter calls the page handwriting (part 6), the same for every reader. No route reports "
          "a confidence: the panel's prompt asks for none and the APIs used return no token probabilities, so that "
          "signal was not available.", "",
          "| reader | answered | poor readings | kind label: AUC, caught | Vision: handwriting: AUC, caught | "
          "length: AUC, caught | disagreement: partner, AUC, caught |",
          "|---|---:|---:|---|---|---|---|"]
    for f in d["flags"]:
        s = f["signals"]
        kind_ = s.get("said handwritten or mixed")
        length = s.get("length against Apple Vision's")
        vis = s.get("Vision: handwriting")
        dis = next(((k, v) for k, v in s.items() if k.startswith("disagrees")), None)
        L.append(f"| {f['name']} | {f['answered']} | {f['wrong']} | "
                 + (f"{kind_['auc']:.2f}, {kind_['caught_at_20']}" if kind_ else "–") + " | "
                 + (f"{vis['auc']:.2f}, {vis['caught_at_20']}" if vis else "–") + " | "
                 + (f"{length['auc']:.2f}, {length['caught_at_20']}" if length else "–") + " | "
                 + (f"{dis[0].removeprefix('disagrees with ')}, {dis[1]['auc']:.2f}, {dis[1]['caught_at_20']}" if dis else "–") + " |")
    rng_ = lambda key: [v["auc"] for f in d["flags"] for k, v in f["signals"].items() if k.startswith(key)]
    dis_, len_, kind_ = rng_("disagrees"), rng_("length"), rng_("said")
    L += ["", f"Disagreement between two cheap readers is the strong signal (AUC {min(dis_):.2f} to {max(dis_):.2f}), "
          f"and length against Apple Vision's reading is a free second ({min(len_):.2f} to {max(len_):.2f}). The "
          f"model's own kind label is weak ({min(kind_):.2f} to {max(kind_):.2f}): the models often label a page "
          "differently from the truth (the panel's `kind_correct`), and poor readings are spread over printed and "
          "typewritten pages as well as handwritten ones.", ""]
    if d["bulk"]:
        bt = d["bulk_total"]
        L += ["## Failures on the real corpus", "",
              f"FarmShare's bulk pilot (Qwen3.6 27B, {bt['pages']:,} random corpus pages, no truth): {bt['failed']} "
              f"failed ({', '.join(f'{v} {k}' for k, v in d['bulk_failures'].items())}). By the kind the model gave "
              "the page:", "",
              "| kind (model's label) | pages | failed | failure rate |", "|---|---:|---:|---:|"]
        for k, v in d["bulk"].items():
            L.append(f"| {k} | {v['pages']:,} | {v['failed']} | {100 * v['failed'] / v['pages']:.1f}% |")
        worst = max(v["failed"] / v["pages"] for v in d["bulk"].values())
        L += ["", f"No kind fails more than {100 * worst:.1f}% of its pages, so on the real corpus escalation on failure "
              f"is cheap: the dearer route would see about one page in {round(bt['pages'] / bt['failed'])}.", ""]
    L += vision_report(d)
    L += ["## A proposed routing rule (a proposal, filed as W41.app-ocr-cascade; not built)", "",
          "1. Read every page with a cheap reader first.",
          "2. Send a failed page to a stronger route. This is the measured, robust gain (part 4), and on the real "
          "corpus it costs little because few pages fail.",
          "3. Optionally, read the page with a second cheap reader (or compare the word count with Apple Vision's, "
          "which is free) and send pages where they disagree to the stronger route. It catches most poor readings, "
          "at the second reader's cost plus the pages escalated; on these pages its gain over step 2 alone was not "
          "consistent (part 4), so it wants a larger test before it is the default.",
          "4. Where accuracy matters more than price, one strong reader alone is still the best single choice.", "",
          VISION_RULE.get(vision_verdict(d), ""), "",
          "## Limits", "",
          f"{d['pages']} pages from one corpus; truth drafted by Claude Opus 5.5 and Gemini 3.8 Flash before it was "
          "adjudicated, so it may lean toward those families. Difficulty is measured by the same routes that are "
          "ranked, with the judged route left out. Most routes failed a handful of pages or none, so failure rates "
          "and where failures fall are anecdotes. The cascade frontier is chosen on the same pages it is scored on; "
          "the split-half column is the honest figure. Prices are standard, not batch.", ""]
    return "\n".join(L)
