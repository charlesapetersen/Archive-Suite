"""W46.seg-common-support: rescore app comparisons from cached predictions at their frozen levels.

Run under heavy-run.py with the lab Python. No model, fit, upload, key or paid call.
Base options first, then g1 offsets, then the g2 offsets; existing generators render the results.
Historical conditional uppers survive explicitly in each figure's exactness object.
"""
from collections import Counter
import datetime as dt
import json

import data
import rescore

TAG = "W46.seg-common-support"


def conditional_figures(f):
    """Recover the old estimand even after an interrupted or already completed rescore."""
    out = {k: v for k, v in f.items() if k != "exactness"}
    if x := f.get("exactness"):
        out["pages_exact_no_review"] = x["no_review"]["conditional_upper"] if x["no_review"] else None
        out["pages_exact_after_review"] = x["after_review"]["conditional_upper"]
    return out


def score_rows(boxes, voters, level, rule):
    import ensemble as E
    import options as O
    with O.rule(rule):
        rows = [E.evaluate(boxes[n], voters, level) | {"name": n} for n in data.TEST]
    return {"test": O.figures(E.pooled(rows)), "test_by_box": {r["name"]: O.figures(r) for r in rows}}


def main():
    rescore.no_network()
    import ensemble as E
    import options as O
    import method_openrouter as R
    import seg_magazine_rule_app as G2
    import seg_text_tier_app as T
    import seg_boxes_score as B
    import seg_g2_offsets as GO
    opts = json.loads(O.OUT_JSON.read_text())
    record_path = B.RESULTS / "seg-common-support.json"
    previous = json.loads(record_path.read_text()) if record_path.exists() else None
    before = ({k: r["before_conditional_upper"] for k, r in previous["moves"].items()} if previous else
              {a["id"]: conditional_figures(a["figures"]["test"]) for a in opts["approaches"]})
    standard = {n: E.Box(data.load(n, with_exif=False), "CGO") for n in data.TEST}
    _, other = R.five_box([f"X:{R.GLM_KEY}", f"X:{R.LOCAL_SEG_KEY}"])
    g2 = {n: G2.g2_box(n) for n in data.TEST}
    failed = Counter()
    text = {n: T.box(n, failed) for n in data.TEST}
    sets = {"claude": (standard, ("C",)), "openai": (standard, ("O",)),
            "mix": (standard, tuple(O.frozen_openai()["approaches"]["mix"]["voters"])),
            "glm": (other, (f"X:{R.GLM_KEY}",)), "local": (other, (f"X:{R.LOCAL_SEG_KEY}",)),
            "gemini": (g2, ("G",)), "gemini-text": (text, ("G",))}
    for a in opts["approaches"]:
        if a["id"] == "manual":
            # Every gap still needs judgement, including the unknown ones; no model prediction exists.
            manual = {n: E.Box(data.load(n, with_exif=False), "") for n in data.TEST}
            scored = O.manual_figures(manual)
        else:
            boxes, voters = sets[a["id"]]
            scored = score_rows(boxes, voters, a["level"], a["rule"])
        a["figures"].update(scored)
        if a["id"] == "gemini":
            old = a["replaces"]
            g1 = score_rows(standard, ("G",), old["level"], old["rule"])
            old.update(g1)
    supports = {a["figures"]["test"]["exactness"]["resolved_doc_pages"] for a in opts["approaches"]}
    if len(supports) != 1:
        raise RuntimeError(f"route support differs: {supports}")
    opts["common_support"] = {"item": TAG, "date": dt.date.today().isoformat(),
                              "rule": "Rank only documents touching no unknown gap; costs count all pages. "
                                      "Full-document bounds keep each route's conditional upper separately; "
                                      "after checking assumes perfect correction on known gaps only."}
    O.OUT_JSON.write_text(json.dumps(opts, indent=1) + "\n")
    # g1 offset source has to precede g2: both spreads use the same fixed support.
    path = B.RESULTS / "seg-boxes-score.json"
    boxes_out = json.loads(path.read_text())
    boxes_out["offsets"] = B.offsets(B.judges()["gemini"])
    boxes_out["note"] = B.reading(boxes_out)  # the reading quotes the offset range
    path.write_text(json.dumps(boxes_out, indent=1) + "\n")
    (B.RESULTS / "seg-boxes-score.md").write_text(B.render(boxes_out))
    GO.cmd_score(None)
    opts = json.loads(O.OUT_JSON.read_text())
    by_id = {a["id"]: a for a in opts["approaches"]}
    # Refresh generator-owned detail at the existing levels; no development or test level is refitted.
    path = B.RESULTS / "seg-magazine-rule-app.json"
    out = json.loads(path.read_text())
    gem = by_id["gemini"]
    out["test"] = {k: gem["figures"][k] for k in ("test", "test_by_box")}
    out["test_at_g1_level"] = score_rows(g2, ("G",), out["level_g1_3_8"], "min")["test"]
    out["g1_3_8"]["test"] = gem["replaces"]["test"]
    path.write_text(json.dumps(out, indent=1) + "\n")
    path.with_suffix(".md").write_text(G2.render(out))
    path = B.RESULTS / "seg-text-tier-app.json"
    out = json.loads(path.read_text())
    out["test"] = {k: by_id["gemini-text"]["figures"][k] for k in ("test", "test_by_box")}
    out["test_at_image_level"] = score_rows(text, ("G",), out["image_level"], "min")["test"]
    out["image"]["test"] = gem["figures"]["test"]
    path.write_text(json.dumps(out, indent=1) + "\n")
    path.with_suffix(".md").write_text(T.render(out))
    import seg_text_tier_test as TT
    TT.cmd_score(None)  # Includes its paired bootstrap, now restricted to the same resolved documents.
    owner = json.loads(rescore.OWNER_JSON.read_text())
    extra = rescore.pooled_rows(owner["boxes"], list(data.TEST))
    extra = {k: extra[k] for k in ("window-or-fs-seg-2b", "window-or-fs-seg-4b", "window-or-fs-qwen3.5-27b")}
    moves = {a["id"]: {"before_conditional_upper": before[a["id"]], "now": a["figures"]["test"]}
             for a in opts["approaches"]}
    result = {"tag": TAG, "support": sorted(supports), "moves": moves, "extra_routes": extra,
              "frozen_levels": {a["id"]: a.get("level") for a in opts["approaches"]}}
    record_path.write_text(json.dumps(result, indent=1) + "\n")
    render_result(result, opts)
    print("Common document pages:", sorted(supports))
    for a in opts["approaches"]:
        f = a["figures"]["test"]
        print(a["id"], f["pages_exact_no_review"], f["pages_exact_after_review"], f["flagged_per_100_pages"])


def render_result(result, opts):
    import ensemble as E
    import options as O
    import seg_boxes_score as B
    before = {k: r["before_conditional_upper"] for k, r in result["moves"].items()}
    extra = result["extra_routes"]
    record_path = B.RESULTS / "seg-common-support.json"
    lines = ["# Segmentation on common truth support — W46.seg-common-support", "",
             "Offline rescore of cached answers; $0, no model or upload, every rule/level kept frozen. "
             "The two unknown RG165 gaps remove five of 330 document pages: every route ranks on the same 325. "
             "Checking costs still cover all 363 photographed pages and all 315 document gaps.", "",
             "| route | old conditional upper (not ranking) | common support, no checking | ideal checking | checks/100 photographed pages |",
             "|---|---:|---:|---:|---:|"]
    for a in opts["approaches"]:
        f, old = a["figures"]["test"], before[a["id"]]
        pct = lambda x: "—" if x is None else E.pct(x)
        lines.append(f"| {a['label']} | {pct(old['pages_exact_no_review'])} | {pct(f['pages_exact_no_review'])} | "
                     f"{E.pct(f['pages_exact_after_review'])} | {f['flagged_per_100_pages']:.1f} |")
    lines += O.support_note({a["label"]: a["figures"]["test"] for a in opts["approaches"]})
    lines += ["## Other cluster routes, from cached additive counts", "",
              "These no-checking figures use the same 325 document pages. Other segment metrics in their old "
              "reports remain conditional diagnostics, with no fixed-truth ranking claim.", "",
              "| route | common support | all-document lower | conditional upper |", "|---|---:|---:|---:|"]
    for k, m in extra.items():
        lines.append(f"| {k} | {E.pct(m['pages_in_exact_doc_resolved'])} | {E.pct(m['pages_in_exact_doc_low'])} | "
                     f"{E.pct(m['pages_in_exact_doc'])} |")
    spread = json.loads((B.RESULTS / "seg-g2-offsets.json").read_text())["spread_points"]
    lines += ["", "## Offset floors and picks", "",
              f"On this same support g1 spans {spread['g1']:.3f} points (rounded 2.5, previously 2.4), g2 "
              f"{spread['g2']:.3f} (rounded 5.2). The owner's per-pair construction is unchanged: twice the larger "
              "own range, borrowing g1 only when absent. Thus unmeasured pairs use 5.0 points, g2 pairs 10.4. "
              "The numerical borrowing change follows the common denominator; it is not a new tie policy. "
              "Documented profiles keep their picks. Two move on one 16-page gap: text alone has 285 of 325 exact, "
              "GLM-5.3 Flash and the cluster 4B 269 each, 4.9 points against the 5.0 floor (on 330 pages, 4.85 against "
              "4.8). A Gemini plus OpenRouter key now picks GLM-5.3 Flash, a cluster plus a Gemini key the cluster 4B; "
              "the cheaper route wins the tie. The gap is exactly twice g1's 8-page spread, so the move follows the "
              "denominator and rounding, not a measured change (13-profile-tests.md; SettingsSolverTestDriver).", ""]
    import seg_card
    lines += seg_card.card(truth="Owner-ruled Stanton and RG165, including the eight corrections and two unknowns "
                          "recorded by W46.seg-truth-owner-fixes; truth photo labels.",
                          selection="The same frozen whole test boxes, not selected by these answers.",
                          comparison="One fixed common document support for every route and every offset; own "
                          "frozen review rules/levels, original prompts/models retained and disclosed in options.md.",
                          noise="Truth ambiguity bounds are distinct from offset placement ranges; neither measures "
                          "fresh material or human correction accuracy. No level refitted here.",
                          scope="Repairs the ranked estimand, not truth, predictions or trained models. Gemini 3.8 "
                          "still borrows Gemini 3.7 evidence; Claude w1 has a different magazine rule.")
    record_path.with_suffix(".md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["render"]:
        import options as O
        render_result(json.loads((O.RESULTS / "seg-common-support.json").read_text()), json.loads(O.OUT_JSON.read_text()))
    else:
        main()
