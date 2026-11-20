"""W47.wh-kinds-floor: the page-kind classifier's 0.8 routing floor measured, with a document prior.

    heavy-run.py run -- <torch-env python> kind_floor.py           # -> segbench-results/kind-floor.md + .json
    <torch-env python> kind_floor.py --render                       # the .md again from the committed .json

The app routes a page to the model guide's pick for its kind when the classifier's top class is at least 0.8 and keeps
the run's model otherwise (PageKindRouting.choose; a form call, form probability over 0.5, counts with that probability,
PageKind.decide). This scores that rule at other cuts, and with a prior that gives an unsure page the kind of the sure
pages beside it, against keeping the run's model for every page. Three parts:

1. The 144 labelled owner pages (kind_classifier's labels, at their own resolution): each page's probabilities from a
   model of the shipped form (Vision signals + feature print, the hand and the form regressions, lam 0.05) fitted
   without any page of its folder, so a page's confidence is not flattered by its own label. How often the top class
   is right above and below each cut.
2. The 96 OCR truth pages among them (ocr-pages.csv NES per route): mean NES when a sure page goes to the guide's first
   pick for its kind (every pick taken as runnable, as in kind-classifier.md §4) and an unsure page to the run's model,
   for five run models. The truth pages are single pages, not documents, so the prior here is a folder prior: the
   majority kind of the sure calls on the other labelled pages of the same folder. Paired bootstrap intervals.
3. The 848 document pages of the five owner boxes (kind_churn's measurement): the document prior itself, the majority
   kind of the sure pages of the page's own document, on the pages under each cut. No kind or OCR truth exists there,
   so this counts what the prior would change, not whether the change is right.
No calls, no money.
"""
from __future__ import annotations

import csv
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np

import kind_classifier as kc

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / "segbench-results"
FLOOR = 0.8
CUTS = [0.0, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95]
RUN_MODELS = ["apple-vision", "gemini3.1-flash-lite", "qwen3.6-27b", "gemini3.8-flash", "claude-sonnet5.5"]
SEED = 20261119
BOOT = 4000


def probs_loo(X, y, k, groups, lam=0.05):
    out = np.zeros((len(y), k))
    groups = np.array(groups)
    for g in set(groups):
        m = groups != g
        mu, sd = X[m].mean(0), X[m].std(0) + 1e-6
        W, b = kc.lr_fit((X[m] - mu) / sd, y[m], k, lam)
        z = ((X[~m] - mu) / sd) @ W + b
        z -= z.max(1, keepdims=True)
        e = np.exp(z)
        out[~m] = e / e.sum(1, keepdims=True)
    return out


def decide(ph, pf):
    """PageKind.decide: a form when its probability passes 0.5, else the top hand, each with its probability."""
    if pf[1] > pf[0]:
        return "forms", float(pf[1])
    k = int(ph.argmax())
    return kc.KINDS3[k], float(ph[k])


def labelled_pages():
    lab = [r for r in kc.read_tsv(kc.CACHE / "labels.tsv") if not r["set"].startswith("ladder")]
    sig = {r["id"]: r for r in kc.read_tsv(kc.CACHE / "signals.tsv")}
    fp = {}
    for line in open(kc.CACHE / "featureprints.tsv"):
        pid, _, v = line.rstrip("\n").partition("\t")
        fp[pid] = np.array([float(x) for x in v.split(",")])
    num = lambda x: 0.0 if kc.num(x) != kc.num(x) else kc.num(x)
    scal = ["harmonic", "periodic", "conf", "text_px", "lines"]
    Xh = np.array([np.concatenate([[num(sig[r["id"]][c]) for c in scal], fp[r["id"]]]) for r in lab])
    Xf = np.array([np.concatenate([[num(sig[r["id"]]["table_share"]), num(sig[r["id"]]["table_cells"])], x])
                   for r, x in zip(lab, Xh)])
    y3 = np.array([kc.KINDS3.index(r["hand"]) if r["hand"] in kc.KINDS3 else 0 for r in lab])  # mixed -> handwritten
    yf = np.array([int(r["form"] == "yes") for r in lab])
    folders = [r["group"] for r in lab]
    ph, pf = probs_loo(Xh, y3, 3, folders), probs_loo(Xf, yf, 2, folders)
    pages = []
    for i, r in enumerate(lab):
        kind, conf = decide(ph[i], pf[i])
        truth = "forms" if r["form"] == "yes" else (r["hand"] if r["hand"] in kc.KINDS3 else "handwritten")
        pages.append({"id": r["id"], "set": r["set"], "folder": r["group"], "kind": kind, "conf": conf, "truth": truth})
    return pages


def prior(kinds_confs, j, cut):
    """The majority kind of the other sure calls in the group, or None (ties: the first such call's kind)."""
    sure = [k for i, (k, c) in enumerate(kinds_confs) if i != j and c >= cut]
    if not sure:
        return None
    cnt = Counter(sure)
    top = max(cnt.values())
    return next(k for k in sure if cnt[k] == top)


def boot(diffs, rng):
    d = np.array(diffs)
    idx = rng.integers(0, len(d), (BOOT, len(d)))
    m = d[idx].mean(1)
    return [round(float(np.percentile(m, 2.5)) * 100, 2), round(float(np.percentile(m, 97.5)) * 100, 2)]


def analyse() -> dict:
    out: dict = {"floor": FLOOR, "cuts": CUTS, "run_models": RUN_MODELS}
    pages = labelled_pages()
    out["labelled"] = len(pages)
    out["labelled_right"] = sum(p["kind"] == p["truth"] for p in pages)
    by_folder: dict[str, list[int]] = {}
    for i, p in enumerate(pages):
        by_folder.setdefault(p["folder"], []).append(i)

    # 1. the top class above and below each cut
    cal = []
    for c in CUTS[1:]:
        sure = [p for p in pages if p["conf"] >= c]
        uns = [p for p in pages if p["conf"] < c]
        cal.append({"cut": c, "sure": len(sure), "sure_right": sum(p["kind"] == p["truth"] for p in sure),
                    "unsure": len(uns), "unsure_right": sum(p["kind"] == p["truth"] for p in uns)})
    out["calibration"] = cal
    # the folder prior on the labelled pages under each cut
    fpr = []
    for c in CUTS[1:]:
        uns = [i for i, p in enumerate(pages) if p["conf"] < c]
        got = right_prior = right_top = 0
        for i in uns:
            grp = by_folder[pages[i]["folder"]]
            k = prior([(pages[g]["kind"], pages[g]["conf"]) for g in grp], grp.index(i), c)
            if k is None:
                continue
            got += 1
            right_prior += k == pages[i]["truth"]
            right_top += pages[i]["kind"] == pages[i]["truth"]
        fpr.append({"cut": c, "unsure": len(uns), "with_prior": got, "prior_right": right_prior, "top_right": right_top})
    out["folder_prior"] = fpr

    # 2. routing on the 96 OCR truth pages
    guide = {k["id"]: k["picks"][0]["source"]["route"] for k in json.load(open(kc.GUIDE))["kinds"]}
    nes = {}
    for r in csv.DictReader(open(kc.PAGES)):
        nes[(r["route"], r["page"])] = kc.num(r["nes"]) if r["ok"] == "True" else 0.0
    need = set(guide[k] for k in ("handwritten", "typewritten", "printed", "forms")) | set(RUN_MODELS)
    acc = [i for i, p in enumerate(pages) if p["set"] == "truth" and all((rt, p["id"]) in nes for rt in need)]
    out["routing_pages"] = len(acc)
    out["guide"] = {k: guide[k] for k in ("handwritten", "typewritten", "printed", "forms")}
    rng = np.random.default_rng(SEED)

    def read(i, kind, run):
        return nes[(guide[kind] if kind else run, pages[i]["id"])]

    def plan(i, c, with_prior):
        p = pages[i]
        if p["conf"] >= c:
            return p["kind"]
        if with_prior:
            grp = by_folder[p["folder"]]
            return prior([(pages[g]["kind"], pages[g]["conf"]) for g in grp], grp.index(i), c)
        return None

    routing = []
    for run in RUN_MODELS:
        keep = [nes[(run, pages[i]["id"])] for i in acc]
        oracle = [read(i, pages[i]["truth"], run) for i in acc]
        at_floor = [read(i, plan(i, FLOOR, False), run) for i in acc]
        row = {"run_model": run, "keep": round(float(np.mean(keep)) * 100, 2),
               "true_kinds": round(float(np.mean(oracle)) * 100, 2), "cuts": []}
        for c in CUTS:
            for wp in (False, True):
                if c == 0.0 and wp:
                    continue
                got = [read(i, plan(i, c, wp), run) for i in acc]
                routed = sum(plan(i, c, wp) is not None for i in acc)
                row["cuts"].append({
                    "cut": c, "prior": wp, "routed": routed, "mean": round(float(np.mean(got)) * 100, 2),
                    "vs_keep": round(float(np.mean(got) - np.mean(keep)) * 100, 2),
                    "vs_keep_ci": boot([a - b for a, b in zip(got, keep)], rng),
                    "vs_floor": round(float(np.mean(got) - np.mean(at_floor)) * 100, 2),
                    "vs_floor_ci": boot([a - b for a, b in zip(got, at_floor)], rng)})
        routing.append(row)
    out["routing"] = routing
    under = [i for i in acc if pages[i]["conf"] < FLOOR]
    out["routing_under_floor"] = {"pages": len(under), "right": sum(pages[i]["kind"] == pages[i]["truth"] for i in under),
                                  "with_folder_prior": sum(plan(i, FLOOR, True) is not None for i in under)}
    # The pages whose reader a move of the cut changes (under 0.9), with what each reader scored on them.
    fails = {(r["route"], r["page"]): r["failure"] for r in csv.DictReader(open(kc.PAGES)) if r["ok"] != "True"}
    out["near_floor_pages"] = [
        {"id": pages[i]["id"], "kind": pages[i]["kind"], "truth": pages[i]["truth"], "conf": round(pages[i]["conf"], 3),
         "pick": guide[pages[i]["kind"]], "pick_nes": round(nes[(guide[pages[i]["kind"]], pages[i]["id"])] * 100, 1),
         "pick_failure": fails.get((guide[pages[i]["kind"]], pages[i]["id"])),
         "run_nes": {run: round(nes[(run, pages[i]["id"])] * 100, 1) for run in RUN_MODELS}}
        for i in sorted(acc, key=lambda i: pages[i]["conf"]) if pages[i]["conf"] < 0.9]

    # 3. the document prior on the five owner boxes
    import data
    import kind_churn
    from score import PHOTO, segment_ids
    cols = [data.load(n, with_exif=False) for n in data.COLLECTIONS]
    sig, fp = kind_churn.measure(cols)

    def call(key):
        s = sig[key]
        base = np.array([kind_churn.num(s[c]) for c in kind_churn.SCAL])
        def soft(m, x):
            z = (x - np.array(m["mean"])) / np.array(m["sd"])
            sc = z @ np.array(m["W"]) + np.array(m["b"])
            e = np.exp(sc - sc.max())
            return e / e.sum()
        ph = soft(kind_churn.MODEL["hand"], np.concatenate([base, fp[key]]))
        pf = soft(kind_churn.MODEL["form"], np.concatenate([[kind_churn.num(s["table_share"]),
                                                              kind_churn.num(s["table_cells"])], base, fp[key]]))
        return decide(ph, pf)

    docs = []
    for c in cols:
        groups: dict[int, list[int]] = {}
        for i, s in enumerate(segment_ids(c.labels)):
            if c.labels[i] not in PHOTO:
                groups.setdefault(s, []).append(i)
        for idx in groups.values():
            docs.append([call(f"{c.name}:{c.pages[i].n}") for i in idx])
    box = []
    for cut in CUTS[1:]:
        n = uns = single = no_sure = agree = differ = 0
        changes = Counter()
        for d in docs:
            for j, (k, cf) in enumerate(d):
                n += 1
                if cf >= cut:
                    continue
                uns += 1
                if len(d) == 1:
                    single += 1
                    continue
                pk = prior(d, j, cut)
                if pk is None:
                    no_sure += 1
                elif pk == k:
                    agree += 1
                else:
                    differ += 1
                    changes[f"{k} → {pk}"] += 1
        box.append({"cut": cut, "pages": n, "unsure": uns, "single_page_doc": single, "no_sure_neighbour": no_sure,
                    "prior_agrees": agree, "prior_differs": differ, "changes": dict(changes)})
    out["box_prior"] = box
    out["box_docs"] = len(docs)
    return out


def render(r: dict) -> str:
    fl = r["floor"]
    cal = {c["cut"]: c for c in r["calibration"]}
    fpr = {c["cut"]: c for c in r["folder_prior"]}
    box = {c["cut"]: c for c in r["box_prior"]}
    pct = lambda a, b: f"{100 * a / b:.0f}%" if b else "—"
    g = r["guide"]
    L = ["# The kind classifier's 0.8 floor, measured, with the document prior — W47.wh-kinds-floor", "",
         "Made by `scripts/segbench/kind_floor.py` (method in its docstring). The app sends a page whose top class is at "
         f"least {fl} to the model guide's pick for its kind and keeps the run's model for the rest "
         "(`PageKindRouting.choose`). Asked by the owner on 2026-11-19 (call 15): measure the floor before routing under it "
         "is released or kept withheld.", ""]
    c8, f8, b8 = cal[fl], fpr[fl], box[fl]
    at = lambda row, c, wp: next(x for x in row["cuts"] if x["cut"] == c and x["prior"] == wp)
    ci = lambda x, k: f"{x[k]:+.2f} [{x[k + '_ci'][0]:+.2f}, {x[k + '_ci'][1]:+.2f}]"
    failed = [p for p in r["near_floor_pages"] if p["pick_failure"] and p["conf"] >= fl]
    L += ["## What it shows", "",
          f"- **The floor separates right calls from wrong ones.** At or over {fl} the top class is right on "
          f"{c8['sure_right']} of {c8['sure']} labelled pages ({pct(c8['sure_right'], c8['sure'])}); under it on "
          f"{c8['unsure_right']} of {c8['unsure']} ({pct(c8['unsure_right'], c8['unsure'])}).",
          "- **Routing the unsure pages by their top class anyway (cut 0) against the 0.8 floor**, on the 96: " +
          "; ".join(f"{row['run_model']} {ci(at(row, 0.0, False), 'vs_floor')}" for row in r["routing"]) + "." +
          (" Every interval reaches zero: a tie for each run model, leaning to routing where the run model is weak."
           if all(at(row, 0.0, False)["vs_floor_ci"][0] <= 0 for row in r["routing"]) else "") +
          (" No run model's mean falls by it." if all(at(row, 0.0, False)["vs_floor"] >= 0 for row in r["routing"]) else ""),
          f"- **The folder prior adds nothing measurable.** On the labelled pages under {fl} that have a sure "
          f"neighbour it is right on {f8['prior_right']} of {f8['with_prior']}, the top class on {f8['top_right']}; in "
          "reading, the prior at 0.8 against the floor alone: " +
          "; ".join(f"{row['run_model']} {ci(at(row, fl, True), 'vs_floor')}" for row in r["routing"]) + "."]
    if failed:
        p = failed[0]
        L.append(f"- **A higher cut's apparent gain is one page.** {p['id']}, {p['truth']} but called {p['kind']} at "
                 f"{p['conf']:.3f}, goes to {p['pick']}, whose stored reading is a {p['pick_failure']} failure scored "
                 "0; a cut of 0.9 sends it to the run model instead, which is nearly all of the 0.9 rows' gain over 0.8 "
                 "for the three run models that read it well.")
    L += [f"- **On the owner's boxes a document prior would change {b8['prior_differs']} of the {b8['unsure']} pages "
          f"under {fl}** ({', '.join(f'{k} {v}' for k, v in sorted(b8['changes'].items(), key=lambda kv: -kv[1]))}); "
          f"{b8['prior_agrees']} keep their top class, {b8['single_page_doc']} are single-page documents with no prior "
          f"and {b8['no_sure_neighbour']} have no sure page beside them. Whether those changes are right is not "
          "measured: the boxes have no kind truth.", "",
          "## 1. Is the top class right above and below the cut", "",
         f"The {r['labelled']} labelled owner pages, each scored by a classifier of the shipped form fitted without its "
         f"folder: the kind (form, else hand) is right on {r['labelled_right']} of {r['labelled']}.", "",
         "| cut | pages at or over | right | pages under | right |", "|---:|---:|---:|---:|---:|"]
    for c, x in cal.items():
        L.append(f"| {c} | {x['sure']} | {x['sure_right']} ({pct(x['sure_right'], x['sure'])}) | {x['unsure']} | "
                 f"{x['unsure_right']} ({pct(x['unsure_right'], x['unsure'])}) |")
    L += ["", "A folder prior on the same pages (the majority kind of the sure calls on the other labelled pages of the "
          "folder; most folders give one to three pages, so most unsure pages have no neighbour):", "",
          "| cut | pages under | with a neighbour | prior right | top class right on those |", "|---:|---:|---:|---:|---:|"]
    for c, x in fpr.items():
        L.append(f"| {c} | {x['unsure']} | {x['with_prior']} | {x['prior_right']} | {x['top_right']} |")
    u = r["routing_under_floor"]
    L += ["", "## 2. What the cut is worth in reading accuracy", "",
          f"The {r['routing_pages']} OCR truth pages with NES for every route used. A sure page goes to the guide's first "
          f"pick (handwritten and typewritten {g['handwritten']}, printed {g['printed']}, forms {g['forms']}), an unsure "
          "page to the run's model. Cut 0 routes every page by its top class; \"keep\" reads every page with the run's "
          f"model. Mean NES in points; differences with paired bootstrap 95% intervals. {u['pages']} of the "
          f"{r['routing_pages']} are under {fl} ({u['right']} of them with the right top class); {u['with_folder_prior']} "
          "of those have a folder neighbour.", ""]
    for row in r["routing"]:
        L += [f"**Run model {row['run_model']}**: keep {row['keep']:.2f}; routed by the true kinds {row['true_kinds']:.2f}.", "",
              "| cut | prior | pages routed | mean NES | against keep | against the 0.8 floor |", "|---:|:---:|---:|---:|---:|---:|"]
        for x in row["cuts"]:
            L.append(f"| {x['cut']} | {'folder' if x['prior'] else '—'} | {x['routed']} | {x['mean']:.2f} | "
                     f"{x['vs_keep']:+.2f} [{x['vs_keep_ci'][0]:+.2f}, {x['vs_keep_ci'][1]:+.2f}] | "
                     f"{x['vs_floor']:+.2f} [{x['vs_floor_ci'][0]:+.2f}, {x['vs_floor_ci'][1]:+.2f}] |")
        L.append("")
    L += ["The truth pages under 0.9, by confidence: the guide's pick for the called kind and what it read, against "
          "each run model's reading (NES).", "",
          "| page | called | truth | confidence | pick | pick NES | " + " | ".join(r["run_models"]) + " |",
          "|---|---|---|---:|---|---:|" + "---:|" * len(r["run_models"])]
    for p in r["near_floor_pages"]:
        f = f" ({p['pick_failure']} failure)" if p["pick_failure"] else ""
        L.append(f"| {p['id']} | {p['kind']} | {p['truth']} | {p['conf']:.3f} | {p['pick']} | {p['pick_nes']:.1f}{f} | " +
                 " | ".join(f"{p['run_nes'][m]:.1f}" for m in r["run_models"]) + " |")
    L.append("")
    L += ["## 3. The document prior on the five owner boxes", "",
          f"The {box[fl]['pages']} document pages in {r['box_docs']} documents (kind-churn.md), the shipped classifier as "
          "the app runs it. An unsure page takes the majority kind of the sure pages of its own document. No truth: this "
          "counts what the prior would change, not whether the change is right.", "",
          "| cut | pages under | single-page document | no sure page beside it | prior agrees with the top class | "
          "prior differs | the changes |", "|---:|---:|---:|---:|---:|---:|---|"]
    for c, x in box.items():
        ch = ", ".join(f"{k} {v}" for k, v in sorted(x["changes"].items(), key=lambda kv: -kv[1])) or "—"
        L.append(f"| {c} | {x['unsure']} | {x['single_page_doc']} | {x['no_sure_neighbour']} | {x['prior_agrees']} | "
                 f"{x['prior_differs']} | {ch} |")
    L += [""]
    from seg_card import card
    L += card(f"Kind: the {r['labelled']} labelled owner pages of `kind-classifier.md` (the truth set's kinds as the "
              "drafting models and the owner left them, the drawn pages labelled by a session looking; KND-1), mixed pages "
              "counted as handwriting as the app does. Reading: the 96 owner OCR truth pages' NES per route "
              "(`ocr-pages.csv`). The five boxes have no kind truth.",
              "Every labelled page and every truth page with all the routes; every document page of the five boxes. "
              "Nothing chosen by the classifier or a reader.",
              "Every arm reads the same pages with the same stored readings; only the rule choosing the reader changes. "
              "The guide's picks were chosen on these 96 pages, which flatters routing against keeping one model.",
              "Paired bootstrap over the pages (4,000 resamples, seed 20261119); the readings are one run per route, so "
              "no rerun floor is applied here and a difference whose interval crosses zero is a tie. The folder prior "
              "has few pages with a neighbour, so its rows are small.",
              "Whether the 0.8 cut and a prior change the reading on single owner pages, and how many box pages a "
              "document prior would change. It does not measure the document prior's accuracy (no kind truth on the "
              "boxes), routing when a pick is not runnable, or the cost of the picks.")
    return "\n".join(L)


def main() -> int:
    if sys.argv[1:] == ["--render"]:
        r = json.loads((RESULTS / "kind-floor.json").read_text())
    else:
        r = analyse()
        (RESULTS / "kind-floor.json").write_text(json.dumps(r, indent=1, ensure_ascii=False) + "\n")
    (RESULTS / "kind-floor.md").write_text(render(r))
    print(render(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
