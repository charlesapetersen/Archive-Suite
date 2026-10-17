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
PUBLIC = RESULTS / "bench-corpus"  # W43.corpus-build: corpus/routes.py report, the public strata
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


def farmshare_run(run, kinds):
    """One FarmShare run: per-kind scores from pages.csv over the 96 accuracy pages, checked against summary.json."""
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
             "gpu_hours_per_100k": 100000 / tp["pages_per_hour_per_gpu"]})


def segmentation():
    """Test-box figures (Stanton and RG 165, 363 pages) for every segmentation approach, each at the flag
    level frozen on the development boxes for the 98% bar: options.md's five, then cheap-models.md's finalists."""
    seg = []
    for c in table_after(OPTIONS_MD.read_text(), "## The five figures"):
        std, batch = money_cells(c[5])
        seg.append({"name": c[0], "nocheck": pct(c[1]), "checks": float(c[2]), "after": pct(c[3]),
                    "unflagged": int(re.search(r"\((\d+)\)", c[4]).group(1)), "std": std, "batch": batch,
                    "source": "options.md"})
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
    # Open weights on FarmShare's GPUs: no price per page, so in the table and off the price chart. The teacher
    # (W41.seg-27b-test) and the fine-tuned Mac segmenters it taught (W41.seg-finetune), scored the same way.
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
            seg.append({"name": c[0] + suffix, **row, "std": None, "batch": None, "farmshare": True,
                        "source": md.name})
    return seg


def handwriting():
    hw = json.loads(HANDWRITING.read_text())
    bar = hw["bar"]
    for r in hw["readers"]:
        r["passes"] = r["missed"] <= bar["missed"] and r["added"] <= bar["added"]
    return {k: hw[k] for k in ("pages", "words", "bar", "source", "readers", "reference")}


FARMSHARE_ROOT = RESULTS / "farmshare"
PRESET_NAMES = {"qwen3.6-27b": "Qwen3.6 27B", "qwen3.6-27b-dyn": "Qwen3.6 27B, fp8 at load time",
                "qwen3.6-35b-a3b": "Qwen3.6 35B-A3B", "qwen3.8-27b": "Qwen3.8 27B", "glm-ocr": "GLM-OCR",
                "qwen3.5-122b-a10b": "Qwen3.5 122B-A10B"}


def newsbench_table():
    """NewsBench's own score.py table as the run left it: {label: (overall, broadsheet, page)}."""
    out = {}
    for line in (FARMSHARE_ROOT / "news" / "newsbench-score.txt").read_text().splitlines():
        f = line.split()
        if len(f) == 8 and f[-1] == "15":
            out[f[0]] = tuple(float(x) for x in f[1:4])
    return out


def farmshare():
    """The FarmShare runs (W41.farmshare-run and after): one L40S each unless noted, no money spent. Truth runs
    from their summary.json; newspaper runs from NewsBench's own scores of what each run wrote."""
    truth = []
    for f in sorted((FARMSHARE_ROOT / "truth").glob("*/summary.json")):
        s = json.loads(f.read_text())
        env, t = s["env"], s["throughput"]
        kv = re.search(r"--kv-cache-dtype (\S+)", env.get("FS_VLLM_ARGS", ""))
        a = s["accuracy_96"]
        truth.append({"label": s["label"], "name": PRESET_NAMES.get(env["FS_PRESET"], env["FS_PRESET"]),
                      "kv": "bf16" if kv and kv.group(1) == "auto" else (kv.group(1) if kv else "?"),
                      "gpus": t["gpus"], "nes": round(100 * a["nes"], 2), "ok": a["ok"], "n": a["n"],
                      "clippings": round(100 * s["clippings"]["nes"], 2), "per_hour": t["pages_per_hour_per_gpu"],
                      "gpu_hours_100k": round(100000 / t["pages_per_hour_per_gpu"])})  # already per GPU
    truth.sort(key=lambda r: -r["nes"])
    nb = newsbench_table()
    news = []
    for f in sorted((FARMSHARE_ROOT / "news").glob("*/summary.json")):
        s = json.loads(f.read_text())
        how = "DocLayout-YOLO 1280 regions, the kit's glm-ocr route" if s.get("layout") else "whole page"
        news.append({"label": s["label"], "how": how, "per_hour": s["throughput"]["pages_per_hour_per_gpu"],
                     "answered": f"{s['throughput']['ok']}/{s['throughput']['pages']}"})
    for f in sorted((FARMSHARE_ROOT / "news-layout").glob("*/timing.json")):
        s = json.loads(f.read_text())
        news.append({"label": s["label"], "how": {"doclayout_yolo": "DocLayout-YOLO regions",
                                                   "paddlex": "PP-DocLayout regions"}[s["detector"]] + " (fs_news_layout.py)",
                     "per_hour": s["pages_per_hour_per_gpu"], "answered": f"{s['ok']}/{s['pages']}"})
    for r in news:
        preset = re.sub(r"-\d+(-(doclayout_yolo|paddlex))?$", "", r["label"])
        r["name"] = PRESET_NAMES.get(preset, preset)
        if r["label"] not in nb:
            sys.exit(f"no NewsBench score for {r['label']}: rerun score.py into newsbench-score.txt")
        r["overall"], r["broadsheet"], r["page"] = nb[r["label"]]
    news.sort(key=lambda r: -r["overall"])
    refs = [{"label": k, "overall": nb[k][0], "broadsheet": nb[k][1], "page": nb[k][2]}
            for k in ("ll-doclayout-pvl", "glm-ocr-doclayout", "ll-doclayout-glm", "gpt-5.6-luna-paddlex",
                      "gpt-5.6-luna-wholepage") if k in nb]
    bulk_f = FARMSHARE_ROOT / "bulk" / "summary.json"
    return {"truth": truth, "news": news, "news_reference": refs,
            "bulk": json.loads(bulk_f.read_text()) if bulk_f.exists() else None}


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
    strata = {}
    for m in manifest:
        s = strata.setdefault(m["stratum"], {"pages": 0, "sources": set(), "script": m["script"]})
        s["pages"] += 1
        s["sources"].add(m["source"])
    return {"rows": rows, "paired": json.loads((PUBLIC / "routes-paired.json").read_text()),
            "strata": {k: {**v, "sources": sorted(v["sources"])} for k, v in sorted(strata.items())}}


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
    extra = []
    for rid, spec in own["routes"].items():
        if spec["where"] == "mac":
            scores, hw = mac_route(spec, inputs["kinds"])
        else:
            scores, hw = farmshare_run(spec["run"], inputs["kinds"])
        routes.append({"id": rid, "name": spec["name"], "panel": spec["where"], "pair": spec["pair"],
                       "std": 0.0, "batch": None, "machine": spec["machine"], "hw": hw})
        for c in charts:
            c["scores"][rid] = scores[c["key"]]
    for spec in own["table_only"]:
        scores, hw = farmshare_run(spec["run"], inputs["kinds"])
        extra.append({"name": spec["name"], "panel": "farmshare", "machine": spec["machine"], "hw": hw, "scores": scores})
    for c in charts:
        if any(c["scores"][r["id"]][2] != c["n"] for r in routes if r["panel"] == "farmshare") \
                or any(e["scores"][c["key"]][2] != c["n"] for e in extra):
            sys.exit(f"a FarmShare run's {c['key']} page count differs from the panel's {c['n']}")

    diff = difficulty.analyse({r["id"]: r["std"] for r in routes}, {r["id"]: r["name"] for r in routes},
                              [r["id"] for r in routes if r["panel"] != "farmshare"])
    built = {"routes": routes, "table_only": extra, "charts": charts, "segmentation": segmentation(), "handwriting": handwriting(),
             "farmshare": farmshare(), "difficulty": diff,
             "kind_classifier": json.loads(KIND_CLASSIFIER.read_text()) if KIND_CLASSIFIER.exists() else None,
             "dating": json.loads(DATING.read_text()) if DATING.exists() else None,
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
