#!/usr/bin/env python3
"""Build ArchiveOCRBench's data file and chart page from the bench's committed results.

Reads, in ../ArchiveProcessor/segbench-results/, the W41 OCR panel's reports and per-attribute CSVs, the
routes run on our own hardware (ocr-mac-local.md, ocr-mac-local-hw.md and their groups CSV; farmshare/truth/<run>/summary.json and
pages.csv), the segmentation reports (options.md, cheap-models.md), the date-tagging score (date-tagging.json), plus the hand-entered figures in data/inputs.json and
the Vision OCR lab's handwriting figures in data/vision-ocr-handwriting.json, and the per-page tables
(ocr-pages.csv, ocr-pages-agree.csv) that difficulty.py turns into page difficulty and cascades, and writes:

  data/panel-data.json   every OCR route's score per chart, its answered pages and its price; every
                         segmentation approach's test-box figures; the handwriting readers
  site/index.html        the chart page (site/template.html with the data filled in)
  difficulty.md          page difficulty, failures apart from accuracy, cascades (W41.bench-difficulty)

Run from anywhere:  python3 ArchiveOCRBench/build.py
Add --check to fail instead of writing when either output is out of date.
"""
import csv
import json
import random
import re
import sys
from collections import Counter
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

import difficulty

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parent / "ArchiveProcessor" / "segbench-results"
CLOUD_MD = RESULTS / "ocr-panel-cloud.md"
LOCAL_MD = RESULTS / "ocr-panel-local.md"
CLOUD_CSV = RESULTS / "ocr-panel-cloud-groups.csv"
LOCAL_CSV = RESULTS / "ocr-panel-local-groups.csv"
GATEWAY_MD = RESULTS / "gemini37-vs-38.md"  # W46.fix-ocr-scorers-paid: gateway_gemini.py report, Gemini 3.7 Flash
GATEWAY_CSV = RESULTS / "gemini37-vs-38-groups.csv"
GATEWAY_ROUTES = {"gemini3.7-flash-gw"}
# W46.ocr-new-open's Mac readers and W46.ocr-new-open-boxes's granite-docling, added after the difficulty fit was built:
# on the headline and speed tables, not in the fit.
LATE_MAC_ROUTES = {"xiaomi-ocr-0-bf16", "paddleocr-vl1.6-bf16", "granite-docling-258m-mlx", "apple-fm-27"}
MAC_MD = RESULTS / "ocr-mac-local.md"
MAC_CSV = RESULTS / "ocr-mac-local-groups.csv"
FOUNDATION = RESULTS / "r1-foundation.json"  # W46.r1-foundation: fm_foundation.py report, Apple's on-device model
FARMSHARE = RESULTS / "farmshare" / "truth"
PANEL_PY = HERE.parent / "ArchiveProcessor" / "scripts" / "segbench" / "ocr_panel.py"
OPTIONS_MD = RESULTS / "options.md"
CHEAP_MD = RESULTS / "cheap-models.md"
STUDENTS_MD = RESULTS / "seg-students.md"  # W41.seg-finetune: the fine-tuned 4B and 2B
TEACHER_MD = RESULTS / "seg-teacher.md"  # W41.seg-27b-test: the FarmShare teacher, scored as cheap-models.md scores
INPUTS = HERE / "data" / "inputs.json"
HANDWRITING = HERE / "data" / "vision-ocr-handwriting.json"
R6_SPOT = HERE / "data" / "r6-spot.json"
KIND_CLASSIFIER = RESULTS / "kind-classifier.json"  # W41.bench-kind-classifier: kind_classifier.py report
KIND_ATRIUM = RESULTS / "kind-atrium.json"  # W46.kind-mixed-support: covered estimates and full-call bounds
DATING = RESULTS / "date-tagging.json"  # W41.date-tag-measure: date_tagging.py score
DATING_PUBLIC = RESULTS / "date-tagging-public.json"
DATING_TRACEABLE = RESULTS / "date-traceable.json"  # W46.date-traceable: date_traceable.py score
DATING_TRACEABLE_PAID = RESULTS / "date-traceable-paid.json"  # W46.date-traceable-paid: date_traceable_gateway.py score
DATING_ENCLOSURE = RESULTS / "date-enclosure.json"  # W46.date-enclosure: date_enclosure.py score
DATING_IMAGE = RESULTS / "date-image.json"  # W46.date-image: date_image.py score
DATING_UNDATED = RESULTS / "date-undated.json"  # W46.date-undated: date_undated.py score
PUBLIC = RESULTS / "bench-corpus"  # W43.corpus-build: corpus/routes.py report, the public strata
OCR_SCORERS = RESULTS / "ocr-scorers.json"  # W46.fix-ocr-scorers: ocr_rescore.py, every cached reading re-scored
TRUTH_BIAS = RESULTS / "ocr-truth-bias.json"  # W46.fix-ocr-truth-bias: ocr_truth_bias.py, agreed v adjudicated words
HANDS_RESCORE = RESULTS / "ocr-hands-rescore.json"  # W46.ocr-hands-rescore: the hand pages on the owner's sheet
TRUTH_JPEG = RESULTS / "truth-jpeg-upgrade.json"  # W46.truth-jpeg-upgrade: truth_jpeg_upgrade.py score, PDF image v JPEG
TRUTH_BIAS_SCORE = RESULTS / "ocr-truth-bias-score.json"  # W46.fix-ocr-truth-bias-score: the owner's blind check
CHAOS = RESULTS / "chaos-probe.json"  # W46.fix-ocr-scorers: chaos_probe.py score, the altered-word probe
DEWARP = RESULTS / "enh-dewarp.json"  # W46.enh-dewarp: enh_dewarp.py report, crop or dewarp against raw, by reader
VISION_REREAD = RESULTS / "vision-27-reread.json"  # W46.vision-27-reread: Apple Vision on macOS 27.2 against 26.6
VISION_UNFILTERED = RESULTS / "ocr-vision-unfiltered.json"  # W46.ocr-vision-unfiltered: its failure rate on owner pages
ROTATION = RESULTS / "rotation-routes.json"  # W46.rotation-routes: every rotation route on the same turned pages
CAPTURE = RESULTS / "capture-ladder.json"  # W46.capture-ladder: capture_ladder.py report, capture defects by reader
ENH_OCR = RESULTS / "enh-ocr-input.json"  # W46.enh-ocr-input: enh_ocr_input.py report, content-removing enhancement
COLOUR_DROPOUT = RESULTS / "ocr-colour-dropout.json"  # W46.ocr-input-colour-dropout: ocr_colour_dropout.py report
ENH_MARKS = RESULTS / "enh-ocr-marks.json"  # W46.enh-ocr-input-marks: the mark-region ink check
POSTCORRECT = RESULTS / "ocr-postcorrect.json"  # W46.ocr-postcorrect: postcorrect.py score --results, the band corrector
LOGPROB = RESULTS / "ocr-logprob.json"  # W46.ocr-logprob: ocr_logprob.py report, log-probabilities as an error flag
LAYOUT_ORDER = RESULTS / "layout-order.json"  # W46.layout-order: layout_order.py run, ordering with detection fixed
LAYOUT_ORDER_MARKS = RESULTS / "layout-order-marks.json"  # W46.layout-order-marks: the 96 and the marks core
MARKS_DETECT = RESULTS / "marks-detect.json"  # W46.marks-detect: marks_detect.py report, trained marks detectors
MIXED_ROUTE = RESULTS / "mixed-route.json"    # W46.mixed-route: mixed_route.py report, marks read whole page or by box
MIXED_BANDS = RESULTS / "mixed-route-bands.json"   # W46.mixed-route-bands: mixed_route_bands.py report
LAYOUT_ORDER_PP = RESULTS / "layout-order-pp.json"  # W46.layout-order-newspapers-pp: orderers on PP-DocLayoutV3's L9 regions
LAYOUT_ORDER_PAID = RESULTS / "layout-order-paid.json"  # W46.layout-order-paid: Gemini 3.7 Flash's blocks in its order
DEWARP_GUARD_REAL5 = RESULTS / "dewarp-guard-real5.json"  # W46.dewarp-guard: Apple Vision on Real5 Warping, raw/quad/UVDoc
LAYOUT_PHOTO = RESULTS / "layout-photo.json"  # W46.layout-photo: layout_photo.py score, four detectors feeding GLM-OCR
RERUN_NOISE = RESULTS / "ocr-rerun-noise.json"  # W46.ocr-rerun-noise: ocr_rerun_noise.py report, the 96 read three times
LOOPS = PUBLIC / "loop-rerun-20261021.json"  # W46.ocr-loops: corpus/loop_rerun.py report, the capped pages read again
REGIONS = PUBLIC / "regions-20261021.json"  # W46.ocr-regions: whole page, detector regions and overlapping tiles
REGIONS_GW = PUBLIC / "regions-gateway-20261028.json"  # W46.ocr-regions-paid: corpus/regions_gateway.py score, Gemini 3.7
REGIONS_ORDERFREE = PUBLIC / "regions-orderfree-20261030.json"  # W46.ocr-rescore-offline: corpus/regions_orderfree.py
PPOCRV6_HANDS = RESULTS / "ocr-ppocrv6-hands.json"  # W46.ocr-ppocrv6-hands: ocr_ppocrv6_hands.py report, kraken PP-OCRv6
# The line routes that item measured; every other row of its tables is a cached comparator already on the page.
PPOCRV6_HANDS_ROUTES = ("ppocrv6-kraken-blla", "ppocrv6-kraken-vision", "apple-vision (lines)")
OCR_PAGES = RESULTS / "ocr-pages.csv"  # ocr_pages_export.py: every whole-page route's score on every page of the 96
OCR_SCORERS_PAGES = RESULTS / "ocr-scorers-pages.csv"
TIME_LFL = RESULTS / "ocr-time-like-for-like.json"    # W46.ocr-time-like-for-like: Mac seconds a page, like for like  # ocr_rescore.py's per-page rows, both sets
OPEN_SWEEP = HERE / "data" / "open-sweep-20261019.json"  # the open-model sweep's receipts (hand-entered, sourced)
# Later native routes: reports in PUBLIC, receipts in data/, with the same names.
OPEN_SWEEP_LATER = ("new-open-sherlock-20261024", "new-open-sherlock-20261031", "new-open-boxes-20261031")
TEMPLATE = HERE / "site" / "template.html"
OUT_DATA = HERE / "data" / "panel-data.json"
OUT_PAGE = HERE / "site" / "index.html"
OUT_DIFFICULTY = HERE / "difficulty.md"


def table_after(md, heading, nth=0):
    """Rows of the nth Markdown table (0 = the first) after a heading line, as lists of stripped cells."""
    lines = md.splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith(heading))
    tables, rows, seen = [], [], False
    for l in lines[start + 1:]:
        if l.startswith("|"):
            seen = True
            cells = [c.strip() for c in l.strip().strip("|").split("|")]
            if not set("".join(cells)) <= set("-: "):
                rows.append(cells)
        elif seen:
            tables.append(rows[1:])  # drop the header row
            if len(tables) > nth:
                break
            rows, seen = [], False
    if seen:
        tables.append(rows[1:])
    return tables[nth]


def route_id(cell):
    return cell.split("·")[0].strip().strip("`")


def dollars_per_1000(cell):
    """A report's per-page dollar cell as unrounded dollars per 1,000 pages; rounding waits for the batch halving."""
    m = re.search(r"\$([0-9.]+)", cell)
    return float(m.group(1)) * 1000 if m else None


def cents(v):
    """Round half up to the cent, so half of $5.55 shows as $2.78 rather than float rounding's $2.77."""
    return float(Decimal(str(v)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def openrouter_price(op, preset, prompt, completion):
    """Dollars per 1,000 requests at OpenRouter's list price for the same open-weight model (inputs.json ->
    openrouter_open_weights), from a run's mean tokens a request. None for a model that fits on the Mac, which stays free."""
    m = op["models"].get(re.sub(r"-dyn$", "", preset))
    return None if m is None else (prompt * m["in"] + completion * m["out"]) / 1e3


def dating_traceable():
    """The staged dating pipeline's rows for the page: every one-shot and trace row, and every pipeline configuration
    on the owner's set at the two ends of the threshold (t=0, t=3), with its exact-year shares by class, evidence and
    GPU-seconds per 1,000 documents."""
    if not DATING_TRACEABLE.exists():
        return None
    d = json.loads(DATING_TRACEABLE.read_text())

    def cut(s):
        ev = s.get("evidence", {})
        return {"exact": {k: s["exact"].get(k) for k in ("all year-tagged", "in text", "A+A'+B", "C+D", "not in text")},
                "valid": ev.get("valid", 0), "unsupported": ev.get("unsupported", 0), "invalid": s["invalid"]}
    rows = [{"kind": "one shot", "name": k.split("|", 1)[1], **cut(s)} for k, s in d["one_shot"].items()
            if k.startswith("owner|")]
    rows += [{"kind": "one shot", "name": "qwen3.6-27b-nothink, trace prompt " + k.split("|", 1)[1], **cut(s)}
             for k, s in d["trace"].items() if k.startswith("owner|")]
    for k, s in d["pipeline"].items():
        setname, chooser, residue, t = k.split("|")
        if setname == "owner" and t in ("t=0", "t=3"):
            rows.append({"kind": "pipeline", "name": f"{chooser}, {residue}, {t}", **cut(s),
                         "gpu_s_1000": s["per_1000"]["gpu_s"], "mac_s_1000": s["per_1000"]["mac_s"]})
    if DATING_TRACEABLE_PAID.exists():
        # Gemini 3.7 Flash on the gateway: its one-shot rows were asked only for the 131 not in the text, so the
        # columns over all year-tagged and printed documents are left empty rather than read on a subset
        p = json.loads(DATING_TRACEABLE_PAID.read_text())
        for k, s in p["one_shot"].items():
            if k.startswith("Gemini 3.7"):
                c = cut(s)
                c["exact"].update({"all year-tagged": None, "in text": None})
                rows.append({"kind": "one shot", "name": k + ", on the 131 not in the text", **c})
        for k, s in p["pipeline"].items():
            chooser, residue, t = k.split("|")
            if residue.startswith("Gemini") and t in ("t=0", "t=3"):
                rows.append({"kind": "pipeline", "name": f"{chooser}, {residue}, {t}", **cut(s), "gpu_s_1000": None,
                             "usd_1000": round(1000 * p["usd_per_reply"] * s["residue_calls"] / s["n"], 2)})
    va = d.get("vision_arms") or {}
    reread = [{"name": k, "corpus": cut(c["corpus"]), "reread": cut(c["reread"]),
               "gpu_s_1000": (c.get("per_1000") or {}).get("gpu_s")} for k, c in (va.get("configs") or {}).items()]
    return {"rows": rows, "vision": {k: cut(v) for k, v in (d.get("vision") or {}).items() if isinstance(v, dict) and "exact" in v},
            "reread": reread, "classes": va.get("classes")}


def dating_enclosure():
    """The enclosure panel's rows: each arm's result on the owner's relation truth, its firing rate on the structural
    proxy (A, A' and the matched negatives) and its proposals' propagated years."""
    if not DATING_ENCLOSURE.exists():
        return None
    d = json.loads(DATING_ENCLOSURE.read_text())
    rows = [{"arm": k, "name": a["name"], "owner": a["owner"]["confusion"], "precision": a["owner"]["precision"],
             "recall": a["owner"]["recall"], "rate": {g: [a["rate"][g]["fired"], a["rate"][g]["of"]] for g in ("A", "A'", "neg")},
             "auc": a["auc_proxy"], "seconds": a["seconds_mean"], "propagation": a["propagation"]}
            for k, a in d["arms"].items()]
    return {"set": d["set"], "rows": rows}


IMAGE_ARMS = {"qwen3.6-27b": "Qwen3.6-27B (Sherlock, 2,400 px)",
              "mac:qwen3-vl-8b-mlx4-1400": "Qwen3-VL 8B, 4-bit MLX (this Mac, 1,400 px)",
              "gw:gemini3.7-flash-gw-2400": "Gemini 3.7 Flash (Stanford gateway, 2,400 px)"}


def dating_image():
    """The date-image panel: dates read off the page images of the unprinted-year documents, per arm and variant, and
    the look-alike retrieval against the positional baselines. Reads whatever arms the result file holds."""
    if not DATING_IMAGE.exists():
        return None
    d = json.loads(DATING_IMAGE.read_text())
    rows = []
    for key, v in d["summary"].items():
        arm, variant = key.rsplit("|", 1)
        rows.append({"arm": arm, "name": IMAGE_ARMS.get(arm, arm), "variant": variant, "n": v["n"], "exact": v["exact"],
                     "within1": v["within1"], "on_page": v["on_page"]})
    ret = d["retrieval"]["summary"]
    retrieval = [{"cls": c, **{a: [ret[c][a]["exact"], ret[c][a]["within1"], ret[c][a]["n"]]
                               for a in ("prev", "near", "nn1", "knn")}}
                 for c in ("D", "C", "B", "A", "A'", "all") if c in ret]
    return {"rows": rows, "retrieval": retrieval}


def money_cells(cell):
    """'$16.93 / $8.47' or '$0.48' or 'none' -> (standard, batch) in dollars per 1,000 pages."""
    vals = [float(v) for v in re.findall(r"\$([0-9.]+)", cell)]
    return (vals[0] if vals else 0.0), (vals[1] if len(vals) > 1 else None)


def pct(cell):
    return None if cell in ("—", "") else float(cell.rstrip("%"))


def agreement_pages():
    """The three agreement-only letters the panel leaves out of its 96 accuracy pages, read from ocr_panel.py."""
    m = re.search(r"^AGREEMENT = \{([^}]*)\}", PANEL_PY.read_text(), re.M)
    return set(re.findall(r"'(p\d+)'", m.group(1)))


def mac_route(spec, kinds):
    """A Mac-local route: scores from the groups CSV, speed and memory from its report's table (ocr-mac-local.md unless
    the route names its own report and speed heading, as the W41.mac-local-hw models do in ocr-mac-local-hw.md)."""
    with MAC_CSV.open(newline="") as f:
        rows = {(r["attribute"], r["value"]): r for r in csv.DictReader(f) if r["model"] == spec["key"]}
    if not rows:
        return None  # registered before its results landed (W46.ocr-new-open-boxes's granite-docling): not drawn yet
    sc = lambda r: [round(100 * float(r["nes"]), 2), int(r["ok"]), int(r["n"])]
    md = RESULTS / spec.get("report", MAC_MD.name)
    speed = {c[0]: c for c in table_after(md.read_text(), spec.get("speed", "## Speed and memory"))}
    page_s = float(speed["seconds a page (prompt + generation)"][1])
    peak = speed["MLX peak memory, GB"]
    return ({"overall": sc(rows[("all", "accuracy-96")]), **{k: sc(rows[("kind", k)]) for k in kinds}},
            {"seconds": page_s, "peak_gb": float(peak[1]), "peak_max_gb": float(peak[3])})


def farmshare_run(run, kinds, op, price=None):
    """One FarmShare run: per-kind scores from pages.csv over the 96 accuracy pages, checked against summary.json, and
    its price at OpenRouter's rate for the same model (or the route's own entered OpenRouter price); None when
    OpenRouter does not sell the model."""
    d = FARMSHARE / run
    summary = json.loads((d / "summary.json").read_text())
    agree = agreement_pages()
    with (d / "pages.csv").open(newline="") as f:
        pages = [r for r in csv.DictReader(f) if r["page"] not in agree]
    acc = summary["accuracy_96"]

    def sc(rr):
        return [round(100 * sum(float(r["nes"]) for r in rr) / len(rr), 2), sum(r["ok"] == "True" for r in rr), len(rr)]
    overall = sc(pages)
    if overall[1:] != [acc["ok"], acc["n"]] or abs(overall[0] - round(100 * acc["nes"], 2)) > 1e-9:
        sys.exit(f"{run}: pages.csv over the 96 accuracy pages gives {overall}, summary.json says {acc}")
    tp = summary["throughput"]
    return ({"overall": overall, **{k: sc([r for r in pages if r["kind"] == k]) for k in kinds}},
            {"photos_per_hour": tp["pages_per_hour_per_gpu"], "gpus": tp["gpus"],
             "gpu_hours_per_100k": 100000 / tp["pages_per_hour_per_gpu"],
             "usd_per_1000": run_price(op, summary["env"]["FS_PRESET"], tp, price)})


def run_price(op, preset, tp, price=None):
    """A FarmShare run's dollars per 1,000 pages at OpenRouter's rate: a route's own entered price first, else
    openrouter_open_weights; None for a model OpenRouter does not sell."""
    pt, ct = tp.get("mean_prompt_tokens", 0), tp.get("mean_completion_tokens", 0)
    if price:
        return (pt * price["in"] + ct * price["out"]) / 1e3
    return openrouter_price(op, preset, pt, ct)


def segmentation(op):
    """Test-box figures (Stanton and RG 165, 363 pages) for every segmentation approach, each at the flag
    level frozen on the development boxes for the 98% bar: options.md's five, then cheap-models.md's finalists."""
    seg = []
    for c in table_after(OPTIONS_MD.read_text(), "## The five figures"):
        std, batch = money_cells(c[5])
        row = {"name": c[0], "nocheck": pct(c[1]), "checks": float(c[2]), "after": pct(c[3]),
               "unflagged": int(re.search(r"\((\d+)\)", c[4]).group(1)), "std": std, "batch": batch,
               "source": "options.md"}
        # The corpus-trained 2B the app runs on the user's Mac (W41.app-local-seg): free, so in the table and off the
        # price chart, as the FarmShare rows are.
        if "on this Mac" in c[0]:
            row.update(name=c[0] + " (scored at full precision on FarmShare)", std=None, batch=None, mac=True)
        # W46.seg-text-tier-app: the app's text-only Gemini 3.8 tier, its level and figures Gemini 3.7 Flash's (gateway).
        if c[0].startswith("Gemini only, text alone"):
            row.update(name=c[0] + " (3.8 sends it; figures are Gemini 3.7 Flash's, gateway)")
        seg.append(row)
    shipped_mac = next((a for a in seg if a.get("mac")), None)
    cheap = CHEAP_MD.read_text()
    costs = {c[0]: c for c in table_after(cheap, "### The level fitted per model", 1)}
    gemini = next(a for a in seg if a["name"] == "Gemini only")
    # W46.seg-magazine-rule-app: the app's Gemini voter sends g2, and options.md's row is Gemini 3.7 Flash's g2 answers
    # through the gateway at a level fitted on them. The other reports' "Gemini 3.8 Flash" rows are 3.8 on g1, which
    # options.json keeps as the row it replaced; they are checked against that.
    gem_row = next(a for a in json.loads((RESULTS / "options.json").read_text())["approaches"] if a["id"] == "gemini")
    replaced = gem_row.get("replaces")
    # W46.seg-g2-offsets: the shown figure is one offset; the point carries its range over three window offsets.
    if gem_row.get("offsets"):
        gemini["range"] = [round(100 * v, 1) for v in gem_row["offsets"]["range"]["pages_exact_no_review"]]
    if replaced:
        gemini["name"] = "Gemini only (3.8 sends g2; figures are Gemini 3.7 Flash's g2, gateway)"
        t = replaced["test"]
        gemini = {"nocheck": round(100 * t["pages_exact_no_review"], 1), "after": round(100 * t["pages_exact_after_review"], 1),
                  "checks": round(t["flagged_per_100_pages"], 1), "unflagged": t["unflagged_errors"]}
    for c in table_after(cheap, "### The level fitted per model"):
        if c[1] != "98%":
            continue
        row = {"nocheck": pct(c[5]), "after": pct(c[6]), "checks": float(c[7]), "unflagged": int(c[8])}
        if c[0].startswith("Gemini 3.8 Flash"):
            # cheap-models.md says its Gemini row reproduces options.md at this bar; fail if they ever part
            if any(row[k] != gemini[k] for k in row):
                sys.exit(f"cheap-models.md's Gemini row at 98% no longer matches options.md: {row}")
            continue
        # A finalist the app offers is an approach in options.md (GLM-5.3 Flash, W41.app-openrouter): shown once,
        # from there, and the two files must agree.
        shipped = next((a for a in seg if a["name"].startswith(c[0] + " only")), None)
        if shipped:
            if any(row[k] != shipped[k] for k in row):
                sys.exit(f"cheap-models.md's {c[0]} row at 98% no longer matches options.md: {row}")
            # options.json has no batch price for it (the app has no OpenRouter batch route); the bench measured one
            if shipped["batch"] is None:
                shipped["batch"] = money_cells(costs[c[0]][4] + " " + costs[c[0]][5])[1]
            continue
        std, batch = money_cells(costs[c[0]][4] + " " + costs[c[0]][5])
        seg.append({"name": c[0], **row, "std": std, "batch": batch, "source": "cheap-models.md"})
    # Open weights on FarmShare's GPUs, scored the same way: the teacher (W41.seg-27b-test), too large for the Mac, at
    # OpenRouter's rate for its measured tokens a window, its one FarmShare run's windows over pages; and the
    # fine-tuned Mac segmenters it taught (W41.seg-finetune), free because they fit on the Mac, so off the price chart.
    t = json.loads((FARMSHARE_ROOT / "seg" / "qwen3.5-27b" / "summary.json").read_text())
    pages = t["pages_per_hour_per_gpu"] * t["wall_s"] / 3600
    teacher_usd = cents(openrouter_price(op, t["label"], t["mean_prompt_tokens"], t["mean_gen_tokens"]) * t["windows"] / pages)
    for md, suffix in ((TEACHER_MD, " on FarmShare (the corpus teacher)"),
                       (STUDENTS_MD, " (trained on the corpus; FarmShare figures)")):
        if not md.exists():
            continue
        for c in table_after(md.read_text(), "### The level fitted per model"):
            if c[1] != "98%":
                continue
            row = {"nocheck": pct(c[5]), "after": pct(c[6]), "checks": float(c[7]), "unflagged": int(c[8])}
            if c[0].startswith("Gemini 3.8 Flash"):
                if any(row[k] != gemini[k] for k in row):
                    sys.exit(f"{md.name}'s Gemini row at 98% no longer matches options.md: {row}")
                continue
            # The 2B the app offers is options.md's on-this-Mac approach: shown once, from there, and the two agree.
            if md == STUDENTS_MD and shipped_mac and c[0] == "Qwen3.5 2B, fine-tuned":
                if any(row[k] != shipped_mac[k] for k in row):
                    sys.exit(f"{md.name}'s 2B row at 98% no longer matches options.md: {row}")
                continue
            seg.append({"name": c[0] + suffix, **row, "std": teacher_usd if md == TEACHER_MD else None, "batch": None,
                        "farmshare": True, "source": md.name})
    # W46.seg-adapt-curve: doc-split-v1 (open ONNX, the Mac's CPU), scored the same way; its 2B row must reproduce
    # options.md's, which checks the reimplemented level fit.
    adapt = RESULTS / "seg-adapt-curve-owner.json"
    if adapt.exists():
        fz = json.loads(adapt.read_text())["frozen"]
        r2 = fz["2B"]
        if shipped_mac and (round(r2["nocheck"], 1), round(r2["checks"], 1)) != (shipped_mac["nocheck"], shipped_mac["checks"]):
            sys.exit(f"seg-adapt-curve-owner.json's 2B row no longer matches options.md: {r2}")
        for k, label in (("doc-split-v1, zero-shot", "doc-split-v1 zero-shot (open, Mac CPU; not in the app)"),
                         ("doc-split-v1, dev refit", "doc-split-v1 refit on the development boxes (open, Mac CPU; not in the app)")):
            r = fz[k]
            seg.append({"name": label, "nocheck": round(r["nocheck"], 1), "checks": round(r["checks"], 1),
                        "after": round(r["after"], 1), "unflagged": r["unflagged"], "std": None, "batch": None,
                        "mac": True, "source": adapt.name})
    # W46.seg-text-tier-test: Gemini 3.7 Flash's g2 window with the images dropped, at the shipped Gemini level, its
    # price from its own tokens on the test boxes (batch at half list, as options.md's Gemini row). Its image arm must
    # reproduce options.md's Gemini only row, which checks it was scored the same way.
    tier = RESULTS / "seg-text-tier-test.json"
    if tier.exists():
        d = json.loads(tier.read_text())
        f = lambda x: {"nocheck": round(100 * x["pages_exact_no_review"], 1), "checks": round(x["flagged_per_100_pages"], 1),
                       "after": round(100 * x["pages_exact_after_review"], 1), "unflagged": x["unflagged_errors"]}
        shipped = next(a for a in seg if a["name"].startswith("Gemini only"))
        if any(f(d["arms"]["image"]["figures"])[k] != shipped[k] for k in ("nocheck", "checks", "after", "unflagged")):
            sys.exit(f"seg-text-tier-test.json's image arm no longer matches options.md: {d['arms']['image']['figures']}")
        c = d["per_1000_pages"]["text"]
        seg.append({"name": "Gemini only, text alone at the image level, <= 0.965 (3.7 Flash, gateway)",
                    **f(d["arms"]["text"]["figures"]), "std": cents(c["list"]), "batch": cents(c["batch"]),
                    "source": tier.name})
    return seg


def seg_context():
    """W46.seg-context: each window with and without a COLLECTION FACTS block, beside a rerun's vote flips."""
    path = RESULTS / "seg-context.json"
    if not path.exists():
        return None
    d = json.loads(path.read_text())
    if d["incomplete"]:
        sys.exit(f"seg-context.json has incomplete cells: {d['incomplete'][:1]}")
    return {"rows": [{k: r[k] for k in ("model", "box", "arm", "pages_exact", "boundary_f1", "false_splits",
                                        "false_merges")} for r in d["rows"] if "arm" in r],
            "vote_flips": d["vote_flips"]}


def seg_adapt_lora():
    """W46.seg-adapt-lora: the corpus 2B against its LoRA continuations on a user's corrected gaps of one Lincoln box,
    scored on box 1's gaps after the training ones and on a second box no training row saw."""
    path = RESULTS / "seg-adapt-lora.json"
    if not path.exists():
        return None
    d = json.loads(path.read_text())
    if any(d["failed_windows"].values()):
        sys.exit(f"seg-adapt-lora.json has failed windows: {d['failed_windows']}")
    rows = []
    for box, b in d["boxes"].items():
        for label, s in b["sets"].items():
            for arm, t in s["arms"].items():
                rows.append({"box": box, "set": label, "arm": arm, "gaps": t["gaps"], "errors": t["errors"],
                             "err_per_100": t["err_per_100"], "false_splits": t["fs"], "false_merges": t["fm"],
                             "starts": [t["catalogue"][0] + t["internal"][0], t["catalogue"][1] + t["internal"][1]],
                             "paired": s["paired"].get(arm), "rerun": s.get("rerun", {}).get("paired") if arm == "base" else None})
    return {"rows": rows}


def seg_window_modality():
    """W46.seg-window-modality: the 2B's window sizes with and without images, and the three models' six-run vote,
    pooled over the development and test boxes, with Lincoln on its own."""
    path = RESULTS / "seg-window-modality.json"
    if not path.exists():
        return None
    d = json.loads(path.read_text())
    # The one kind of cell allowed to be missing: a whole folder the 2B never answered parseably (the report says so).
    if any(not x.startswith("2b-folder folder-") for x in d["incomplete"]):
        sys.exit(f"seg-window-modality.json has incomplete cells: {d['incomplete'][:1]}")
    keep = ("model", "arm", "pages_exact", "boundary_f1")
    out = {"pooled": [{"pool": r["pool"], **{k: r[k] for k in keep}} for r in d["pooled"]] +
                     [{"pool": "lincoln", **{k: r[k] for k in keep}} for r in d["rows"] if r["box"] == "Lincoln"],
           "incomplete": d["incomplete"]}
    # W46.seg-window-modality-paid: Gemini 3.7 Flash through the gateway, K = 7 on the three boxes, sizes on Deaver.
    gw = RESULTS / "seg-window-gateway.json"
    if gw.exists():
        g = json.loads(gw.read_text())
        if g["incomplete"]:
            sys.exit(f"seg-window-gateway.json has incomplete cells: {g['incomplete'][:1]}")
        out["gateway"] = {"pooled": [{k: r[k] for k in ("arm", "boxes", "pages", "pages_exact", "boundary_f1",
                                                        "false_splits", "false_merges")} for r in g["pooled"]],
                          "paired": g["paired"], "spent": g["spent"],
                          "loss_difference": g.get("loss_difference")}
    return out


def seg_tabme():
    """W46.seg-tabme: the students and the teacher over TABME++'s test split (clean scans, public), with the published
    references the report compares them to."""
    path = RESULTS / "seg-tabme.json"
    if not path.exists():
        return None
    d = json.loads(path.read_text())
    if d["incomplete"]:
        sys.exit(f"seg-tabme.json has incomplete arms: {d['incomplete'][:1]}")
    rows = [{**{k: r[k] for k in ("arm", "boundary_f1", "pages_exact", "doc_f1", "false_splits", "false_merges")},
             "interval": d["intervals"][r["arm"]]["boundary_f1"]} for r in d["rows"] if r["arm"] != "no-boundaries"]
    # Hand-entered from the papers (execution-plans/processing-review/A-segmentation.md), different protocols.
    refs = [["Mistral-7B LoRA, fine-tuned on TABME++ (A05)", 0.987], ["Phi-3-mini LoRA, fine-tuned (A05)", 0.973],
            ["Best encoder or XGBoost, trained on TABME++ (A05)", 0.831], ["Gemini 3.1 Flash-Lite, zero-shot text, K = 7 (A04)", 0.863],
            ["Claude Haiku 4.5, zero-shot text, K = 7 (A04)", 0.782], ["GPT-5.4-mini, zero-shot text, K = 7 (A04)", 0.739],
            ["doc-split-v1, zero-shot (A20)", 0.704]]
    out = {"rows": rows, "refs": refs, "pages": d["stream"]["pages"], "documents": d["stream"]["documents"],
           "gaps": d["stream"]["gaps"]}
    gw = RESULTS / "seg-tabme-gateway.json"   # W46.seg-tabme-paid: Gemini 3.7 Flash on the stream's first documents
    if gw.exists():
        g = json.loads(gw.read_text())
        out["gateway"] = {"subset": g["subset"], "cost": g["ledger"]["charged_usd"],
                          "rows": [{**{k: r[k] for k in ("arm", "boundary_f1", "pages_exact", "doc_f1", "false_splits",
                                                         "false_merges")},
                                    "interval": g["intervals"].get(r["arm"], {}).get("boundary_f1")}
                                   for r in g["rows"] if r["arm"] != "no-boundaries"]}
    return out


def seg_kit_gate_sherlock():
    """W46.kit-gate-sherlock: the teacher and the two students on owner-ruled gaps, the checkpack and the three locked
    boxes, from one Sherlock job."""
    path = RESULTS / "seg-kit-gate-sherlock.json"
    if not path.exists():
        return None
    d = json.loads(path.read_text())
    if any(r["missing"] for r in d["runs"].values()):
        sys.exit(f"seg-kit-gate-sherlock.json has unanswered windows: {d['runs']}")
    # Enforce the writer's provenance/source contract on every build, including after a local rescore.
    sys.path.insert(0, str(HERE.parent / "ArchiveProcessor/scripts/segbench"))
    from kit_gate_sherlock import qualify_boxes
    from copy import deepcopy
    qualified = qualify_boxes(deepcopy(d["boxes"]), RESULTS / "seg-boxes-score-local.json")
    if qualified != d["boxes"]:
        sys.exit("seg-kit-gate-sherlock.json has stale provenance; run kit_gate_sherlock.py refresh")
    return {"sc0122_owner": qualified["sc0122_owner"], "checkpack": [{k: r[k] for k in ("model", "split", "gaps", "right", "false_splits", "false_merges",
                                              "tag_right")} for r in d["checkpack"]["rows"]],
            "boxes": [{k: r[k] for k in ("model", "box", "split", "known gaps", "gap accuracy", "false splits",
                                          "false merges", "pages exact", "truth", "interpretation")} for r in d["boxes"]["observed"]],
            "failed": {k: r["failed"] for k, r in d["runs"].items()}}


def seg_boxes_score():
    """W46.seg-boxes-score: every segmentation route on the three locked boxes, SC0122 on its owner-ruled gaps, and
    Gemini 3.7 at the shipped cloud route's rule and level, three window offsets."""
    path = RESULTS / "seg-boxes-score.json"
    if not path.exists():
        path = RESULTS / "seg-boxes-score-local.json"
        if not path.exists():
            return None
    d = json.loads(path.read_text())
    labels = {"gemini": "Gemini 3.7 Flash (gateway)", "mac-2b": "Shipped 2B, 8-bit, on the Mac",
              "teacher": "Qwen3.5 27B teacher", "fs-2b": "Trained 2B, bf16", "fs-4b": "Trained 4B, bf16"}
    return {"labels": labels, "status": d["status"], "source": path.with_suffix(".md").name,
            "boxes": [{k: r[k] for k in ("route", "box", "split", "known gaps", "gap accuracy", "false splits",
                                          "false merges", "pages exact", "resolved pages", "unsure")} for r in d["observed"]],
            "sc0122": d["sc0122_owner"], "offsets": d["offsets"], "note": d["note"]}


def seg_magazine_rule():
    """W46.seg-magazine-rule-redo: Gemini 3.7's window prompt on the article-within-issue rule (g2) against g1."""
    path = RESULTS / "seg-magazine-rule.json"
    if not path.exists():
        return None
    d = json.loads(path.read_text())
    return {"source": path.with_suffix(".md").name, "review": d["review"], "review_paired": d["review_paired"],
            "test": {v: d["test"]["prompts"][v]["figures"] for v in ("g1", "g2")},
            "test_paired": d["test"]["paired"], "verdict": d["verdict"],
            "usd_per_1000_pages": d["gateway_g2"]["usd_per_1000_pages"]}


def public_segmentation():
    """Separate public/easier boxes; their labels and scores never enter owner-box fitting."""
    root = RESULTS / "public-segmentation"
    boxes = []
    for name in ("crest", "lincoln"):
        path = root / f"{name}-scores.json"
        if not path.exists():
            continue
        truth = json.loads((root / f"{name}.json").read_text())
        result = json.loads(path.read_text())
        import hashlib
        digest = hashlib.sha256(json.dumps(truth, sort_keys=True).encode()).hexdigest()
        if result["truth_sha256"] != digest or result["pages"] != len(truth["pages"]):
            sys.exit(f"{path.name}: scores do not match the frozen public truth")
        boxes.append(result)
    # W46.fix-seg-scorers: the field's scorers on the same answers (rescore.py), joined by source name; the two
    # files must agree on the figure they share.
    field = RESULTS / "seg-scorers-public.json"
    if field.exists():
        rescored = json.loads(field.read_text())["boxes"]
        for b in boxes:
            sources = next(v for k, v in rescored.items() if k.lower() == b["box"].lower())["sources"]
            for k, r in b["models"].items():
                f = sources.get(k) or sources.get(f"window-or-{k}")
                if f is None:
                    continue
                if f["counts"]["pages_exact"] != r["counts"]["pages_exact"]:
                    sys.exit(f"seg-scorers-public.json disagrees with {b['box']}-scores.json on {k}")
                r["field"] = {m: f["metrics"][m] for m in ("pq", "kappa", "mndd", "mndd_per_100_pages")}
    gateway = RESULTS / "seg-lincoln-gateway.json"
    if gateway.exists():
        gateway_data = json.loads(gateway.read_text())
        scored = gateway_data["boxes"]
        for b in boxes:
            box_result = next(v for k, v in scored.items() if k.lower() == b["box"].lower())
            b["failed"] = box_result.get("failed", {})
            for key, failure in b["failed"].items():
                if key in b["models"]:
                    sys.exit(f"failed gateway arm {b['box']}/{key} has a numeric score")
                calls = [c for c in gateway_data["calls"] if c["box"].lower() == b["box"].lower()
                         and c["route"] == "glm" and not c["whole"]]
                timed = [c["wall_s"] for c in calls if "wall_s" in c]
                failure["gateway"] = {"calls": len(calls), "cost_estimate": sum(c["charge"] for c in calls),
                                      "mean_s": sum(timed) / len(timed) if timed else None}
            sources = box_result["sources"]
            for k, f in sources.items():
                r = b["models"].get(k)
                if r is None or {a: v for a, v in r["counts"].items() if a != "collections"} != {
                        a: v for a, v in f["counts"].items() if a != "collections"}:
                    sys.exit(f"seg-lincoln-gateway.json disagrees with {b['box']}-scores.json on {k}")
                r["field"] = {m: f["metrics"][m] for m in ("pq", "kappa", "mndd", "mndd_per_100_pages")}
                route = {"gateway-gemini": "gemini", "gateway-glm": "glm",
                         "gateway-gemini-whole": "gemini", "window-cues-claude-cue": "claude-cue"}[k]
                calls = [c for c in gateway_data["calls"] if c["box"].lower() == b["box"].lower()
                         and c["route"] == route and c["whole"] == k.endswith("-whole")]
                if calls:
                    timed = [c["wall_s"] for c in calls if "wall_s" in c]
                    r["gateway"] = {"calls": len(calls), "cost_estimate": sum(c["charge"] for c in calls),
                                    "mean_s": sum(timed) / len(timed) if timed else None}
    # W46.seg-adapt-curve-paid: the same Gemini windows with a box's k checked gaps as text examples. Scored with the
    # k gaps set to the truth in both arms, so its rows sit in their own table, not beside the unchecked ones.
    fewshot = RESULTS / "seg-adapt-fewshot.json"
    if fewshot.exists():
        fs = json.loads(fewshot.read_text())
        for b in boxes:
            b["fewshot"] = [s for s in fs["settings"] if s["box"].lower() == b["box"].lower()]
            for s in b["fewshot"]:
                g = b["models"].get("gateway-gemini")
                if g and s["zero_shot"]["held_errors"] > g["counts"]["false_splits"] + g["counts"]["false_merges"]:
                    sys.exit(f"seg-adapt-fewshot.json's zero-shot arm on {b['box']} is not the gateway-gemini row")
                s["cost_estimate"] = fs["calls_by_box"].get(b["box"], {}).get("cost")
    return boxes


# The headline ranking of the 96 (W46.ocr-rescore-offline; the measurement audit's OCR-2, OCR-4 and OCR-9).
UNCORRECTABLE = "p081"  # the owner cannot correct its truth (ocr-truth-bias.md), so it is reported apart
BASELINE = "qwen3.6-27b"  # the paired intervals are against Qwen3.6 27B, the local panel's hosted reading
MODEL_FAILURES = ("cap", "refusal", "empty")
# A chart route's own reading of the 895 public pages, as ocr-scorers-pages.csv names it (route, family). A route not
# here has read only the 96; the same model run elsewhere (a hosted route's FarmShare twin) does not count.
PUBLIC_TWIN = {
    "apple-vision": ("apple-vision", "Mac"), "gemini3.8-flash": ("gemini3.8-flash", "reference"),
    "qwen3-vl-235b": ("qwen3-vl-235b", "reference"), "churro-3b-farmshare": ("fs-churro", "FarmShare churro"),
    "glm-ocr-farmshare": ("glm-ocr", "FarmShare native"), "lightonocr3-4b-farmshare": ("lightonocr3-4b", "FarmShare native"),
    "lightonocr3-0.8b-farmshare": ("lightonocr3-0.8b", "FarmShare native"),
    "paddleocr-vl1.5-farmshare": ("paddleocr-vl1.5", "FarmShare native"),
    "ppocrv6-medium-farmshare": ("ppocrv6-medium", "FarmShare pipeline"),
    "ling3-flash-vl-farmshare": ("ling3-flash-vl-fp8", "FarmShare panel"),
    "qwen3-vl-8b-farmshare": ("qwen3-vl-8b", "FarmShare panel"), "qwen3.5-27b-farmshare": ("qwen3.5-27b", "FarmShare panel"),
    "qwen3.5-4b-farmshare": ("qwen3.5-4b", "FarmShare panel"), "qwen3.6-27b-farmshare": ("qwen3.6-27b", "FarmShare panel"),
    "qwen3.6-35b-a3b-farmshare": ("qwen3.6-35b-a3b", "FarmShare panel"),
    "paddleocr-vl1.6-sherlock": ("paddleocr-vl1.6", "Sherlock native"), "qwen3.8-27b-sherlock": ("qwen3.8-27b", "Sherlock panel"),
    "xiaomi-ocr-0-sherlock": ("xiaomi-ocr-0", "Sherlock native"),
    "unlimited-ocr-sherlock": ("unlimited-ocr", "Sherlock native"),
    "nemotron-parse-2-sherlock": ("nemotron-parse-2", "Sherlock native"),
    "infinity-parser2-pro-sherlock": ("infinity-parser2-pro", "Sherlock native"),  # W46.ocr-new-open-sherlock
    "qwen3.5-9b-sherlock": ("qwen3.5-9b", "Sherlock logprob"),  # W46.ocr-logprob's run read both sets
    "gemini3.7-flash-gw": ("gemini3.7-flash-gw", "gateway"),  # W46.ocr-gemini37-895-paid
}
LOGPROB_PAGES = RESULTS / "ocr-logprob-pages.csv"


def bootstrap(d, rounds=10000, seed=0):
    """Mean of paired per-page differences and its 95% bootstrap interval, the interval ocr_panel_score.paired
    computes (seeded alike but drawn differently, so an end can differ from its figure in the second decimal)."""
    rng, n = random.Random(seed), len(d)
    boots = sorted(sum(rng.choices(d, k=n)) / n for _ in range(rounds))
    return {"n": n, "delta": round(100 * sum(d) / n, 2), "lo": round(100 * boots[int(.025 * rounds)], 2),
            "hi": round(100 * boots[int(.975 * rounds) - 1], 2)}


def headline(routes):
    """Every whole-page route on the 96: NES on the pages it answered as the headline, its failures beside it, split
    into the provider's (transport) and the model's own (caps, refusals, empty answers); strict NES with failures as 0;
    the paired difference from Qwen3.6 27B on pages both answered; p081 apart; and whether it read the 895."""
    with OCR_PAGES.open(newline="") as f:
        by = {}
        for r in csv.DictReader(f):
            by.setdefault(r["route"], {})[r["page"]] = (r["ok"] == "True", float(r["nes"]), r["failure"])
    with OCR_SCORERS_PAGES.open(newline="") as f:
        public = Counter((r["route"], r["family"]) for r in csv.DictReader(f) if r["set"] == "public895")
    with LOGPROB_PAGES.open(newline="") as f:
        public.update((r["route"], "Sherlock logprob") for r in csv.DictReader(f) if r["set"] in ("440", "455"))
    base = by[BASELINE]
    out = []
    for r in routes:
        if r["id"] not in by:
            continue
        pp = by[r["id"]]
        pages = sorted(p for p in pp if p != UNCORRECTABLE)
        if len(pages) != 95 or UNCORRECTABLE not in pp:
            sys.exit(f"{r['id']}: ocr-pages.csv holds {len(pp)} of the 96 pages")
        ans = [p for p in pages if pp[p][0]]
        fails = Counter(pp[p][2] for p in pages if not pp[p][0])
        if set(fails) - {"transport", *MODEL_FAILURES}:
            sys.exit(f"{r['id']}: unclassified failures {dict(fails)}")
        both = [p for p in ans if base[p][0]]
        twin = PUBLIC_TWIN.get(r["id"])
        out.append({"id": r["id"], "name": r["name"], "pages": len(pages), "answered": len(ans),
                    "nes_answered": round(100 * sum(pp[p][1] for p in ans) / len(ans), 2),
                    "strict": round(100 * sum(pp[p][1] for p in pages) / len(pages), 2),
                    "transport": fails["transport"], "model": sum(fails[k] for k in MODEL_FAILURES),
                    **{k: fails[k] for k in MODEL_FAILURES},
                    "vs_baseline": None if r["id"] == BASELINE else bootstrap([pp[p][1] - base[p][1] for p in both]),
                    "p081": [pp[UNCORRECTABLE][0], round(100 * pp[UNCORRECTABLE][1], 2)],
                    "public_pages": public.get(twin, 0) if twin else 0})
    out.sort(key=lambda h: -h["nes_answered"])
    return {"baseline": BASELINE, "uncorrectable": UNCORRECTABLE, "rows": out}


def regions_orderfree():
    return json.loads(REGIONS_ORDERFREE.read_text()) if REGIONS_ORDERFREE.exists() else None


def handwriting():
    hw = json.loads(HANDWRITING.read_text())
    bar = hw["bar"]
    for r in hw["readers"]:
        r["passes"] = r["missed"] <= bar["missed"] and r["added"] <= bar["added"]
    return {k: hw[k] for k in ("pages", "words", "bar", "source", "readers", "reference")}


FARMSHARE_ROOT = RESULTS / "farmshare"
PRESET_NAMES = {"qwen3.5-27b": "Qwen3.5 27B", "qwen3.6-27b": "Qwen3.6 27B", "qwen3.6-27b-dyn": "Qwen3.6 27B, fp8 at load time",
                "qwen3.6-35b-a3b": "Qwen3.6 35B-A3B", "qwen3.8-27b": "Qwen3.8 27B", "glm-ocr": "GLM-OCR",
                "qwen3.5-122b-a10b": "Qwen3.5 122B-A10B",
                # truth96 runs of the 895-page open sweep's models (farmshare_truth96.py): native and pipeline routes
                # keep their own prompt, so the name says so, as on the 895
                "glm-ocr-native": "GLM-OCR (native prompt)", "lightonocr3-0.8b-native": "LightOnOCR-3 0.8B (native, image only)",
                "lightonocr3-4b-native": "LightOnOCR-3 4B (native, image only)",
                "paddleocr-vl1.5-native": "PaddleOCR-VL 1.5 (native prompt)", "qwen3.5-4b": "Qwen3.5 4B",
                "qwen3-vl-8b": "Qwen3-VL 8B", "ppocrv6-medium-pipeline": "PP-OCRv6 medium (pipeline, not a VLM)",
                "ling3-flash-vl-fp8": "Ling 3 Flash VL (publisher fp8, 4 GPUs)",
                # W46.ocr-new-open's Sherlock runs, same harness and settings (farmshare_truth96.py)
                "paddleocr-vl1.6-native": "PaddleOCR-VL 1.6 (native prompt)",
                "xiaomi-ocr-0-native": "Xiaomi-OCR-0 (native Markdown prompt)",
                "qwen3.8-27b-sherlock": "Qwen3.8 27B (Sherlock, open sweep settings)",
                "infinity-parser2-pro-native": "Infinity-Parser2-Pro (doc2md prompt, two cards)",
                "unlimited-ocr-native": "Unlimited-OCR (card prompt, boxes)",
                "nemotron-parse-2-native": "Nemotron-Parse 2.0 (card prompt, boxes)"}


def newsbench_table():
    """NewsBench's own score.py table as the run left it: {label: (overall, broadsheet, page)}."""
    out = {}
    for line in (FARMSHARE_ROOT / "news" / "newsbench-score.txt").read_text().splitlines():
        f = line.split()
        if len(f) == 8 and f[-1] == "15":
            out[f[0]] = tuple(float(x) for x in f[1:4])
    return out


def farmshare(op, own_routes):
    """The FarmShare runs (W41.farmshare-run and after): one L40S each unless noted, no money spent, but priced at
    OpenRouter's rate for the same model where it is too large for the Mac. Truth runs from their summary.json;
    newspaper runs from NewsBench's own scores of what each run wrote."""
    def usd(preset, tp):
        v = openrouter_price(op, preset, tp.get("mean_prompt_tokens", 0), tp.get("mean_completion_tokens", 0))
        return None if v is None else cents(v)
    entered = {spec["run"]: spec["price"] for spec in own_routes.values() if spec.get("price")}
    truth = []
    for f in sorted((FARMSHARE_ROOT / "truth").glob("*/summary.json")):
        s = json.loads(f.read_text())
        env, t = s["env"], s["throughput"]
        kv = re.search(r"--kv-cache-dtype (\S+)", env.get("FS_VLLM_ARGS", ""))
        a = s["accuracy_96"]
        truth.append({"label": s["label"], "name": PRESET_NAMES.get(env["FS_PRESET"], env["FS_PRESET"]),
                      "kv": env.get("FS_KV") or ("bf16" if kv and kv.group(1) == "auto" else (kv.group(1) if kv else "?")),
                      "gpus": t["gpus"], "nes": round(100 * a["nes"], 2), "ok": a["ok"], "n": a["n"],
                      "clippings": round(100 * s["clippings"]["nes"], 2), "per_hour": t["pages_per_hour_per_gpu"],
                      "gpu_hours_100k": round(100000 / t["pages_per_hour_per_gpu"]),  # already per GPU
                      "usd_1000": cents(run_price(op, env["FS_PRESET"], t, entered[f.parent.name]))
                                  if f.parent.name in entered else usd(env["FS_PRESET"], t)})
    truth.sort(key=lambda r: -r["nes"])
    nb = newsbench_table()
    news = []
    for f in sorted((FARMSHARE_ROOT / "news").glob("*/summary.json")):
        s = json.loads(f.read_text())
        how = "DocLayout-YOLO 1280 regions, the kit's glm-ocr route" if s.get("layout") else "whole page"
        news.append({"label": s["label"], "how": how, "per_hour": s["throughput"]["pages_per_hour_per_gpu"],
                     "answered": f"{s['throughput']['ok']}/{s['throughput']['pages']}",
                     "usd_1000": usd(s["env"]["FS_PRESET"], s["throughput"])})
    for f in sorted((FARMSHARE_ROOT / "news-layout").glob("*/timing.json")):
        s = json.loads(f.read_text())
        news.append({"label": s["label"], "how": {"doclayout_yolo": "DocLayout-YOLO regions",
                                                   "paddlex": "PP-DocLayout regions"}[s["detector"]] + " (fs_news_layout.py)",
                     "per_hour": s["pages_per_hour_per_gpu"], "answered": f"{s['ok']}/{s['pages']}",
                     "usd_1000": None})  # timing.json records no tokens
    for r in news:
        preset = re.sub(r"-\d+(-(doclayout_yolo|paddlex))?$", "", r["label"])
        r["name"] = PRESET_NAMES.get(preset, preset)
        r["fits_mac"] = re.sub(r"-dyn$", "", preset) not in op["models"]
        if r["label"] not in nb:
            sys.exit(f"no NewsBench score for {r['label']}: rerun score.py into newsbench-score.txt")
        r["overall"], r["broadsheet"], r["page"] = nb[r["label"]]
    news.sort(key=lambda r: -r["overall"])
    refs = [{"label": k, "overall": nb[k][0], "broadsheet": nb[k][1], "page": nb[k][2]}
            for k in ("ll-doclayout-pvl", "glm-ocr-doclayout", "ll-doclayout-glm", "gpt-5.6-luna-paddlex",
                      "gpt-5.6-luna-wholepage") if k in nb]
    bulk_f = FARMSHARE_ROOT / "bulk" / "summary.json"
    bulk = json.loads(bulk_f.read_text()) if bulk_f.exists() else None
    if bulk:  # the Qwen3.6 27B pilot; its tokens are per page in pages.csv
        with (FARMSHARE_ROOT / "bulk" / "pages.csv").open(newline="") as f:
            bp = list(csv.DictReader(f))
        mean = lambda k: sum(int(r[k] or 0) for r in bp) / len(bp)
        per = openrouter_price(op, "qwen3.6-27b", mean("prompt_tokens"), mean("completion_tokens"))
        bulk.update(usd_1000=cents(per), usd_total=cents(per * len(bp) / 1000))
    return {"truth": truth, "news": news, "news_reference": refs, "bulk": bulk}


def public():
    """The reference routes on the frozen public strata, by stratum: corpus/routes.py's routes.csv and the paired
    comparison. None until the routes have run."""
    f = PUBLIC / "routes.csv"
    if not f.exists():
        return None
    num = lambda v: None if v in ("", None) else float(v)
    with f.open(newline="") as fh:
        rows = [{k: (v if k in ("route", "stratum") else num(v)) for k, v in r.items()} for r in csv.DictReader(fh)]
    manifest = [json.loads(l) for l in (PUBLIC / "manifest.jsonl").read_text().splitlines()]
    reference = [json.loads(l) for l in (PUBLIC / "manifest-reference-440.jsonl").read_text().splitlines()]
    reference_keys = {(m["source"], m["page_id"]) for m in reference}
    strata = {}
    for m in manifest:
        s = strata.setdefault(m["stratum"], {"pages": 0, "reference_pages": 0, "sources": set(), "script": m["script"]})
        s["pages"] += 1
        s["reference_pages"] += (m["source"], m["page_id"]) in reference_keys
        s["sources"].add(m["source"])
    spec = PUBLIC / "specialists.csv"   # W43.script-specialists: corpus/specialists.py report
    specialists = None
    if spec.exists():
        with spec.open(newline="") as fh:
            specialists = [{k: (v if k in ("route", "stratum", "contaminated") else num(v)) for k, v in r.items()}
                           for r in csv.DictReader(fh)]
    fs = PUBLIC / "farmshare.csv"
    farmshare_rows = []
    if fs.exists():
        with fs.open(newline="") as fh:
            farmshare_rows = [{k: (v if k in ("route", "stratum") else num(v)) for k, v in r.items()}
                              for r in csv.DictReader(fh)]
    return {"rows": rows, "farmshare": farmshare_rows,
            "paired": json.loads((PUBLIC / "routes-paired.json").read_text()),
            "strata": {k: {**v, "sources": sorted(v["sources"])} for k, v in sorted(strata.items())},
            "specialists": specialists, "open_sweep": open_sweep(num)}


def open_sweep(num):
    """The FarmShare open-model sweep on all 895 frozen pages (corpus/farmshare_expanded_report.py --name
    open-sweep-20261019), with its receipts from data/open-sweep-20261019.json. A review baseline, nothing adopted."""
    f = PUBLIC / "open-sweep-20261019.csv"
    if not f.exists():
        return None
    with f.open(newline="") as fh:
        rows = [{k: (v if k in ("route", "mode", "subset", "stratum") else num(v)) for k, v in r.items()}
                for r in csv.DictReader(fh)]
    meta = json.loads((PUBLIC / "open-sweep-20261019.json").read_text())
    receipts = json.loads(OPEN_SWEEP.read_text())
    if set(receipts["routes"]) != {r["route"] for r in rows}:
        sys.exit("open-sweep receipts and scores name different routes")
    routes, not_scored, later = dict(receipts["routes"]), list(receipts["not_scored"]), []
    for name in OPEN_SWEEP_LATER:  # later runs of new readers through the same harness, on the same manifests
        with (PUBLIC / f"{name}.csv").open(newline="") as fh:
            more = [{k: (v if k in ("route", "mode", "subset", "stratum") else num(v)) for k, v in r.items()}
                    for r in csv.DictReader(fh)]
        m = json.loads((PUBLIC / f"{name}.json").read_text())
        rc = json.loads((HERE / "data" / f"{name}.json").read_text())
        if m["manifest_sha256"] != meta["manifest_sha256"] or m["base_sha256"] != meta["base_sha256"]:
            sys.exit(f"{name} was scored on other manifests than the open sweep")
        if set(rc["routes"]) != {r["route"] for r in more} or set(rc["routes"]) & set(routes):
            sys.exit(f"{name}: receipts and scores name different routes, or reuse an open-sweep route")
        rows += more
        routes.update(rc["routes"])
        not_scored += rc["not_scored"]
        later.append(rc["hardware"])
    return {"rows": rows, "coverage": meta["coverage"], "manifest_sha256": meta["manifest_sha256"],
            "routes": routes, "not_scored": not_scored, "status": receipts["status"],
            "hardware": " ".join([receipts["hardware"], *("Rows marked Sherlock: " + h for h in later)])}


SCORER_FIELDS = ("route", "family", "n", "ok", "nes", "nes_answered", "added_rate", "rewritten_rate", "cmer",
                 "nb_overall", "nb_bowF1", "nb_gap", "suspect_rate", "suspect_precision", "suspect_recall",
                 "order_edit", "order_pages", "markup_pages", "markup_mean_lift")


def ocr_scorers():
    """The review's scorer additions per route on the 96 and on the 895 (whole sets only; the strata stay in the
    report), and the altered-word probe. None until ocr_rescore.py has run."""
    if not OCR_SCORERS.exists():
        return None
    d = json.loads(OCR_SCORERS.read_text())
    out = {s: sorted(({k: r.get(k) for k in SCORER_FIELDS} for r in d["summary"]
                      if r["set"] == s and r["stratum"] == "all" and r["ok"]), key=lambda r: -r["nes"])
           for s in ("owner96", "public895")}
    out["chaos"] = json.loads(CHAOS.read_text()) if CHAOS.exists() else None
    if TRUTH_BIAS.exists():
        tb = json.loads(TRUTH_BIAS.read_text())
        keep = ("route", "family", "pages", "agreed_acc", "agreed_acc_joined", "adjudicated_acc")
        out["truth_bias"] = {"truth": tb["truth"], "reference": tb["reference"], "sheet": tb["sheet"],
                             "routes": [{**{k: r[k] for k in keep},
                                         "lead_agreed_joined": (r.get("lead") or {}).get("lead_agreed_joined")}
                                        for r in tb["split"]]}
        if TRUTH_BIAS_SCORE.exists():
            out["truth_bias"]["score"] = json.loads(TRUTH_BIAS_SCORE.read_text())["summary"]
    if HANDS_RESCORE.exists():
        hr = json.loads(HANDS_RESCORE.read_text())
        out["hands_rescore"] = {"lead": hr["lead"], "sheet": hr["sheet"], "controls": hr["controls"],
                                "changed": len(hr["changed_pages"]), "routes": hr["routes"],
                                "paired": {k: v["after"] for k, v in hr["paired"].items()},
                                # W46.ocr-audit-report-fix: the "either / can't tell" places and the leads they hold
                                "unresolved": {"places": sum(len(v) for v in hr["unresolved"]["places"].values()),
                                               "pages": len(hr["unresolved"]["pages"]),
                                               **hr["unresolved"]["summary"]}}
    if TRUTH_JPEG.exists():
        tj = json.loads(TRUTH_JPEG.read_text())
        out["truth_jpeg"] = {"pages": tj["pages"], "routes": {k: {f: v for f, v in r.items() if f != "per_page"}
                                                              for k, r in tj["routes"].items()}}
    return out


def rerun_noise():
    """Each rerun route's three readings of the 96: the run means, their spread, the run-to-run paired differences and
    the tie threshold. The per-page scores stay in the report. None until ocr_rerun_noise.py report has run."""
    if not RERUN_NOISE.exists():
        return None
    d = json.loads(RERUN_NOISE.read_text())
    return {"routes": {k: {f: v for f, v in r.items() if f != "pages_detail"} for k, r in d["routes"].items()},
            "gateway_cost_estimate": d["gateway_cost_estimate"]}


def logprob():
    """W46.ocr-logprob: per route and page set, AUC of each signal against an answered page under 90 NES (part 5's
    poor reading), and on the 455 the NES with the riskiest 20% sent to the escalation route. None until it has run."""
    if not LOGPROB.exists():
        return None
    d = json.loads(LOGPROB.read_text())
    names = {"lightonocr-3-4b-mlx8": "LightOnOCR-3 4B, Mac 8-bit", "qwen3.5-9b-mlx4": "Qwen3.5-9B, Mac 4-bit",
             "lightonocr3-4b": "LightOnOCR-3 4B, Sherlock", "qwen3.5-9b": "Qwen3.5-9B, Sherlock"}
    sigs = ("first", "mean", "min_k", "low_share", "length", "disagreement")
    rows, budget = [], []
    for k, r in d["routes"].items():
        if "auc_answered" not in r:
            continue
        for s in ("96", "455", "440"):
            a = r["auc_answered"].get(s, {}).get("nes<90")
            if a:
                rows.append({"route": names.get(k, k), "set": s, "poor": a["poor"], "answered": a["answered"],
                             **{g: a[g] for g in sigs}})
        c = r.get("cascade")
        if c:
            t = c["mean"]["test_455"]
            budget.append({"route": names.get(k, k), "first": t["first_nes"], "all": t["all_nes"],
                           "oracle": t["oracle_at_20pct"],
                           **{g: c[g]["test_455"]["nes_at_20pct"]
                              for g in ("mean", "fail+mean", "length", "disagreement", "failure")}})
    return {"escalation_route": d["escalation_route"], "rows": rows, "budget": budget}


def ppocrv6_hands(sweep):
    """W46.ocr-ppocrv6-hands: kraken's PP-OCRv6 medium on kraken blla lines and on Apple Vision's line boxes (and
    Vision's own text of those lines), on the public L1-L3 and the owner's hand and mixed pages, and its fine-tunes on
    one hand. Only the item's own routes are kept; the comparators are on the page already. Their L1-L3 figures in the
    result must equal the open sweep's, which is what lets the line routes join that table's stratum rows."""
    if not PPOCRV6_HANDS.exists():
        return None
    d = json.loads(PPOCRV6_HANDS.read_text())
    if sweep:
        at = {(r["route"], r["stratum"]): r["nes"] for r in sweep["rows"] if r["subset"] == "full895"}
        for r in d["public"]:
            for s, v in r["strata"].items():
                if (r["route"], s) in at and abs(v / 100 - at[(r["route"], s)]) > 1e-6:
                    sys.exit(f"ocr-ppocrv6-hands.json's {r['route']} {s} ({v:.2f}) is not the open sweep's")
    ours = lambda rows: [r for r in rows if r["route"] in PPOCRV6_HANDS_ROUTES]
    public_rows = [{"route": r["route"], "n": r["n"], "nes": r["nes"], "strata": r["strata"], "empty": r["empty"]}
                   for r in ours(d["public"])]
    owner_rows = [{"route": r["route"], "n": r["n"], "nes": r["nes"], "hand": d["owner_hand"][r["route"]],
                   "mixed": d["owner_mixed"][r["route"]], "empty": r["empty"]} for r in ours(d["owner"])]
    pairs = []
    for setname, pp in (("public", d["public_pairs"]), ("owner", d["owner_pairs"])):
        seen = set()
        for k, v in pp.items():
            a, b = k.split(" vs ")
            if (b, a) in seen:  # the same pair the other way round
                continue
            seen.add((a, b))
            pairs.append({"set": setname, "a": a, "b": b, **{f: v[f] for f in ("n", "delta", "lo", "hi", "p")}})
    return {"public": public_rows, "owner": owner_rows, "pairs": pairs, "tunes": d["tunes"],
            "tune_pairs": d.get("tune_pairs", []), "kit_recommendation": d.get("kit_recommendation", ""), "sets": d["sets"],
            "line_pairs": d["pairs"],  # the per-page guard lists stay in the report
            "timing": {g: {k: v for k, v in t.items() if isinstance(v, dict)} for g, t in d["timing"].items()}}


def postcorrect():
    """W46.ocr-postcorrect: Qwen3.6-27B correcting cheap readings in the NES 70-90 band, with the image and text only,
    beside the same model's own reading; the easy pages are the abstention check. None until it has run."""
    if not POSTCORRECT.exists():
        return None
    d = json.loads(POSTCORRECT.read_text())
    names = {"apple-vision": "Apple Vision", "lightonocr-3-4b-mlx8": "LightOnOCR-3 4B, Mac", "qwen3-vl-8b": "Qwen3-VL 8B",
             "gemini3.5-flash-lite": "Gemini 3.5 Flash-Lite", "glm-ocr": "GLM-OCR", "lightonocr3-4b": "LightOnOCR-3 4B",
             "all": "All readers"}
    by = {(g["set"], g["kind"], g["route"], g["arm"]): g for g in d["summary"]}
    rows = []
    for (s, k, route, arm), g in by.items():
        if arm != "image":
            continue
        t = by[(s, k, route, "text")]
        rows.append({"set": "the 96" if s == "owner96" else "public 895", "kind": k, "route": names.get(route, route),
                     "n": g["n"], "before": g["nes_before"], "image": g["nes_guard"], "trim": g["nes_trim"],
                     "text": t["nes_after"], "worse": g["worse_guard"], "worse_text": t["worse"],
                     "direct": g["nes_direct"]})
    return {"corrector": d["corrector"], "rows": rows,
            "intervals": {k: {a: [v["mean"], v["lo"], v["hi"]] for a, v in iv.items()}
                          for k, iv in d["intervals"].items() if k.count("/") == 1}}


def layout_order():
    """W46.layout-order's summaries (the per-page rows stay in the result file). None until it has run."""
    if not LAYOUT_ORDER.exists():
        return None
    d = json.loads(LAYOUT_ORDER.read_text())
    return layout_order_paid({"guard": d["guard"], "sources": d["sources"],
                              **{k: d[k]["summary"] for k in ("bench_lines", "bench_regions", "l9")},
                              **layout_order_marks(), **layout_order_pp()})


def layout_order_pp():
    """W46.layout-order-newspapers-pp: every orderer on PP-DocLayoutV3's own L9 regions, over the Vision lines inside
    them, with each arm's paired tau difference from the native order."""
    if not LAYOUT_ORDER_PP.exists():
        return {}
    return {"l9_pp": json.loads(LAYOUT_ORDER_PP.read_text())["summary"]["own"]}


def layout_order_paid(lo):
    """W46.layout-order-paid: Gemini's own blocks in its own order, one more row in each ordering table, with its
    cost and rerun floor for the notes. ``lo`` unchanged until it has run."""
    if not LAYOUT_ORDER_PAID.exists():
        return lo
    d = json.loads(LAYOUT_ORDER_PAID.read_text())
    native = lambda s: {g: {k: v for k, v in c.items() if k != "paired"} for g, c in d[s]["summary"]["gemini/native"].items()}
    lo["bench_regions"]["gemini_native"] = native("bench")
    lo["l9"]["gemini_native"] = native("l9")
    if "owner96" in lo:
        base = "yolo/app_regions"
        lo["owner96"]["summary"]["gemini/native"] = {
            g: {**{k: v for k, v in c.items() if k != "paired"},
                "paired_vs_default": c["paired"][base] and {"tau_diff": c["paired"][base]["diff"], "ci": c["paired"][base]["ci"]}}
            for g, c in d["owner"]["summary"]["gemini/native"].items()}
    r = d["rerun"]
    lo["gemini"] = {"cost": round(d["usage"]["all"]["charged"], 2),
                    "rerun": {k: {"tau": r[k].get("tau"), "abs": r[k]["mean_abs_page_diff"],
                                  "diff": r[k]["first_minus_rerun"]["diff"], "ci": r[k]["first_minus_rerun"]["ci"]}
                              for k in ("owner", "l9", "bench_multi")}}
    return lo


def layout_order_marks():
    """W46.layout-order-marks: ordering on the 96 owner pages, and the share of owner-core marks each stream keeps."""
    if not LAYOUT_ORDER_MARKS.exists():
        return {}
    d = json.loads(LAYOUT_ORDER_MARKS.read_text())
    m = d["marks"]["summary"]
    share = lambda arm: f'{m[arm]["all"]["reached"]} ({100 * m[arm]["all"]["share"]:.0f}%)'
    return {"owner96": {"summary": d["owner96"]["summary"]},
            "marks": {"of": m["vision-lines"]["all"]["of"], "vision": share("vision-lines"),
                      "yolo_filter": share("yolo-app-filter"), "yolo_pics": share("yolo-pictures-kept"), "pp": share("pp-any"),
                      **marks_detect()}}


def marks_detect():
    """W46.marks-detect: the trained YOLO11m's recall on the same core, at its default floor and at 0.05 (loose hit)."""
    if not MARKS_DETECT.exists():
        return {}
    d = json.loads(MARKS_DETECT.read_text()).get("yolo")
    if not d:
        return {}
    cell = lambda r, p: f'{r["found"]} ({100 * r["rate"]:.0f}%, interval {100 * r["ci"][0]:.0f}-{100 * r["ci"][1]:.0f}) at {100 * p:.0f}% precision'
    a = d["score"]["hit"]["all"]
    low = d["sweep"][0]["hit"]
    return {"detector": cell(a["recall"], a["precision"]), "detector_low": cell(low["recall"], low["precision"]),
            **mixed_route()}


MIXED_READERS = {"lighton": "LightOnOCR-3 4B", "vision": "Apple Vision", "glm": "GLM-OCR", "qwen27": "Qwen3.6-27B"}
MIXED_PREFLAGGED = {"qwen27"}   # mixed_route.PREFLAGGED


def mixed_route():
    """W46.mixed-route: each reader's marks read (NES >= 0.8) given the whole page and given the owner's box."""
    if not MIXED_ROUTE.exists():
        return {}
    d = json.loads(MIXED_ROUTE.read_text())
    rows = []
    for key, name in MIXED_READERS.items():
        w, b = d["whole"].get(key, {}), d["region"].get(f"{key}/oracle")
        if "read" not in w or b is None:
            continue
        row = f'{name} {w["read"]} of {w["n"]} given the whole page, {b["read"]} from the owner\'s box'
        u = d.get("two_pass", {}).get(f"{key}/oracle")   # W46.marks-two-pass: either reading, the two-pass ceiling
        if u:
            row += f', {u["union"]} from either reading'
        if key in MIXED_PREFLAGGED and "by_core" in w:   # MRK-1: it chose the B-core, so not ranked on all 35
            wa, ba = w["by_core"]["A-core"], b["by_core"]["A-core"]
            row += (f' (not ranked: it pre-flagged the pages of {w["by_core"]["B-core"]["n"]} of them; on the other '
                    f'{wa["n"]}, {wa["read"]} and {ba["read"]}, too few to rank)')
        rows.append(row)
    out = {"mixed_read": "; ".join(rows)} if rows else {}
    if MIXED_BANDS.exists():
        out.update(mixed_bands(json.loads(MIXED_BANDS.read_text())))
    return out


def mixed_bands(d):
    """W46.mixed-route-bands: the mixed share by handwriting band, and what a handwriting reader does to typed text."""
    share = lambda h: f'{100 * d["share"][h]["share"]:.0f}% ({100 * d["share"][h]["ci"][0]:.0f}-{100 * d["share"][h]["ci"][1]:.0f}%)'
    body = d["body"]["routes"]
    typed = lambda r: body[r]["typed"]
    diff = lambda r: (f'{100 * typed(r)["minus_vision"]:+.1f} ({100 * typed(r)["minus_vision_ci"][0]:+.1f} to '
                      f'{100 * typed(r)["minus_vision_ci"][1]:+.1f})')
    return {"mixed_bands": (f'Mixed pages are an estimated {share("signature")} of the bulk-pilot draw, '
                            f'{share("few")} with more than a signature, initials or a date; on the 96\'s '
                            f'{typed("apple-vision")["pages"]} typed and printed pages, body NES against Apple Vision is '
                            f'LightOnOCR-3 4B {diff("lightonocr-3-4b-mlx8")}, GLM-OCR {diff("glm-ocr")}, '
                            f'Qwen3.6-27B {diff("qwen3.6-27b")} points')}


LAYOUT_PHOTO_ARMS = {"yolo_appsort": "DocLayout-YOLO regions, the app's sort", "heron": "docling-layout-heron regions",
                     "vision_doc": "Apple Vision document regions"}  # the rest of its bench arms are W46.ocr-regions' rows


def layout_photo_chart_routes(data, kinds, op):
    """W46.layout-photo's new GLM-OCR crop arms on the 96, priced as region_chart_routes prices GLM-OCR's."""
    if data is None:
        return []
    out = []
    for arm, label in LAYOUT_PHOTO_ARMS.items():
        groups = [("overall", "the 96"), *((k, "kind:" + k) for k in kinds)]
        overall = data["bench"]["the 96"][arm]
        price = openrouter_price(op, "glm-ocr", overall["prompt_tokens"] / overall["n"],
                                 overall["completion_tokens"] / overall["n"])
        out.append({"id": f"layout-photo-glm-ocr-{arm}", "name": "GLM-OCR · " + label, "panel": "farmshare",
                    "cluster": "Sherlock", "std": cents(price) if price is not None else 0.0, "batch": None,
                    "free_cluster": price is None, "machine": "one NVIDIA L40S per job",
                    "hw": {"photos_per_hour": None, "gpu_hours_per_100k": None},
                    "scores": {key: [round(100 * data["bench"][g][arm]["nes"], 2), data["bench"][g][arm]["ok"],
                                     data["bench"][g][arm]["n"]] for key, g in groups}})
    return out


def layout_photo(data):
    """W46.layout-photo's table: each detector's GLM-OCR NES by photographed condition and on the bench groups."""
    if data is None:
        return None
    cell = lambda e, k=None: {"nes": e["nes"], "ok": e["ok"], "n": e["n"],
                              **({"d": [e[k]["delta"], e[k]["lo"], e[k]["hi"]]} if k and k in e else {})}
    return {"real5": {c: {a: cell(e, "vs_scan") for a, e in arms.items()} for c, arms in data["real5"].items()},
            "staged": {c: {a: cell(e, "vs_raw") for a, e in arms.items()} for c, arms in data["staged"].items()},
            "bench": {g: {a: cell(e, "vs_whole") for a, e in data["bench"][g].items()}
                      for g in ("L9", "L4", "the 96", "handwritten")},
            "gpu_hours": data["meta"]["gpu_hours_reading"], "caps": data["meta"]["caps"]}


def dewarp_real5():
    """W46.dewarp-guard's Real5 table: Apple Vision on the Warping folder's raw photograph, quad crop and UVDoc image,
    and the own-sheet guard's pass count and guarded figure (an arm where the guard passes, raw where it does not)."""
    if not DEWARP_GUARD_REAL5.exists():
        return None
    s = json.loads(DEWARP_GUARD_REAL5.read_text())["summary"]
    o = s["ocr_warp_vision"]
    return {"pages": o["pages"], "raw": o["raw_nes"],
            "arms": {a: {k: o[a][k] for k in ("nes", "gain", "chrf_gain", "better", "worse", "guarded", "passing_n")}
                     | {"lost_own": s["warp"][a]["lost_own"], "images_lost_own": s["warp"][a]["images_lost_own"]}
                     for a in ("quad", "uvdoc")}}


def region_chart_routes(data, kinds, op):
    """Crop routes on the exact panel-kind subsets, priced from all attempted crops of the 96 accuracy pages.
    Concurrent job spans combine all arms and sets, so no per-arm throughput is inferred from them.
    """
    if data is None:
        return []
    by = {(r["route"], r["arm"], r["group"]): r for r in data["rows"]}
    names = {"glm-ocr": "GLM-OCR", "paddleocr-vl1.5": "PaddleOCR-VL 1.5",
             "lightonocr3-4b": "LightOnOCR-3 4B", "qwen3.6-27b": "Qwen3.6 27B"}
    arms = {"doclayout_yolo": "DocLayout-YOLO", "pp-doclayoutv3": "PP-DocLayoutV3", "tiles": "overlapping tiles"}
    out = []
    for route in data["readers"]:
        for arm in data["arms"]:
            overall = by[(route, arm, "the 96")]
            price = openrouter_price(op, route, overall["prompt_tokens"] / overall["n"],
                                     overall["completion_tokens"] / overall["n"])
            scores = {}
            for key, group in [("overall", "the 96"), *((k, "kind:" + k) for k in kinds)]:
                r = by[(route, arm, group)]
                scores[key] = [round(100 * r["nes"], 2), r["ok"], r["n"]]
            out.append({"id": f"regions-{route}-{arm}", "name": names[route] + " · " + arms[arm],
                        "panel": "farmshare", "cluster": "Sherlock" + (" (38 pilot crops on FarmShare)" if route == "glm-ocr" else ""),
                        "std": cents(price) if price is not None else 0.0, "batch": None,
                        "free_cluster": price is None, "machine": "one NVIDIA L40S per job",
                        "hw": {"photos_per_hour": None, "gpu_hours_per_100k": None}, "scores": scores})
    return out


def gateway_region_routes(data, kinds):
    """Gemini 3.7 Flash's crop arms on the 96 (W46.ocr-regions-paid), priced from their own estimated token cost
    (the gateway returns no bill). Only exact 96-page groups reach the charts; the public pilot rows stay in the table."""
    if data is None:
        return []
    by = {(r["arm"], r["group"]): r for r in data["rows"]}
    arms = {"pp-doclayoutv3": "PP-DocLayoutV3 regions", "tiles": "overlapping tiles"}
    out = []
    for arm, label in arms.items():
        if arm not in data["arms_on_the_96"]:
            continue  # read on the pilot pages only: stays in the table, off the charts
        overall = by[(arm, "the 96")]
        if overall["n"] != 96:
            sys.exit(f"gateway {arm} covers {overall['n']} of the 96")
        scores = {key: [round(100 * by[(arm, g)]["nes"], 2), by[(arm, g)]["ok"], by[(arm, g)]["n"]]
                  for key, g in [("overall", "the 96"), *((k, "kind:" + k) for k in kinds)]}
        out.append({"id": f"gw-regions-{arm}", "name": "Gemini 3.7 Flash (Stanford gateway, price estimated) · " + label,
                    "panel": "cloud", "std": cents(1000 * overall["cost"] / overall["n"]), "batch": None, "scores": scores})
    return out


def dewarp_chart_routes(data, kinds, op):
    """Crop, dewarp and encoder arms on the 96 (W46.enh-dewarp): Apple Vision's at no cost, like its plain route, and
    the Sherlock readers' priced like the crop routes above, Gemini 3.7 Flash (W46.enh-dewarp-paid) from its own
    estimated token cost like the gateway's region arms. The plain photograph is left off: each reader's own
    route already draws it. The hand crops and the ladder are small subsets and stay in the table."""
    if data is None or data["readers_pending"]:
        return []
    by = {(r["route"], r["arm"], r["group"]): r for r in data["chart_rows"]}
    names = {"apple-vision": "Apple Vision", "lightonocr3-4b": "LightOnOCR-3 4B", "qwen3.6-27b": "Qwen3.6 27B",
             "ppocrv6": "PP-OCRv6", "gemini3.7-flash-gw": "Gemini 3.7 Flash (Stanford gateway, price estimated)"}
    arms = {"quad": "Apple quad crop", "uvdoc": "UVDoc dewarp", "docres": "DocRes dewarp",
            "enc-2048-q85": "app encoder 2048 px q0.85", "enc-2400-q90": "app encoder 2400 px q0.90",
            "enc-1600-q90": "app encoder 1600 px q0.90"}
    out = []
    for route, arm in dict.fromkeys((r["route"], r["arm"]) for r in data["chart_rows"]):
        if arm == "raw":
            continue
        overall = by[(route, arm, "the 96")]
        scores = {key: [round(100 * by[(route, arm, g)]["nes"], 2), by[(route, arm, g)]["ok"], by[(route, arm, g)]["n"]]
                  for key, g in [("overall", "the 96"), *((k, "kind:" + k) for k in kinds)]}
        label = names[route] + (" (macOS 26.6)" if route == "apple-vision" else "")   # W46.vision-27-swap: not re-read on 27.2
        common = {"id": f"dewarp-{route}-{arm}", "name": label + " · " + arms[arm], "batch": None, "scores": scores}
        if route == "apple-vision":
            out.append({**common, "panel": "local", "std": 0.0})
            continue
        if route in GATEWAY_ROUTES:
            out.append({**common, "panel": "cloud", "std": cents(1000 * overall["cost"] / overall["n"])})
            continue
        price = openrouter_price(op, route, overall["prompt_tokens"] / overall["n"],
                                 overall["completion_tokens"] / overall["n"])
        out.append({**common, "panel": "farmshare", "cluster": "Sherlock", "std": cents(price) if price is not None else 0.0,
                    "free_cluster": price is None, "machine": "one NVIDIA L40S per job",
                    "hw": {"photos_per_hour": None, "gpu_hours_per_100k": None}})
    return out


def enh_ocr_chart_routes(data, kinds, op):
    """Content-removing enhancement arms on the 96 (W46.enh-ocr-input): Apple Vision's free, the Sherlock readers'
    priced like the crop routes (GLM-OCR from its region crops' tokens, PP-OCRv6 free on a cluster), Gemini 3.7 Flash
    (W46.enh-ocr-input-paid) from its own estimated token cost like the gateway's region arms. Raw is each
    reader's own route on the charts already; the two-seed probe's 30 pages are too few for a chart."""
    if data is None or data["readers_pending"]:
        return []
    by = {(r["route"], r["arm"], r["group"]): r for r in data["chart_rows"]}
    names = {"apple-vision": "Apple Vision", "ppocrv6": "PP-OCRv6", "qwen3-vl-8b": "Qwen3-VL 8B",
             "glm-ocr": "GLM-OCR · PP-DocLayoutV3 regions",
             "gemini3.7-flash-gw": "Gemini 3.7 Flash (Stanford gateway, price estimated)"}
    arms = {"shading": "shading division", "gcdrnet": "GCDRNet", "sbb": "SBB binarisation",
            "docres-appearance": "DocRes appearance", "docres-deshadow": "DocRes deshadow"}
    out = []
    for route, arm in dict.fromkeys((r["route"], r["arm"]) for r in data["chart_rows"]):
        overall = by[(route, arm, "the 96")]
        scores = {key: [round(100 * by[(route, arm, g)]["nes"], 2), by[(route, arm, g)]["ok"], by[(route, arm, g)]["n"]]
                  for key, g in [("overall", "the 96"), *((k, "kind:" + k) for k in kinds)]}
        label = names[route] + (" (macOS 26.6)" if route == "apple-vision" else "")   # W46.vision-27-swap: not re-read on 27.2
        common = {"id": f"enh-{route}-{arm}", "name": label + " · " + arms[arm], "batch": None, "scores": scores}
        if route == "apple-vision":
            out.append({**common, "panel": "local", "std": 0.0})
            continue
        if route in GATEWAY_ROUTES:
            out.append({**common, "panel": "cloud", "std": cents(1000 * overall["cost"] / overall["n"])})
            continue
        price = openrouter_price(op, route, overall["prompt_tokens"] / overall["n"],
                                 overall["completion_tokens"] / overall["n"])
        out.append({**common, "panel": "farmshare", "cluster": "Sherlock", "std": cents(price) if price is not None else 0.0,
                    "free_cluster": price is None, "machine": "one NVIDIA L40S per job",
                    "hw": {"photos_per_hour": None, "gpu_hours_per_100k": None}})
    return out


def colour_dropout_chart_routes(data, kinds):
    """Colour dropout as the OCR input on the 96 (W46.ocr-input-colour-dropout): Apple Vision with dropout on every page
    that has a coloured mark at all, and with the gate (dropout only where a stamp lies over dark text, 1 of the 96);
    Gemini 3.7 Flash with the gate, from its own estimated token cost. Raw is each reader's own route already."""
    if data is None:
        return []
    by = {(r["route"], r["arm"], r["group"]): r for r in data["chart_rows"]}
    names = {"apple-vision": "Apple Vision (macOS 27.2)",
             "gemini3.7-flash-gw": "Gemini 3.7 Flash (Stanford gateway, price estimated)"}
    arms = {"ungated": "colour dropout on every marked page", "gated": "colour dropout, stamp gate"}
    out = []
    for route, arm in dict.fromkeys((r["route"], r["arm"]) for r in data["chart_rows"]):
        overall = by[(route, arm, "the 96")]
        scores = {key: [round(100 * by[(route, arm, g)]["nes"], 2), by[(route, arm, g)]["ok"], by[(route, arm, g)]["n"]]
                  for key, g in [("overall", "the 96"), *((k, "kind:" + k) for k in kinds)]}
        common = {"id": f"colour-{route}-{arm}", "name": names[route] + " · " + arms[arm], "batch": None, "scores": scores}
        if route == "apple-vision":
            out.append({**common, "panel": "local", "std": 0.0})
        else:
            out.append({**common, "panel": "cloud", "std": cents(1000 * overall["cost"] / overall["n"])})
    return out


def enh_marks():
    """W46.enh-ocr-input-marks: per arm and ink threshold, the share of the mark boxes' ink each method keeps on the
    marks set's 40-page owner core, the boxes it loses and the print kept outside them (enh_ocr_marks.py report)."""
    if not ENH_MARKS.exists():
        return None
    d = json.loads(ENH_MARKS.read_text())
    rows = []
    for key, groups in d["summary"].items():
        arm, t = key.split("@")
        s = groups["all 40 pages"]
        rows.append({"arm": arm, "t": float(t), **{k: round(100 * s["kept"][k], 1) for k in ("mean", "lo", "hi")},
                     "lost": s["lost"], "boxes": s["boxes"], "lost_pages": len(s["lost_pages"]),
                     "print": round(100 * s["print_kept"]["mean"], 1)})
    return {"pages": d["pages"], "rows": rows, "report": "enh-ocr-marks.md"}


def rotation():
    """W46.rotation-routes: every rotation route on the same turned pages (rotation_routes.py report), per page set;
    W46.rotation-heldout's held-out owner pages for the routes that ran on them (the rest have no figure there)."""
    if not ROTATION.exists():
        return None
    d = json.loads(ROTATION.read_text())
    groups = {"all": "all pages", "owner96": "the owner's 96", "public": "the six public strata", "L1": "L1 English handwriting",
              "L4": "L4 ledgers and tables", "L7": "L7 charters", "N1": "N1 Arabic", "N4": "N4 Hebrew", "N5": "N5 Chinese print",
              # W46.rotation-heldout: owner pages the shipped detector was not tuned on (local routes and their rules)
              "heldout": "held out: 119 owner pages", "heldout_replaced": "held out: the 19 the 96's draw replaced",
              "heldout_boxes": "held out: 100 locked-box pages"}
    rows = [{"id": k, "name": v["name"], **{g: v.get(g) for g in groups}} for k, v in d["routes"].items()]
    return {"groups": groups, "rows": rows, "meta": d["bench_meta"], "note": d["bench_note"]}


def vision_reread():
    """W46.vision-27-reread and W46.vision-27-swap: the page's Apple Vision route is its macOS 27.2 reading; the paired
    re-read says how far the update moved it from the 26.6 one (the 96's scored originals, the 440's Latin pages), and
    the note names the panels that still show 26.6 arms."""
    if not VISION_REREAD.exists():
        return None
    d = json.loads(VISION_REREAD.read_text())
    cell = lambda c: {"n": c["n"], "changed": c["n"] - c["identical"], "old": round(c["old_nes"], 1),
                      "answered_old": c["answered_old"], "answered_new": c["answered_new"], "lost": c["lost"],
                      "new": round(c["new_nes"], 1), **{k: round(c["d_nes"][k], 1) for k in ("delta", "lo", "hi")}}
    return {"os": d["os_now"].get("ProductVersion"), "build": d["os_now"].get("BuildVersion"),
            "panel": cell(d["panel"]["original · scored"]), "public": cell(d["bench"]["all"])}


def vision_unfiltered():
    """W46.ocr-vision-unfiltered: Apple Vision's failure rate on owner pages drawn without the 96's 20-word filter, one
    page per document, against the owner's answer to "does this page have text?"."""
    if not VISION_UNFILTERED.exists():
        return None
    d = json.loads(VISION_UNFILTERED.read_text())
    t = d["tally"]["drawn"]
    if "fail_on_text_page" not in t:
        return None
    return {"os": d["meta"]["os"], "pages": t["pages"], "answers": t["answers"], "fail": t["fail_on_text_page"],
            "empty": t["empty_on_has_text"], "under_min": t["vision_under_min"]}


def main():
    check = "--check" in sys.argv[1:]
    inputs = json.loads(INPUTS.read_text())
    names = inputs["routes"]
    cloud_md, local_md = CLOUD_MD.read_text(), LOCAL_MD.read_text()

    overall, std, panel = {}, {}, {}
    for cells in table_after(cloud_md, "## Original pages"):
        rid = route_id(cells[0])
        done, _, total = cells[1].split("/")
        overall[rid] = [float(cells[2]), int(done), int(total)]
        std[rid] = dollars_per_1000(cells[-1])
        panel[rid] = "cloud"
    for cells in table_after(GATEWAY_MD.read_text(), "## Original pages"):
        rid = route_id(cells[0])
        done, _, total = cells[1].split("/")
        overall[rid] = [float(cells[2]), int(done), int(total)]
        std[rid] = dollars_per_1000(cells[-1])  # an estimate: the gateway returns no cost (the route's name says so)
        panel[rid] = "cloud"
    for cells in table_after(local_md, "## Original pages"):
        rid = route_id(cells[0])
        done, _, total = cells[1].split("/")
        overall[rid] = [float(cells[2]), int(done), int(total)]
        std[rid] = dollars_per_1000(cells[-1])
        panel[rid] = "local"

    est = inputs["sonnet_api_estimate"]
    std[est["route"]] = (((est["image_tokens_standard"] + est["prompt_tokens"]) * est["input_usd_per_mtok"]
                               + est["output_tokens"] * est["output_usd_per_mtok"]) / 1e6 * 1000)

    missing = sorted(set(names) ^ set(overall))
    if missing:
        sys.exit(f"routes in inputs.json and the reports differ: {missing}")
    if any(v is None for v in std.values()):
        sys.exit(f"no price for: {[k for k, v in std.items() if v is None]}")

    kinds = {}
    for path, key in ((CLOUD_CSV, "route"), (LOCAL_CSV, "model"), (GATEWAY_CSV, "route")):
        with path.open(newline="") as f:
            for row in csv.DictReader(f):
                if row["attribute"] == "kind" and row[key] in names:
                    kinds.setdefault(row["value"], {})[row[key]] = (
                        round(100 * float(row["nes"]), 2), int(row["ok"]), int(row["n"]), int(row["words"]))

    ratio = inputs["batch"]["ratio"]
    routes = [{"id": rid, "name": names[rid]["name"], "panel": panel[rid], "std": cents(std[rid]),
               "batch": cents(std[rid] * ratio[rid]) if rid in ratio else None} for rid in names]
    charts = [{"key": "overall", "title": "All page kinds", "n": 96, "words": None, "scores": overall}]
    for kind in inputs["kinds"]:
        d = kinds[kind]
        first = d[next(iter(names))]
        charts.append({"key": kind, "title": kind.capitalize(), "n": first[2], "words": first[3],
                       "scores": {rid: list(d[rid][:3]) for rid in names}})

    # Routes on our own hardware: free in money, so drawn in the free column with their own marker.
    own = inputs["own_hardware"]
    op = inputs["openrouter_open_weights"]
    regions = json.loads(REGIONS.read_text()) if REGIONS.exists() else None
    extra = []
    for rid, spec in own["routes"].items():
        if spec["where"] == "mac":
            got = mac_route(spec, inputs["kinds"])
            if got is None:
                print(f"{rid}: no Mac results yet, not drawn")
                continue
            scores, hw = got
        else:
            scores, hw = farmshare_run(spec["run"], inputs["kinds"], op, spec.get("price"))
        # Mac routes are free; a FarmShare run of a model OpenRouter sells is priced at OpenRouter's rate; one it
        # does not sell has no hosted price and is drawn free, marked as free on a university cluster.
        free_cluster = spec["where"] == "farmshare" and hw["usd_per_1000"] is None
        routes.append({"id": rid, "name": spec["name"], "panel": spec["where"], "pair": spec["pair"],
                       "std": cents(hw["usd_per_1000"]) if spec["where"] == "farmshare" and not free_cluster else 0.0,
                       "batch": None, "free_cluster": free_cluster, "machine": spec["machine"], "hw": hw})
        for c in charts:
            c["scores"][rid] = scores[c["key"]]
    for spec in own["table_only"]:
        scores, hw = farmshare_run(spec["run"], inputs["kinds"], op)
        extra.append({"name": spec["name"], "panel": "farmshare", "under": spec["under"], "std": cents(hw["usd_per_1000"]), "machine": spec["machine"],
                      "hw": hw, "scores": scores})
    # W46.r1-foundation: Apple's macOS 27 on-device model, free on this Mac, on the 96 charts only. Its public figures
    # are 100 Latin pages of the 440 reference set (L5-L8), not the 895, so they stay off the public tables (README).
    fm96 = json.loads(FOUNDATION.read_text())["ocr"].get("96") if FOUNDATION.exists() else None
    if fm96:
        if fm96["n"] != 96 or fm96["attempted"] != 96 or any(k not in fm96["groups"] for k in inputs["kinds"]):
            sys.exit(f"{FOUNDATION.name}: the 96 must be read in full, with every kind")
        sc = lambda g: [round(100 * g["fm_nes"], 2), int(g["ok"]), int(g["n"])]
        routes.append({"id": "apple-fm-27", "name": "Apple on-device model (macOS 27)", "panel": "mac", "pair": None,
                       "std": 0.0, "batch": None, "free_cluster": False,
                       "machine": f"Apple M3 Pro, 18 GB; the OS's own model; median shown, mean {fm96['seconds']['mean']:.0f} s "
                                  "(the pages that loop to the cap take about 80 s); not in the ranking table (no per-page row)",
                       "hw": {"seconds": fm96["seconds"]["median"], "peak_gb": None, "peak_max_gb": None}})
        for c in charts:
            c["scores"]["apple-fm-27"] = sc(fm96) if c["key"] == "overall" else sc(fm96["groups"][c["key"]])
    # W46.ocr-time-like-for-like: Vision and every Mac reader timed on the same 16 owner pages in one session, model
    # load apart; shown beside each Mac route's own report figure, and as Vision's only seconds a page.
    lfl = json.loads(TIME_LFL.read_text())["mac"] if TIME_LFL.exists() else {}
    for r in routes:
        t = lfl.get(r["id"])
        if t and r["panel"] in ("mac", "local"):
            r["lfl"] = {"seconds": t["per_unit_s"], "pages": t["n"], "earlier": t.get("earlier")}
    layout_photo_data = json.loads(LAYOUT_PHOTO.read_text()) if LAYOUT_PHOTO.exists() else None
    for route in [*region_chart_routes(regions, inputs["kinds"], op),
                  *layout_photo_chart_routes(layout_photo_data, inputs["kinds"], op)]:
        scores = route.pop("scores")
        routes.append(route)
        for c in charts:
            c["scores"][route["id"]] = scores[c["key"]]
    dewarp = json.loads(DEWARP.read_text()) if DEWARP.exists() else None
    for route in dewarp_chart_routes(dewarp, inputs["kinds"], op):
        scores = route.pop("scores")
        routes.append(route)
        for c in charts:
            c["scores"][route["id"]] = scores[c["key"]]
    enh_ocr = json.loads(ENH_OCR.read_text()) if ENH_OCR.exists() else None
    for route in enh_ocr_chart_routes(enh_ocr, inputs["kinds"], op):
        scores = route.pop("scores")
        routes.append(route)
        for c in charts:
            c["scores"][route["id"]] = scores[c["key"]]
    colour = json.loads(COLOUR_DROPOUT.read_text()) if COLOUR_DROPOUT.exists() else None
    for route in colour_dropout_chart_routes(colour, inputs["kinds"]):
        scores = route.pop("scores")
        routes.append(route)
        for c in charts:
            c["scores"][route["id"]] = scores[c["key"]]
    regions_gw = json.loads(REGIONS_GW.read_text()) if REGIONS_GW.exists() else None
    for route in gateway_region_routes(regions_gw, inputs["kinds"]):
        scores = route.pop("scores")
        routes.append(route)
        for c in charts:
            c["scores"][route["id"]] = scores[c["key"]]
            if scores[c["key"]][2] != c["n"]:
                sys.exit(f"{route['id']}'s {c['key']} page count differs from the panel's {c['n']}")
    if regions and regions_gw:  # the open readers' table gains Gemini's rows; its public rows are a labelled sample of pages
        regions = {**regions, "rows": regions["rows"] + regions_gw["rows"], "gateway": {
            k: regions_gw[k] for k in ("report", "arms_on_the_96", "owner_pilot_pages", "public_pages", "public_per_stratum",
                                       "item_spend_estimate", "calls_new", "table_markup")}}
    for c in charts:
        if any(c["scores"][r["id"]][2] != c["n"] for r in routes if r["panel"] == "farmshare") \
                or any(e["scores"][c["key"]][2] != c["n"] for e in extra):
            sys.exit(f"a FarmShare run's {c['key']} page count differs from the panel's {c['n']}")

    # The difficulty and cascade analysis reads ocr-pages.csv's per-page rows. Its cascades are built from the routes
    # an app user could run; the later gateway reading of Gemini 3.7 Flash and the late Mac readers are left out of them.
    app_routes = [r["id"] for r in routes if r["panel"] != "farmshare" and r["id"] not in GATEWAY_ROUTES | LATE_MAC_ROUTES
                  and not r["id"].startswith(("gw-regions-", "dewarp-", "enh-", "colour-"))]
    # ocr-pages.csv now holds every whole-page route (W46.ocr-rescore-offline); the difficulty fit keeps the 28 routes
    # and the FarmShare Qwen run it was built on, so its figures do not move with the headline table's additions.
    diff = difficulty.analyse({r["id"]: r["std"] for r in routes}, {r["id"]: r["name"] for r in routes},
                              app_routes, fitted={*app_routes, "qwen3.6-27b-farmshare"})
    dating = json.loads(DATING.read_text()) if DATING.exists() else None
    if dating:  # FarmShare dating runs too large for the Mac, at OpenRouter's rate for their cached token means
        for k, m in dating.get("open_models", {}).items():
            tok = op["dating_tokens"]["models"].get(k)
            if tok:
                m["usd_per_1000"] = cents(openrouter_price(op, k.removesuffix("-nothink"), tok["prompt"], tok["completion"]))
            elif k.removesuffix("-nothink") in op["models"]:
                sys.exit(f"dating model {k} has an OpenRouter price but no token means in inputs.json")
    pub = public()
    built = {"routes": routes, "table_only": extra, "charts": charts, "segmentation": segmentation(op), "handwriting": handwriting(), "r6_spot": json.loads(R6_SPOT.read_text()),
             "farmshare": farmshare(op, own["routes"]), "difficulty": diff, "headline": headline(routes), "rerun_noise": rerun_noise(),
             "regions_orderfree": regions_orderfree(), "public_segmentation": public_segmentation(),
             "kind_classifier": json.loads(KIND_CLASSIFIER.read_text()) if KIND_CLASSIFIER.exists() else None,
             "kind_atrium": json.loads(KIND_ATRIUM.read_text()) if KIND_ATRIUM.exists() else None,
             "dating": dating,
             "dating_public": json.loads(DATING_PUBLIC.read_text()) if DATING_PUBLIC.exists() else None,
             "dating_traceable": dating_traceable(),
             "dating_enclosure": dating_enclosure(),
             "dating_image": dating_image(),
             "dating_undated": json.loads(DATING_UNDATED.read_text()) if DATING_UNDATED.exists() else None,
             "seg_date": json.loads((RESULTS / "seg-date-model-final.json").read_text())
                         if (RESULTS / "seg-date-model-final.json").exists() else None,
             "seg_context": seg_context(), "seg_adapt_lora": seg_adapt_lora(), "seg_window_modality": seg_window_modality(), "seg_tabme": seg_tabme(),
             "seg_kit_gate_sherlock": seg_kit_gate_sherlock(), "seg_boxes_score": seg_boxes_score(),
             "seg_magazine_rule": seg_magazine_rule(),
             "public": pub, "ocr_scorers": ocr_scorers(),
             "ppocrv6_hands": ppocrv6_hands(pub and pub["open_sweep"]),
             "hands_icl": {k: v for k, v in json.loads((RESULTS / "ocr-ppocrv6-hands-paid.json").read_text()).items()
                           if k in ("model", "groups", "comparisons", "cohorts", "charged", "complete", "verdict", "retained_allowance", "acknowledged_failures", "failure_reasons")}
                          if (RESULTS / "ocr-ppocrv6-hands-paid.json").exists() else None,
             # W46.ocr-ppocrv6-hands-qwen: hand_icl.py report, the same frozen pack on Qwen3.6-27B (Sherlock)
             "hands_icl_qwen": {k: v for k, v in json.loads((RESULTS / "ocr-ppocrv6-hands-qwen.json").read_text()).items()
                                if k in ("model", "groups", "comparisons", "cohorts", "verdict", "completion_tokens_max")}
                               if (RESULTS / "ocr-ppocrv6-hands-qwen.json").exists() else None,
             "dewarp": dewarp, "enh_ocr": enh_ocr, "enh_marks": enh_marks(),
             "capture_ladder": json.loads(CAPTURE.read_text()) if CAPTURE.exists() else None,
             "vision_reread": vision_reread(), "vision_unfiltered": vision_unfiltered(), "rotation": rotation(),
             "loops": json.loads(LOOPS.read_text()) if LOOPS.exists() else None, "regions": regions,
             "layout_order": layout_order(), "layout_photo": layout_photo(layout_photo_data), "dewarp_real5": dewarp_real5(), "logprob": logprob(), "postcorrect": postcorrect()}
    # indent=0: one value per line, so a grep over site/ prints a matching line, not the whole ~1 MB blob
    page = TEMPLATE.read_text().replace("__DATA__", json.dumps(built, indent=0, separators=(",", ":")))
    outputs = {OUT_DATA: json.dumps(built, indent=1) + "\n", OUT_PAGE: page, OUT_DIFFICULTY: difficulty.report(diff)}

    stale = [p for p, text in outputs.items() if not p.exists() or p.read_text() != text]
    if check:
        if stale:
            sys.exit("out of date: " + ", ".join(str(p.relative_to(HERE)) for p in stale) + " (run build.py)")
        print("up to date")
        return
    for p, text in outputs.items():
        p.write_text(text)
    print(f"wrote {OUT_DATA.relative_to(HERE)}, {OUT_PAGE.relative_to(HERE)} and {OUT_DIFFICULTY.name}: "
          f"{len(routes)} routes, {len(charts)} charts, {len(built['segmentation'])} segmentation approaches, "
          f"{len(built['handwriting']['readers'])} handwriting readers, {diff['cascades']['n']:,} cascades")


if __name__ == "__main__":
    main()
