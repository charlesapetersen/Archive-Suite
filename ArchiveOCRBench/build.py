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
import re
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

import difficulty

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parent / "ArchiveProcessor" / "segbench-results"
CLOUD_MD = RESULTS / "ocr-panel-cloud.md"
LOCAL_MD = RESULTS / "ocr-panel-local.md"
CLOUD_CSV = RESULTS / "ocr-panel-cloud-groups.csv"
LOCAL_CSV = RESULTS / "ocr-panel-local-groups.csv"
MAC_MD = RESULTS / "ocr-mac-local.md"
MAC_CSV = RESULTS / "ocr-mac-local-groups.csv"
FARMSHARE = RESULTS / "farmshare" / "truth"
PANEL_PY = HERE.parent / "ArchiveProcessor" / "scripts" / "segbench" / "ocr_panel.py"
OPTIONS_MD = RESULTS / "options.md"
CHEAP_MD = RESULTS / "cheap-models.md"
STUDENTS_MD = RESULTS / "seg-students.md"  # W41.seg-finetune: the fine-tuned 4B and 2B
TEACHER_MD = RESULTS / "seg-teacher.md"  # W41.seg-27b-test: the FarmShare teacher, scored as cheap-models.md scores
INPUTS = HERE / "data" / "inputs.json"
HANDWRITING = HERE / "data" / "vision-ocr-handwriting.json"
KIND_CLASSIFIER = RESULTS / "kind-classifier.json"  # W41.bench-kind-classifier: kind_classifier.py report
DATING = RESULTS / "date-tagging.json"  # W41.date-tag-measure: date_tagging.py score
DATING_PUBLIC = RESULTS / "date-tagging-public.json"
PUBLIC = RESULTS / "bench-corpus"  # W43.corpus-build: corpus/routes.py report, the public strata
OPEN_SWEEP = HERE / "data" / "open-sweep-20261019.json"  # the open-model sweep's receipts (hand-entered, sourced)
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
    sc = lambda r: [round(100 * float(r["nes"]), 2), int(r["ok"]), int(r["n"])]
    md = RESULTS / spec.get("report", MAC_MD.name)
    speed = {c[0]: c for c in table_after(md.read_text(), spec.get("speed", "## Speed and memory"))}
    page_s = float(speed["seconds a page (prompt + generation)"][1])
    peak = speed["MLX peak memory, GB"]
    return ({"overall": sc(rows[("all", "accuracy-96")]), **{k: sc(rows[("kind", k)]) for k in kinds}},
            {"seconds": page_s, "peak_gb": float(peak[1]), "peak_max_gb": float(peak[3])})


def farmshare_run(run, kinds, op):
    """One FarmShare run: per-kind scores from pages.csv over the 96 accuracy pages, checked against summary.json, and
    its price at OpenRouter's rate for the same model."""
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
             "usd_per_1000": openrouter_price(op, summary["env"]["FS_PRESET"], tp["mean_prompt_tokens"],
                                              tp["mean_completion_tokens"])})


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
        seg.append(row)
    shipped_mac = next((a for a in seg if a.get("mac")), None)
    cheap = CHEAP_MD.read_text()
    costs = {c[0]: c for c in table_after(cheap, "### The level fitted per model", 1)}
    gemini = next(a for a in seg if a["name"] == "Gemini only")
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
    return seg


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
    return boxes


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
                "qwen3-vl-8b": "Qwen3-VL 8B", "ppocrv6-medium-pipeline": "PP-OCRv6 medium (pipeline, not a VLM)"}


def newsbench_table():
    """NewsBench's own score.py table as the run left it: {label: (overall, broadsheet, page)}."""
    out = {}
    for line in (FARMSHARE_ROOT / "news" / "newsbench-score.txt").read_text().splitlines():
        f = line.split()
        if len(f) == 8 and f[-1] == "15":
            out[f[0]] = tuple(float(x) for x in f[1:4])
    return out


def farmshare(op):
    """The FarmShare runs (W41.farmshare-run and after): one L40S each unless noted, no money spent, but priced at
    OpenRouter's rate for the same model where it is too large for the Mac. Truth runs from their summary.json;
    newspaper runs from NewsBench's own scores of what each run wrote."""
    def usd(preset, tp):
        v = openrouter_price(op, preset, tp.get("mean_prompt_tokens", 0), tp.get("mean_completion_tokens", 0))
        return None if v is None else cents(v)
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
                      "usd_1000": usd(env["FS_PRESET"], t)})
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
    return {"rows": rows, "coverage": meta["coverage"], "manifest_sha256": meta["manifest_sha256"],
            "routes": receipts["routes"], "not_scored": receipts["not_scored"], "status": receipts["status"],
            "hardware": receipts["hardware"]}


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
    for path, key in ((CLOUD_CSV, "route"), (LOCAL_CSV, "model")):
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
    extra = []
    for rid, spec in own["routes"].items():
        if spec["where"] == "mac":
            scores, hw = mac_route(spec, inputs["kinds"])
        else:
            scores, hw = farmshare_run(spec["run"], inputs["kinds"], op)
            if hw["usd_per_1000"] is None:
                sys.exit(f"{rid} runs on FarmShare but has no OpenRouter price in inputs.json")
        # Mac routes are free; a FarmShare route is too large for the Mac, so it is priced at OpenRouter's rate.
        routes.append({"id": rid, "name": spec["name"], "panel": spec["where"], "pair": spec["pair"],
                       "std": cents(hw["usd_per_1000"]) if spec["where"] == "farmshare" else 0.0, "batch": None,
                       "machine": spec["machine"], "hw": hw})
        for c in charts:
            c["scores"][rid] = scores[c["key"]]
    for spec in own["table_only"]:
        scores, hw = farmshare_run(spec["run"], inputs["kinds"], op)
        extra.append({"name": spec["name"], "panel": "farmshare", "std": cents(hw["usd_per_1000"]), "machine": spec["machine"],
                      "hw": hw, "scores": scores})
    for c in charts:
        if any(c["scores"][r["id"]][2] != c["n"] for r in routes if r["panel"] == "farmshare") \
                or any(e["scores"][c["key"]][2] != c["n"] for e in extra):
            sys.exit(f"a FarmShare run's {c['key']} page count differs from the panel's {c['n']}")

    diff = difficulty.analyse({r["id"]: r["std"] for r in routes}, {r["id"]: r["name"] for r in routes},
                              [r["id"] for r in routes if r["panel"] != "farmshare"])
    dating = json.loads(DATING.read_text()) if DATING.exists() else None
    if dating:  # FarmShare dating runs too large for the Mac, at OpenRouter's rate for their cached token means
        for k, m in dating.get("open_models", {}).items():
            tok = op["dating_tokens"]["models"].get(k)
            if tok:
                m["usd_per_1000"] = cents(openrouter_price(op, k.removesuffix("-nothink"), tok["prompt"], tok["completion"]))
            elif k.removesuffix("-nothink") in op["models"]:
                sys.exit(f"dating model {k} has an OpenRouter price but no token means in inputs.json")
    built = {"routes": routes, "table_only": extra, "charts": charts, "segmentation": segmentation(op), "handwriting": handwriting(),
             "farmshare": farmshare(op), "difficulty": diff, "public_segmentation": public_segmentation(),
             "kind_classifier": json.loads(KIND_CLASSIFIER.read_text()) if KIND_CLASSIFIER.exists() else None,
             "dating": dating,
             "dating_public": json.loads(DATING_PUBLIC.read_text()) if DATING_PUBLIC.exists() else None,
             "seg_date": json.loads((RESULTS / "seg-date-model-final.json").read_text())
                         if (RESULTS / "seg-date-model-final.json").exists() else None,
             "public": public()}
    page = TEMPLATE.read_text().replace("__DATA__", json.dumps(built, separators=(",", ":")))
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
