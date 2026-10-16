#!/usr/bin/env python3
"""Build ArchiveOCRBench's data file and chart page from the bench's committed results.

Reads, in ../ArchiveProcessor/segbench-results/, the W41 OCR panel's reports and per-attribute CSVs, the
routes run on our own hardware (ocr-mac-local.md and its groups CSV; farmshare/truth/<run>/summary.json and
pages.csv), the segmentation reports (options.md, cheap-models.md), plus the hand-entered figures in data/inputs.json and
the Vision OCR lab's handwriting figures in data/vision-ocr-handwriting.json, and writes:

  data/panel-data.json   every OCR route's score per chart, its answered pages and its price; every
                         segmentation approach's test-box figures; the handwriting readers
  site/index.html        the chart page (site/template.html with the data filled in)

Run from anywhere:  python3 ArchiveOCRBench/build.py
Add --check to fail instead of writing when either output is out of date.
"""
import csv
import json
import re
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

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
INPUTS = HERE / "data" / "inputs.json"
HANDWRITING = HERE / "data" / "vision-ocr-handwriting.json"
TEMPLATE = HERE / "site" / "template.html"
OUT_DATA = HERE / "data" / "panel-data.json"
OUT_PAGE = HERE / "site" / "index.html"


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
    """The Mac-local route: scores from its groups CSV, speed and memory from its report's table."""
    with MAC_CSV.open(newline="") as f:
        rows = {(r["attribute"], r["value"]): r for r in csv.DictReader(f) if r["model"] == spec["key"]}
    sc = lambda r: [round(100 * float(r["nes"]), 2), int(r["ok"]), int(r["n"])]
    speed = {c[0]: c for c in table_after(MAC_MD.read_text(), "## Speed and memory")}
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
        std, batch = money_cells(costs[c[0]][4] + " " + costs[c[0]][5])
        seg.append({"name": c[0], **row, "std": std, "batch": batch, "source": "cheap-models.md"})
    return seg


def handwriting():
    hw = json.loads(HANDWRITING.read_text())
    bar = hw["bar"]
    for r in hw["readers"]:
        r["passes"] = r["missed"] <= bar["missed"] and r["added"] <= bar["added"]
    return {k: hw[k] for k in ("pages", "words", "bar", "source", "readers", "reference")}


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

    built = {"routes": routes, "table_only": extra, "charts": charts, "segmentation": segmentation(), "handwriting": handwriting()}
    page = TEMPLATE.read_text().replace("__DATA__", json.dumps(built, separators=(",", ":")))
    outputs = {OUT_DATA: json.dumps(built, indent=1) + "\n", OUT_PAGE: page}

    stale = [p for p, text in outputs.items() if not p.exists() or p.read_text() != text]
    if check:
        if stale:
            sys.exit("out of date: " + ", ".join(str(p.relative_to(HERE)) for p in stale) + " (run build.py)")
        print("up to date")
        return
    for p, text in outputs.items():
        p.write_text(text)
    print(f"wrote {OUT_DATA.relative_to(HERE)} and {OUT_PAGE.relative_to(HERE)}: "
          f"{len(routes)} routes, {len(charts)} charts, {len(built['segmentation'])} segmentation approaches, "
          f"{len(built['handwriting']['readers'])} handwriting readers")


if __name__ == "__main__":
    main()
