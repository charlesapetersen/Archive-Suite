"""W46.seg-lincoln-cloud: is the Lincoln drop the open models' or the material's? The plan-route windows answer.

    SEGBENCH_CACHE=ROOT/cache <lab venv>/bin/python seg_lincoln_cloud.py public ROOT   # -> seg-lincoln-cloud-public.json
    <lab venv>/bin/python seg_lincoln_cloud.py owner                                  # -> seg-lincoln-cloud-owner.json
    <lab venv>/bin/python seg_lincoln_cloud.py report                                 # -> seg-lincoln-cloud.md

NO CALLS. Every answer is read from its response cache; the windows are collected beforehand with
``method_window_cues.py collect-public ROUTE ROOT`` (Lincoln, CREST) and ``collect ROUTE BOX`` (owner boxes), on the
owner's Claude and ChatGPT plans: no money. A source with a hole in its cache is listed as not collected.

THE ROUTES. ``window-cues-claude`` is Claude Sonnet 5.5 through ``claude -p`` and ``window-cues-codex`` is gpt-6.1-sol
at reasoning low through ``codex exec``, both with prompt c1 (method_gemini's g1, the owner's cues, with only the
image-delivery and answer lines changed). The ``-cue`` routes add G-entities test 4's prompt arm (prompt c2): the
salutation and closing patterns of features_cues.py, run over the window's OCR text, stated per gap. The open
models (FarmShare's 27B teacher and the trained 2B and 4B) are their committed caches, unchanged.

THE SCORERS. The old (pages in an exactly right document, false splits and merges, boundaries found) and the new
(PQ, kappa, MNDD; rescore.py) on the same predictions, plus the finding-aid document-count prior (rescore.py's;
Lincoln's catalogue 72, CREST's 22 PDFs) for each source with per-gap confidences, and the review load: the
fewest least-confident gaps a reviewer must check (taking the truth's decision) for 98% of pages to sit in an
exact document, per 100 pages.

THE OWNER BOXES (the cue arm). c2 is scored against c1 on the same route, box by box, where both caches are
complete. Nothing is fitted or chosen on any box: the c2 wording was written once, before any c2 answer was read.
"""
from __future__ import annotations

import json
import sys
from dataclasses import asdict
from pathlib import Path

import data

RESULTS = data.HERE.parent.parent / "segbench-results"
PUBLIC_JSON = RESULTS / "seg-lincoln-cloud-public.json"
OWNER_JSON = RESULTS / "seg-lincoln-cloud-owner.json"
REPORT = RESULTS / "seg-lincoln-cloud.md"
ROUTES = ("claude", "claude-cue", "codex", "codex-cue")
OPEN = ("fs-qwen3.5-27b", "fs-seg-2b", "fs-seg-4b")
NAMES = {"rule-cues": "rule cues (fitted on owner dev boxes)", "fs-qwen3.5-27b": "Qwen3.5 27B teacher, FarmShare",
         "fs-seg-2b": "trained Qwen3.5 2B, FarmShare", "fs-seg-4b": "trained Qwen3.5 4B, FarmShare",
         "window-cues-claude": "Claude Sonnet 5.5, c1, plan",
         "window-cues-claude-cue": "Claude Sonnet 5.5, c2 (stated letter cues), plan + gateway holes",
         "gateway-gemini": "Gemini 3.7 Flash, g1 windows, gateway",
         "gateway-glm": "GLM 5.3 Flash, g1 windows, gateway",
         "gateway-gemini-whole": "Gemini 3.7 Flash, wh1 whole stream, gateway",
         "window-cues-codex": "ChatGPT gpt-6.1-sol low, c1, plan",
         "window-cues-codex-cue": "ChatGPT gpt-6.1-sol low, c2 (stated letter cues), plan"}
BAR = 0.98


def review_load(truth: list[str], pred) -> int | None:
    """Fewest least-confident free gaps checked (each set to the truth) for BAR of pages exact."""
    from score import derived, score_labels
    labels = list(pred.labels)
    free = [i for i, b in enumerate(pred.boundaries) if not b.get("fixed") and b.get("confidence") is not None]
    if not free:
        return None
    order = sorted(free, key=lambda i: pred.boundaries[i]["confidence"])
    for k in range(len(order) + 1):
        if derived(score_labels(truth, labels))["pages_in_exact_doc"] >= BAR:
            return k
        if k < len(order):
            i = order[k]
            if labels[i + 1] in ("New", "Cont"):
                labels[i + 1] = "New" if truth[i + 1] == "New" else "Cont"
    return None  # fixed/photo errors cannot be repaired by reviewing the free document gaps


def score_sources(col, srcs: dict, prior_count: int | None) -> dict:
    import rescore
    from score import check_prediction, derived, score_labels
    out = {"pages": len(col.pages), "documents": rescore.truth_docs(col.labels), "sources": {}, "missing": {}}
    for name, predict in srcs.items():
        try:
            pred = predict(col)
        except (RuntimeError, ValueError, KeyError, FileNotFoundError) as e:
            out["missing"][name] = str(e)[:160]
            continue
        check_prediction(pred)
        c = score_labels(col.labels, pred.labels, col.name)
        row = {"counts": asdict(c), "metrics": derived(c), "review_load": review_load(col.labels, pred)}
        if prior_count is not None:
            labels = rescore.count_prior(col.labels, pred, prior_count)
            if labels is not None:
                row["prior"] = {"count": prior_count,
                                "metrics": derived(score_labels(col.labels, labels, col.name))}
        out["sources"][name] = row
        m = row["metrics"]
        print(f"  {col.name:10} {name:28} exact {m['pages_in_exact_doc']:.3f}  FS {c.false_splits}  FM {c.false_merges}"
              f"  PQ {m['pq']:.3f}  review {row['review_load']}", flush=True)
    return out


def window_sources(names) -> dict:
    import method_window as W
    import method_window_cues as WC
    import method_openrouter as R
    srcs = {}
    for k in names:
        if k == "window-cues-claude-cue":
            from seg_lincoln_gateway import claude_cue
            judge = claude_cue  # plan first, separate gateway cache for the final 11 holes; never calls
        else:
            judge = WC.judge(k.removeprefix("window-cues-")) if k.startswith("window-cues-") else R.judge(k)
        srcs[k] = lambda col, j=judge: W.assemble(col, W.combine(col, j), col.name not in ("Lincoln", "CREST"))
    return srcs


def public(root: Path) -> None:
    if data.CACHE_DIR.resolve() != root.resolve() / "cache":
        raise SystemExit(f"set SEGBENCH_CACHE={root / 'cache'}")
    import rescore
    import public_segmentation as P
    from methods import from_labels
    import method_openrouter as R
    import rules
    rescore.no_network()
    frozen = R.committed(P.MANIFESTS / "rule-cues-frozen.json")
    params = rules.Params(**{**frozen["params"], "rules": tuple(frozen["params"]["rules"])})

    def frozen_rule(col):
        # The public cache has only public OCR. Refitting here would train on empty owner
        # text and give spurious rule precisions. Use the already frozen owner-only fit.
        features = rules._features(col, params.top_lines, params.end_lines, params.blank_chars)
        labels, deciders = rules.predict_labels(features, params)
        pred = from_labels(labels)
        for b, rule in zip(pred.boundaries, deciders[1:]):
            b.update(cue=rule, confidence=rules.precision(frozen["stats"], rule))
        return pred

    srcs = {"rule-cues": frozen_rule,
            **window_sources(list(OPEN) + [f"window-cues-{r}" for r in ROUTES])}
    result = {"boxes": {}}
    for box in ("lincoln", "crest"):
        col, _ = P.load(box, root)
        result["boxes"][col.name] = score_sources(col, srcs, rescore.CATALOGUE_COUNT[col.name])
    PUBLIC_JSON.write_text(json.dumps(result, indent=1) + "\n")
    print(f"wrote {PUBLIC_JSON}")


def owner() -> None:
    import rescore
    rescore.no_network()
    srcs = window_sources([f"window-cues-{r}" for r in ROUTES])
    result = {"boxes": {}}
    for name in data.COLLECTIONS:
        col = data.load(name)
        result["boxes"][name] = score_sources(col, srcs, None)
        result["boxes"][name]["split"] = "test" if name in data.TEST else "dev"
    OWNER_JSON.write_text(json.dumps(result, indent=1) + "\n")
    print(f"wrote {OWNER_JSON}")


# --- the report -----------------------------------------------------------------------------------

def _pct(x):
    return "—" if x is None else f"{100 * x:.1f}%"


def _f(x, nd=3):
    return "—" if x is None else f"{x:.{nd}f}"


def public_table(box: str, b: dict) -> list[str]:
    L = [f"### {box}: {b['pages']} pages, {b['documents']} documents", "",
         "| source | pages exact | false splits | false merges | boundaries found | PQ | kappa | MNDD | "
         "pages exact, finding-aid count | checks per 100 pages to 98% |", "|---|---|---|---|---|---|---|---|---|---|"]
    for name, r in b["sources"].items():
        c, m = r["counts"], r["metrics"]
        prior = r.get("prior", {}).get("metrics", {}).get("pages_in_exact_doc")
        load = r["review_load"]
        L.append(f"| {NAMES.get(name, name)} | {_pct(m['pages_in_exact_doc'])} | {c['false_splits']} | "
                 f"{c['false_merges']} | {c['tp']}/{c['truth_bounds']} | {_f(m['pq'])} | {_f(m['kappa'])} | {m['mndd']} | "
                 f"{_pct(prior)} | {'—' if load is None else f'{100 * load / b['pages']:.1f}'} |")
    for name in b["missing"]:
        L.append(f"| {NAMES.get(name, name)} | not collected | | | | | | | | |")
    return L + [""]


def cue_table(owner: dict, pub: dict) -> list[str]:
    L = ["| box | route | c1 pages exact | c2 pages exact | c1 FS / FM | c2 FS / FM | c1 PQ | c2 PQ | "
         "c1 checks/100 p | c2 checks/100 p |", "|---|---|---|---|---|---|---|---|---|---|"]
    boxes = {**{k: v for k, v in owner["boxes"].items()}, **pub["boxes"]}
    for box, b in boxes.items():
        for route in ("claude", "codex"):
            a, c = b["sources"].get(f"window-cues-{route}"), b["sources"].get(f"window-cues-{route}-cue")
            if not (a and c):
                continue
            cell = lambda r: f"{r['counts']['false_splits']} / {r['counts']['false_merges']}"  # noqa: E731
            load = lambda r: "—" if r["review_load"] is None else f"{100 * r['review_load'] / b['pages']:.1f}"  # noqa: E731
            L.append(f"| {box} | {route} | {_pct(a['metrics']['pages_in_exact_doc'])} | "
                     f"{_pct(c['metrics']['pages_in_exact_doc'])} | {cell(a)} | {cell(c)} | {_f(a['metrics']['pq'])} | "
                     f"{_f(c['metrics']['pq'])} | {load(a)} | {load(c)} |")
    return L if len(L) > 2 else ["No box has both c1 and c2 on the same route yet."]


def render(pub: dict, owner: dict, notes: str) -> str:
    L = ["# Lincoln and CREST through the plan routes (W46.seg-lincoln-cloud)", "",
         "Generated by `scripts/segbench/seg_lincoln_cloud.py` from cached answers (no calls); the windows were "
         "collected through `claude -p` on the owner's plan, except the final 11 Claude c2 holes "
         "(9 CREST, 2 Deaver), collected through the gateway in W46.seg-lincoln-cloud-paid. "
         "Same Sonnet 5.5, inline images instead of tool reads; c2 is a mixed-transport result. "
         "The ChatGPT arm was dropped by the owner. Same 7-page windows, stride "
         "3, combining and assembly as every window source; FarmShare rows are the committed open-model caches.", "",
         "Public window rows use the models' own photo calls, matching the public scorer. A dash in the review "
         "column means correcting free document gaps alone cannot reach 98% (including false photo/fixed errors). "
         "The rule baseline and its confidence estimates come from the committed owner-only frozen fit, "
         "rather than refitting against the public cache, which has no owner OCR.", "",
         notes.strip(), "", "## Lincoln and CREST, every source, old and new scorers", ""]
    for box, b in pub["boxes"].items():
        L += public_table(box, b)
    L += ["## The stated letter cue (G-entities test 4, prompt arm): c2 against c1, same route", "",
          *cue_table(owner, pub), ""]
    return "\n".join(L) + "\n"


def main(argv) -> int:
    if argv[:1] == ["public"] and len(argv) == 2:
        public(Path(argv[1]))
    elif argv == ["owner"]:
        owner()
    elif argv[:1] == ["report"]:
        notes = Path(argv[1]).read_text() if len(argv) > 1 else ""
        REPORT.write_text(render(json.loads(PUBLIC_JSON.read_text()), json.loads(OWNER_JSON.read_text()), notes))
        print(f"wrote {REPORT}")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
