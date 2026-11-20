#!/usr/bin/env python3
"""Build the settings layer's rule table, ArchiveProcessor/segbench-results/settings-routes.json (W46.settings-routes-table).

The schema is execution-plans/processing-review/13-stage-rules/00-index.md §"The table schema". Where the rows come from:

- Reading (stage 04), single routes: computed here from the bench's own files (panel-data.json, ocr-hands-rescore.json,
  ocr-scorers.json, ocr-ppocrv6-hands.json, reader-keeps-lines.json, and the Mac speed and memory tables of ocr-mac-local*.md). No figure is
  computed from other figures; values are rounded to two places from the raw value the `source` holds.
- Every other row, the reading stage's cascade rows, and the stage objects the notes give: the JSON blocks of each
  stage note's section 4 (13-stage-rules/NN-*.md), each figure carrying its `source`. Stage headers a note gives only in
  prose (01's geometry, 04, 07, 08, 10, 12) are written below from that note's section 3, each rule with its source.
- Normalised on the way: `needs` to one shape (below), the gateway key to one name, figures whose only source was the
  2026-11-04 prototype's hand-entered tables (settings-design/figures.json, build_figures.py) marked as unmeasured
  estimates with `source: null`, since that prototype now reads this table.

`needs` (every row). Access is any one of: a key in `key`, every plan in `plan` (signed-in tools), or `cluster` (a
Slurm cluster, `gpus` a job); a row with none of the three runs on the Mac alone. `mac` true means the route runs on
this Mac, so its memory must fit (`memory.peak_gb` plus the solver's headroom, `mac_gb` the note's stated floor if any);
`built_in` nothing to download.

Usage:
  settings_routes.py            write the table
  settings_routes.py --check    the drift test: regenerate and compare with the committed table, then check every
                                figure against the file its source names (exit 1 on any failure)
"""
import copy, datetime, glob, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
R = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
NOTES = "execution-plans/processing-review/13-stage-rules"
OUT = "ArchiveProcessor/segbench-results/settings-routes.json"
ITEM = "W46.settings-routes-table"
SEARCH = ["", "ArchiveProcessor/segbench-results", "ArchiveProcessor", "execution-plans/processing-review", NOTES,
          "ArchiveOCRBench"]
PROTOTYPE_FILES = ("settings-design/figures.json", "settings-design/build_figures.py")


def resolve(f):
    for d in SEARCH:
        p = os.path.join(R, d, f)
        if os.path.isfile(p):
            return p
    return None


def load(rel):
    return json.load(open(os.path.join(R, rel)))


# ---------------------------------------------------------------- the notes' section 4 blocks
_dec = json.JSONDecoder()


def note_objects(name):
    """Every JSON value in the code blocks of a note's section 4, in order."""
    t = open(os.path.join(R, NOTES, name)).read()
    m = re.search(r"^## 4\..*?(?=^## 5\.|\Z)", t, re.S | re.M)
    out = []
    for b in re.findall(r"^```[a-z]*\n(.*?)^```", m.group(0), re.S | re.M):
        i = 0
        while i < len(b):
            while i < len(b) and b[i] in " \n\t,":
                i += 1
            if i >= len(b):
                break
            o, i = _dec.raw_decode(b, i)
            out.append(o)
    return out


def note_rows(name):
    """(stage objects, route rows, other dicts) of a note."""
    stages, rows, other = [], [], []
    for o in note_objects(name):
        for x in (o if isinstance(o, list) else [o]):
            if "unit" in x or "choice" in x:
                stages.append(x)
            elif "family" in x:
                rows.append(x)
            else:
                other.append(x)
    return stages, rows, other


# ---------------------------------------------------------------- reading stage, from the bench's files
PD = "ArchiveOCRBench/data/panel-data.json"
HR = "ArchiveProcessor/segbench-results/ocr-hands-rescore.json"
SC = "ArchiveProcessor/segbench-results/ocr-scorers.json"
PH = "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.json"
KL = "ArchiveProcessor/segbench-results/reader-keeps-lines.json"
ML = "ArchiveProcessor/segbench-results/ocr-mac-local-hw.md"
M8 = "ArchiveProcessor/segbench-results/ocr-mac-local.md"
R1F = "ArchiveProcessor/segbench-results/r1-foundation.md"
OT = "ArchiveProcessor/segbench-results/ocr-time-like-for-like.json"   # W46.ocr-time-like-for-like


def src(f, route, attr, val):
    return {"file": f, "route": route, "attribute": attr, "value": str(val)}


def r2(x):
    return round(x, 2)


def mac_speed_memory(f, key):
    """Median seconds a page, MLX peak (max column) and the guard's largest physical footprint, from a Mac
    speed-and-memory section of ocr-mac-local*.md; `key` names the section, or None for the file's only one."""
    t = open(os.path.join(R, f)).read()
    secs = re.split(r"^## ", t, flags=re.M)
    sec = next(s for s in secs if s.startswith("Speed and memory") and (key is None or s.split("\n", 1)[0].strip().endswith(key)))
    med = re.search(r"^\| seconds a page \(prompt \+ generation\) \| ([\d.]+) \|", sec, re.M).group(1)
    peak = re.search(r"^\| MLX peak memory, GB \| [\d.]+ \| [\d.]+ \| ([\d.]+) \|", sec, re.M).group(1)
    guard = sec if key else t  # ocr-mac-local.md keeps its guard rows under a later heading
    foot = max(int(m.group(1)) for m in re.finditer(r"^- \S+ · \d+ · \d+ · \d+ · (\d+) ·", guard, re.M))
    where = "M3 Pro 18 GB, median, one page at a time"
    time = {"per_unit_s": float(med), "measured": True, "measured_on": where,
            "source": src(f, key or "", "seconds a page (prompt + generation), median", med)}
    mem = {"peak_gb": float(peak), "whole_process_gb": round(foot / 1000, 2), "measured_on": "M3 Pro 18 GB",
           "source": src(f, key or "", "MLX peak memory, GB, max", peak),
           "whole_process_source": src(f, key or "", "guard peak physical footprint MB, largest row", foot)}
    return time, mem


def lfl_time(key):
    """A Mac arm's seconds a page from the like-for-like run (ocr_time.py): the same 16 owner pages for every Mac
    reader, one session, load apart; kraken rows are blla plus the line reader."""
    r = load(OT)["mac"][key]
    how = "median, blla + line reader, of" if key.startswith(("kraken", "ppocrv6")) else "median of"
    return {"per_unit_s": r["per_unit_s"], "measured": True, "load_s": r["load_s"],
            "measured_on": f"M3 Pro 18 GB, like for like: {how} the same 16 owner pages as every Mac reader, load apart",
            "source": src(OT, key, f"mac.{key}.per_unit_s", r["per_unit_s"])}


def cloud_time(rid, fallback):
    """A cloud route's wall seconds a call from the scoring run's own log (ocr_time.py cloud), else `fallback`."""
    r = load(OT)["cloud"].get(rid)
    if not r:
        return fallback
    return {"per_unit_s": r["median_s"], "median_96_s": r["median96_s"], "measured": True,
            "measured_on": f"median wall a call on the 16 pages the Mac readers were timed on, from the scoring run's log, {r['in_flight_median']:g} calls in flight",
            "source": src(OT, rid, f"cloud.{rid}.median_s", r["median_s"])}


def reading_rows():
    d = load(PD)
    head = {r["id"]: r for r in d["headline"]["rows"]}
    charts = {c["key"]: c["scores"] for c in d["charts"]}
    routes = {r["id"]: r for r in d["routes"]}
    fsrows = {r["label"]: r for r in d["farmshare"]["truth"]}
    hands = {r["route"]: r for r in load(HR)["routes"]}
    pub = {}
    for r in load(SC)["summary"]:
        if r["set"] == "public895":
            pub.setdefault((r["route"], r["family"]), {})[r["stratum"]] = r
    ph = load(PH)
    l13 = {r["route"]: r for r in ph["public"]}
    ownhand = ph["owner_hand"]
    keeps = {r["reading"]: r for r in load(KL)["rows"] if r["pages"]}

    def figs(hid=None, cid=None, hk=None, pk=None, lk=None, ohk=None):
        F = {}
        if hid and hid in head:
            h = head[hid]
            fail = {k: h[k] for k in ("transport", "model", "cap", "refusal", "empty") if h[k]}
            v = h["vs_baseline"]
            F["overall"] = {"value": h["nes_answered"], "n": f"{h['answered']}/{h['pages']} answered, p081 apart", "strict": h["strict"],
                            "failures": fail, "vs_qwen3.6-27b": (f"{v['delta']} ({v['lo']} to {v['hi']}, n {v['n']})" if v else "baseline"),
                            "truth": "owner-96", "source": src(PD, hid, "headline.rows.nes_answered", h["nes_answered"])}
        if cid and cid in charts["overall"]:
            for k in ("typewritten", "printed", "handwritten"):
                v = charts[k].get(cid)
                if v:  # the bench has strict figures only per kind (no answered NES per kind)
                    F[k] = {"value": r2(v[0]), "answered": v[1], "n": v[2], "basis": "strict, failure as 0", "truth": "owner-96",
                            "source": src(PD, cid, f"charts.{k}.scores[0]", v[0])}
        if hk and hk in hands:
            h = hands[hk]
            F["hands16"] = {"value": r2(h["after"]), "n": 16, "failed": h["failed"], "unresolved_range": f"{r2(h['lo'])} to {r2(h['hi'])}",
                            "truth": "owner-96 after the 2026-10-31 hand sheet (drafter-biased, OCR-1)", "source": src(HR, hk, "routes.after", h["after"])}
        if ohk and ohk in ownhand:
            F["hands16"] = {"value": r2(ownhand[ohk]), "n": 16, "truth": "owner-96 after the hand sheet", "source": src(PH, ohk, "owner_hand", ownhand[ohk])}
        k = keeps.get(F["hands16"]["source"]["route"]) if "hands16" in F else None
        if k:  # W46.reader-keeps-lines: a reflowing reader's hand pages get the text page (05-placement.md)
            F["reflows"] = {"value": k["reflows"], "median_line_share": k["median_ratio"], "pages": k["pages"], "pages_under": k["pages_under"],
                            "basis": "median page's reading lines over kraken blla's detected lines, owner hand pages; reflows under 0.7",
                            "source": src(KL, k["reading"], "rows.reflows", k["reflows"])}
        if lk and lk in l13:
            x = l13[lk]
            F["public_L1-L3"] = {"value": r2(x["nes"]), "n": x["n"], "strata": {k: r2(v) for k, v in x["strata"].items()}, "empty": x["empty"],
                                 "truth": "public (independent)", "source": src(PH, lk, "public.nes", x["nes"])}
        if pk and pk in pub:
            P = pub[pk]
            F["public"] = {"basis": "[NES strict, NES answered, answered/n]", "truth": "public (independent of the routes)",
                           **{st: [r2(x["nes"] * 100), (r2(x["nes_answered"] * 100) if x["nes_answered"] is not None else None), f"{x['ok']}/{x['n']}"] for st, x in sorted(P.items())},
                           "source": src(SC, f"{pk[0]} ({pk[1]})", "summary[set=public895, stratum].nes", {st: round(x["nes"], 4) for st, x in sorted(P.items())})}
        return F

    def cost(cid, money=True):
        r = routes.get(cid)
        if not r:
            return None
        c = {"usd_1000_list": r["std"], "usd_1000_batch": r["batch"], "price_read": "2026-10 (panel run)", "source": src(PD, cid, "routes.std", r["std"])}
        if not money:
            c = {"usd_1000_list": 0.0, "openrouter_equivalent_usd_1000": r["std"] or None,  # 0 in the panel: no OpenRouter route
                 "source": src(PD, cid, "routes.std (OpenRouter rate for the run's tokens)", r["std"])}
            hw = r.get("hw") or {}
            if hw.get("gpu_hours_per_100k"):
                c["gpu_hours_per_100k"] = r2(hw["gpu_hours_per_100k"])
        return c

    def cluster_time(label):
        f = fsrows[label]
        return {"pages_per_hour_per_gpu_set": f["per_hour"], "gpus": f.get("gpus"), "measured": True, "measured_on": "the 96's cluster run, queue wait excluded",
                "source": src(PD, label, "farmshare.truth.per_hour", f["per_hour"])}

    rows = []

    def add(id, name, family, app_route, status, needs, F, cost_, time_, mem, caveats, kind_rules=(), fallback=None, conditions=()):
        app_route = app_route or APP_ROUTES.get(id)
        if app_route:
            status = "shipped"
        rows.append({"id": id, "name": name, "family": family, "app_route": app_route, "status": status, "needs": needs, "figures": F,
                     "cost": cost_, "time": time_, "memory": mem, "caveats": list(caveats), "kind_rules": list(kind_rules), "fallback": fallback, "conditions": list(conditions)})

    # ---- Mac (R1, R2)
    add("apple-vision", "Apple Vision (built in, macOS 27.2)", "mac", None, "shipped", {"mac": True, "built_in": True},
        figs("apple-vision", "apple-vision", "apple-vision", ("apple-vision", "Mac")),
        cost("apple-vision"),
        lfl_time("apple-vision"),
        {"peak_gb": None, "measured_on": "runs in the OS", "source": None},
        ["every figure is the macOS 27.2 reading (vision-27-reread.md)", "the 96 were drawn through a 20-word Vision filter (P8-3, ocr-truth.md); on 200 owner pages drawn without it, one per document, Vision reads under 20 words on 1 of the 181 pages of text (0.6%, 95% 0.1-3.1%) and nothing on none of the 200 with text (ocr-vision-unfiltered.md)",
         "public: Latin-script pages of the 440 only (L5-L8), 305 of 320 answered; empty on 15 of 80 L7 pages (P8-2)", "on 27.2 a few handwritten pages vary run to run, up to 3.7 NES a page (vision-27-reread.md Noise)"],
        ["non-Latin scripts: not measured (the bench ran Vision on the 320 Latin-script pages of the 440 only); figure absent, not zero"], None)
    for rid, nm, f, cav, kr in [
        ("xiaomi-ocr-0-bf16", "Xiaomi-OCR-0 bf16 (Mac)", ML,
         ["public figures are the Sherlock build's (row xiaomi-ocr-0-sherlock); Mac 88.66 against Sherlock 88.67 on the 96 (R-13)", "Markdown output; +2.14 on the 96 if stripped (ocr-scorers.md markup diagnostic)"], []),
        ("paddleocr-vl1.6-bf16", "PaddleOCR-VL 1.6 bf16 (Mac)", ML,
         ["3 of 99 pages hit the 8,192-token cap (ocr-mac-local-hw.md)", "public figures are the Sherlock build's; fails every newspaper (open-sweep-20261019.md)"],
         ["newspapers, ledgers: not without a layout stage (open-sweep: L9 0.0, L4 28.2 for 1.5)"]),
        ("lightonocr-3-4b-mlx8", "LightOnOCR-3 4B 8-bit (Mac)", ML,
         ["0 of 99 failed on the Mac", "public figures are the FarmShare build's (lightonocr3-4b-farmshare): 89.38 there against 89.15 on the Mac, answered, p081 apart", "Markdown output: +2.86 on the 96 if stripped (ocr-scorers.md markup diagnostic)"], []),
        ("qwen3.5-9b-mlx4", "Qwen3.5 9B 4-bit (Mac)", ML, ["96 only: no public reading of this build (P5-1)", "1 of 99 failed (format)"], []),
        ("qwen3-vl-8b-mlx4", "Qwen3-VL 8B 4-bit (Mac)", M8,
         ["3 of 99 looped to the cap at 7.3 minutes each; needs the loop stop (ocr-mac-local.md)", "memory pressure 'warn' on 18 GB with the owner's apps open", "deterministic: two readings 15 days apart byte-identical (ocr-rerun-noise.md)"], []),
    ]:
        _, m = mac_speed_memory(f, rid if f == ML else None)
        t = lfl_time(rid)
        add(rid, nm, "mac", None, "measured", {"mac": True}, figs(rid, rid, rid), cost(rid), t, m, cav, kr)
    # W47.wh-readers-lost (owner call 15, 2026-11-19): offered at Advanced with its figures, never a default or a pick.
    # Its overall figure is r1-foundation.md's, over all 96 (p081 included; no ocr-pages.csv rows, so no pair entries).
    fm = figs(None, "apple-fm-27")
    fm["overall"] = {"value": 64.5, "n": "63/96 answered, all 96 (p081 included)", "strict": 42.4, "failures": {"cap": 33},
                     "truth": "owner-96", "source": src(R1F, "apple-fm-27", "The owner's 96: NES % answered", 64.5)}
    add("apple-fm-27", "macOS 27 on-device model", "mac", None, "measured", {"mac": True, "built_in": True},
        fm, cost("apple-fm-27"),
        lfl_time("apple-fm-27"),
        {"peak_gb": None, "measured_on": "runs in the OS", "source": None},
        ["42.4 strict against Vision's 83.1, both 27.2, -40.7 (-49.0 to -32.5); 33 of 96 loop to the 4,096-token cap (r1-foundation.md)", "not in the ranking table (no ocr-pages.csv rows)", "its 100 public pages are L5-L8 of the 440, drawn where Vision is cached (P7-6); off the public tables",
         "the Processor has no reader for it yet (W47.wh-readers-lost's report)"],
        [], None, [lower("Apple Vision (apple-vision) reads 83.1 strict on the same 96 against 42.4, at no more cost")])
    add("ppocrv6-kraken-blla", "kraken PP-OCRv6 medium on blla lines (Mac CPU)", "mac", None, "measured", {"mac": True},
        figs(lk="ppocrv6-kraken-blla", ohk="ppocrv6-kraken-blla"), {"usd_1000_list": 0.0, "source": None},
        lfl_time("ppocrv6-kraken-blla"),
        {"peak_gb": 6.0, "measured_on": "2-6 GB a page call on the CPU (ocr-ppocrv6-hands.md Verdict)", "source": src("ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "ppocrv6-kraken-blla", "Verdict", "2-6 GB")},
        ["no typed or printed page of the 96 read; not on the 96 ranking", "Latin script only; cannot loop (CTC)"],
        ["role: loop fallback and low-memory hands reader, not a default"], None)

    # ---- cheap API (R3)
    for rid, nm, pk, cav in [
        ("qwen3.6-35b-a3b", "Qwen3.6 35B-A3B (OpenRouter)", None, ["public figures are the FarmShare bf16 run, a different build (OCR-9)"]),
        ("qwen3.6-27b", "Qwen3.6 27B (OpenRouter, hosted fp8)", None, ["the bench's paired baseline; public figures are the FarmShare run (R-5, R-6)"]),
        ("qwen3-vl-235b", "Qwen3-VL 235B (OpenRouter)", ("qwen3-vl-235b", "reference"), ["public: the 440 only; 25 of 40 Hebrew pages loop (C-ocr §5)"]),
        ("qwen3.8-flash", "Qwen3.8 Flash (OpenRouter)", None, ["96 only; 3 of 96 refused"]),
        ("gemini3.5-flash-lite", "Gemini 3.5 Flash-Lite", None, ["96 only; drafter's family (OCR-1)"]),
        ("gemini3.1-flash-lite", "Gemini 3.1 Flash-Lite", None, ["96 only; drafter's family"]),
        ("gpt5.6-luna", "GPT-5.6 Luna (OpenRouter)", None, ["96 only"]),
        ("qwen3.5-397b", "Qwen3.5 397B (OpenRouter)", None, ["96 only"]),
        # W46.ocr-rows-omitted: the cheap hosted routes priced under every row above
        ("gemma4-31b", "Gemma 4 31B (OpenRouter)", None, ["96 only; 3 of 95 ran to the token cap"]),
        ("qwen3.5-9b", "Qwen3.5 9B (OpenRouter)", None, ["96 only; 4 of 95 ran to the token cap", "the hosted build; the Mac row qwen3.5-9b-mlx4 is 4-bit (93.32)"]),
        ("gemma4-26b-a4b", "Gemma 4 26B-A4B (OpenRouter)", None, ["96 only; 8 of 95 ran to the token cap and 1 lost to a transport error, strict 83.62"]),
        ("mistral-small-24b", "Mistral Small 24B (OpenRouter)", None, ["96 only; 2 of 95 ran to the token cap", "handwritten 79.90 strict, 15 of 16 answered: not a hands reader"]),
    ]:
        keys = ["openrouter"] if not rid.startswith(("gemini", "gpt")) else (["gemini", "openrouter"] if rid.startswith("gemini") else ["openai", "openrouter"])
        add(rid, nm, "cloud", None, "measured", {"key": keys}, figs(rid, rid, rid, pk), cost(rid),
            cloud_time(rid, {"per_unit_s": None, "measured": False, "measured_on": "no call log for the 96 (ocr-time-like-for-like.md)", "source": None}), {"peak_gb": 0, "source": None}, cav)

    # ---- premium API (R4) and vendors (R6)
    add("gemini3.8-flash", "Gemini 3.8 Flash", "cloud", "gemini|gemini-3.8-flash", "shipped", {"key": ["gemini", "openrouter"]},
        figs("gemini3.8-flash", "gemini3.8-flash", "gemini3.8-flash", ("gemini3.8-flash", "reference")), cost("gemini3.8-flash"),
        cloud_time("gemini3.8-flash", None), {"peak_gb": 0, "source": None},
        ["truth drafter (OCR-1): its 96 and hands figures are partly agreement with itself", "2 of 95 refused (a model failure in the bench's split, reprinted text)", "public: the 440 only (L5-L8, N1, N3, N4); possible training exposure through CHURRO-DS (OCR-15)", "price doubles 1 January 2027 (J-compute.md §3.1)"])
    add("gemini3.7-flash-gw", "Gemini 3.7 Flash (Stanford gateway)", "cloud", None, "measured", {"key": ["gateway"]},
        figs("gemini3.7-flash-gw", "gemini3.7-flash-gw", "gemini3.7-flash-gw", ("gemini3.7-flash-gw", "gateway"), "gemini3.7-flash-gw"), cost("gemini3.7-flash-gw"),
        {"per_unit_s": 9.43, "measured": True, "measured_on": "median on the 96 (8.195 s on the 895, gemini37-public.md)", "source": src("ArchiveProcessor/segbench-results/gemini37-vs-38.md", "gemini3.7-flash-gw", "median s a page", 9.43)},
        {"peak_gb": 0, "source": None},
        ["relative of a truth drafter (OCR-1)", "the only hosted route on all 895: 879 read, 16 content-filter refusals (gemini37-public.md)", "price an estimate at 3.8's list (R-7)", "rerun range 0.24 on the 96; twice it, 0.49, is the hosted tie floor (ocr-rerun-noise.md)"])
    for rid, nm, keys, cav in [
        ("gemini3.1-pro", "Gemini 3.1 Pro", ["gemini", "openrouter"], ["2 of 95 refused; drafter's family; 96 only"]),
        ("gemini3.5-flash", "Gemini 3.5 Flash", ["gemini", "openrouter"], ["2 of 95 refused; 96 only"]),
        ("gpt5.4-mini", "GPT-5.4 Mini", ["openai", "openrouter"], ["96 only"]),
        ("mistral-large4", "Mistral Large 4", ["mistral", "openrouter"], ["96 only"]),
        ("mistral-ocr-4-1", "Mistral OCR 4.1 (vendor service)", ["mistral"], ["text only, no kind label; the app's 2,048 px encoding and no prompt (ocr-panel-cloud.md)", "96 only"]),
    ]:
        add(rid, nm, "cloud", None, "measured", {"key": keys}, figs(rid, rid, "mistral-ocr" if rid == "mistral-ocr-4-1" else rid), cost(rid),
            cloud_time(rid, {"per_unit_s": None, "measured": False, "measured_on": "no time in its call log (ocr-time-like-for-like.md)", "source": None}), {"peak_gb": 0, "source": None}, cav)

    def hosted_by(dom):
        return lower(f"{dom} scores higher on the 96, "
                     f"{head[dom]['nes_answered']} answered, and costs no more, ${routes[dom]['std']:.2f} per 1,000 pages")

    # W47.wh-readers-lost (owner call 15, 2026-11-19): the hosted routes a row of the same family dominates on the 96
    # (04-reading.md §4, "Not in the table"), offered at Advanced with their figures, never a default or a pick. Each is
    # a pinned OpenRouter route since W47.wh-readers-lost-clients (APP_ROUTES); Mistral Medium 3.5 only through OpenRouter,
    # as the bench read it, since the app's Mistral key sends Mistral OCR alone.
    for rid, nm, keys, hk, dom, cav in [
        ("qwen3-vl-8b", "Qwen3-VL 8B (OpenRouter)", ["openrouter"], "qwen3-vl-8b (local panel)", "qwen3.8-flash", ["96 only: no public run of its own"]),
        ("qwen3-vl-30b-a3b", "Qwen3-VL 30B-A3B (OpenRouter)", ["openrouter"], None, "qwen3.8-flash", ["96 only: no public run of its own"]),
        ("qwen3.5-35b-a3b", "Qwen3.5 35B-A3B (OpenRouter)", ["openrouter"], None, "qwen3.8-flash", ["96 only: no public run of its own", "the second stage of casc-5-fail"]),
        ("mistral-medium3.5", "Mistral Medium 3.5 (OpenRouter)", ["openrouter"], None, "mistral-large4", ["96 only: no public run of its own"]),
    ]:
        add(rid, nm, "cloud", None, "measured", {"key": keys}, figs(rid, rid, hk or rid), cost(rid),
            cloud_time(rid, {"per_unit_s": None, "measured": False, "measured_on": "no time in its call log (ocr-time-like-for-like.md)", "source": None}), {"peak_gb": 0, "source": None},
            cav, conditions=[hosted_by(dom)])

    # ---- plans (R5), read by the plan or by key
    # W41.app-claude-plan-reading (owner, 2026-11-19): measured through `claude -p` on the owner's plan, and the app reads
    # it the same way (the Local Agent backend, `claude` at this model), so a Claude plan reaches it at no money, using
    # the plan's five-hour and weekly windows. A key reaches it too: an Anthropic key, or an OpenRouter key on Anthropic's
    # own endpoint (`OpenRouterRoute.makerRoutes`, W41.app-openrouter-claude), carrying the plan route's figures (owner,
    # 2026-11-18: no parity check); by key it is money, the cloud pilot's cost through that endpoint (three pages,
    # extrapolated to 99), at Anthropic's list price ($2/$10, checked 2026-11-18); no batch figure, since OpenRouter has
    # none. The solver prices it at nothing when the plan reaches it, and the sheet's "Read with this" then switches on
    # the plan, never a key (`SettingsSheetModel.Apply.readingByPlan`).
    add("claude-sonnet5.5", "Claude Sonnet 5.5 (your Claude plan, or an Anthropic or OpenRouter key)", "plan",
        "anthropic|claude-sonnet-5-5", "measured", {"key": ["anthropic", "openrouter"], "plan": ["claude"]},
        figs("claude-sonnet5.5", "claude-sonnet5.5", "claude-sonnet5.5"),
        {"usd_1000_list": 19.56, "price_read": "2026-10-15 (cloud pilot)",
         "derived": "the pilot's three pages extrapolated to 99, $1.936, per 1,000 pages",
         "plan_share": "no money on the Claude plan: it uses the plan's five-hour and weekly windows, measured on the user's account (usage.md)",
         "source": src("ArchiveProcessor/segbench-results/ocr-panel-cloud-pilot.md", "claude-sonnet5.5", "99 pages, mean cost", "$1.936"),
         "api_equivalent_usd_1000": routes["claude-sonnet5.5"]["std"],
         "api_equivalent_source": src(PD, "claude-sonnet5.5", "routes.std (estimated API price, data/inputs.json)", routes["claude-sonnet5.5"]["std"])},
        {"per_unit_s": 10.0, "measured": True, "measured_on": "mean, three at once through claude -p", "source": src("ArchiveProcessor/segbench-results/ocr-panel-cloud.md", "claude-sonnet5.5", "mean s a page", 10)},
        {"peak_gb": 0, "source": None},
        ["Claude Opus 5.5 drafted the truth: same family (OCR-1)", "read through claude -p, whose harness may resize the image (ocr-panel-cloud.md)", "96 only"])

    # ---- cluster (R7)
    for rid, nm, hk, pk, lk, label, cav in [
        ("qwen3.6-27b-farmshare", "Qwen3.6 27B fp8 (your cluster)", None, ("qwen3.6-27b", "FarmShare panel"), "qwen3.6-27b", "qwen3.6-27b-1849739", ["the 96 run (fp8 KV) and the 895 run (BF16 KV) are different runs (R-6)"]),
        ("qwen3.5-27b-farmshare", "Qwen3.5 27B (your cluster)", "qwen3.5-27b (FarmShare panel)", ("qwen3.5-27b", "FarmShare panel"), "qwen3.5-27b", "qwen3.5-27b", ["96 and 895 are different runs"]),
        ("qwen3.6-35b-a3b-farmshare", "Qwen3.6 35B-A3B (your cluster)", None, ("qwen3.6-35b-a3b", "FarmShare panel"), "qwen3.6-35b-a3b", "qwen3.6-35b-a3b-1850004", ["96 fp8 KV against 895 BF16 KV (R-6)"]),
        ("infinity-parser2-pro-sherlock", "Infinity-Parser2-Pro 35B-A3B (your cluster)", "infinity-parser2-pro", ("infinity-parser2-pro", "Sherlock native"), "infinity-parser2-pro", "infinity-parser2-pro-50536490", ["two GPUs", "the 96 is run infinity-parser2-pro-50536490; the public figures are the 895 run (ocr-scorers.json, Sherlock native), named apart; whether one job or two is not recorded here (R-6) [?]"]),
        ("lightonocr3-4b-farmshare", "LightOnOCR-3 4B (your cluster)", "lightonocr3-4b", ("lightonocr3-4b", "FarmShare native"), "lightonocr3-4b", "lightonocr3-4b-1861698", ["Markdown output", "the 96 is run lightonocr3-4b-1861698; the public figures are the 895 run (ocr-scorers.json, FarmShare native), a different run (R-6)"]),
        ("paddleocr-vl1.6-sherlock", "PaddleOCR-VL 1.6 (your cluster)", "paddleocr-vl1.6", ("paddleocr-vl1.6", "Sherlock native"), None, "paddleocr-vl1.6-49202331", ["12,327.9 pages an hour, the most of the 96 cluster runs (panel-data farmshare.truth)", "the 96 is run paddleocr-vl1.6-49202331; the public figures are the 895 run (ocr-scorers.json, Sherlock native), named apart; whether one job or two is not recorded here (R-6) [?]"]),
        ("xiaomi-ocr-0-sherlock", "Xiaomi-OCR-0 (your cluster)", "xiaomi-ocr-0", ("xiaomi-ocr-0", "Sherlock native"), "xiaomi-ocr-0", "xiaomi-ocr-0-49202334", ["Markdown output", "the 96 is run xiaomi-ocr-0-49202334; the public figures are the 895 run (ocr-scorers.json, Sherlock native), named apart; whether one job or two is not recorded here (R-6) [?]"]),
        ("qwen3.5-9b-sherlock", "Qwen3.5 9B (your cluster)", None, None, None, "qwen3.5-9b-49202328", ["96 only in the scorer tables"]),
        # W46.ocr-rows-omitted: dominated on the 96 by qwen3.5-9b-sherlock, but the best cluster route on seven strata of the 440
        ("churro-3b-farmshare", "CHURRO-3B (your cluster)", "fs-churro", ("fs-churro", "FarmShare churro"), None, "churro-1855420",
         ["trained on CHURRO-DS, the source of the 440's strata it leads (L5-L8, N1, N3, N4); image-hash overlap with the 895 not checked (OCR-15, W46.ocr-churro-overlap)",
          "public: the 440 only", "weights Qwen research licence, CHURRO-DS research use only (C-ocr.md); acceptable in a user's own kit, stated",
          "on the 96 it is dominated: 91.07 answered against qwen3.5-9b-sherlock 95.13, and slower (1,251.0 pages an hour)"]),
    ]:
        add(rid, nm, "cluster", None, "measured", {"cluster": True, "gpus": fsrows[label].get("gpus")}, figs(rid, rid, hk, pk, lk), cost(rid, money=False), cluster_time(label),
            {"peak_gb": None, "measured_on": "GPU memory not tabulated", "source": None}, cav)

    def cluster_by(dom, dom_label):
        return lower(f"{dom} scores higher on the 96, {head[dom]['nes_answered']} answered, and reads more pages an hour, "
                     f"{fsrows[dom_label]['per_hour']:,} on {fsrows[dom_label].get('gpus') or 1} GPU")

    # W47.wh-readers-lost (owner call 15, 2026-11-19): the cluster routes a faster cluster row dominates on the 96
    # (04-reading.md §4, "Not in the table"), offered at Advanced with their figures, never a default or a pick.
    Q9, P16 = ("qwen3.5-9b-sherlock", "qwen3.5-9b-49202328"), ("paddleocr-vl1.6-sherlock", "paddleocr-vl1.6-49202331")
    for rid, nm, hk, pk, lk, label, dom, cav in [
        ("qwen3.5-122b-a10b-farmshare", "Qwen3.5 122B-A10B (your cluster)", None, None, None, "qwen3.5-122b-a10b-1850212", Q9, ["four GPUs", "96 only in the scorer tables"]),
        ("ling3-flash-vl-farmshare", "Ling3 Flash VL fp8 (your cluster)", "ling3-flash-vl-fp8", ("ling3-flash-vl-fp8", "FarmShare panel"), "ling3-flash-vl-fp8", "ling3-flash-vl-fp8-1861703", Q9,
         ["four GPUs", "N5 82.29, a tie with qwen3.6-35b-a3b-farmshare and with the N5 leader by the interval (04-reading.md §4)"]),
        ("qwen3-vl-8b-farmshare", "Qwen3-VL 8B (your cluster)", "qwen3-vl-8b (FarmShare panel)", ("qwen3-vl-8b", "FarmShare panel"), "qwen3-vl-8b", "qwen3-vl-8b-1861701", Q9, []),
        ("qwen3.8-27b-sherlock", "Qwen3.8 27B (your cluster)", "qwen3.8-27b", ("qwen3.8-27b", "Sherlock panel"), "qwen3.8-27b", "qwen3.8-27b-sherlock-49202336", Q9, []),
        ("qwen3.8-27b-farmshare", "Qwen3.8 27B, FarmShare build (your cluster)", None, None, None, "qwen3.8-27b-1850053", Q9,
         ["96 only: the public and hand figures are the Sherlock run's (row qwen3.8-27b-sherlock)"]),
        ("glm-ocr-farmshare", "GLM-OCR (your cluster)", "glm-ocr", ("glm-ocr", "FarmShare native"), "glm-ocr", "glm-ocr-1861696", Q9,
         ["whole page fails newspapers (29.2 on L9, cap or empty on 9 of 15): needs the layout stage (layout-photo.md); its layout role is note 03's"]),
        ("qwen3.5-4b-farmshare", "Qwen3.5 4B (your cluster)", "qwen3.5-4b", ("qwen3.5-4b", "FarmShare panel"), "qwen3.5-4b", "qwen3.5-4b-1861700", Q9, []),
        ("nemotron-parse-2-sherlock", "Nemotron Parse 2 (your cluster)", "nemotron-parse-2", ("nemotron-parse-2", "Sherlock native"), "nemotron-parse-2", "nemotron-parse-2-50569394", Q9, []),
        ("unlimited-ocr-sherlock", "Unlimited-OCR (your cluster)", "unlimited-ocr", ("unlimited-ocr", "Sherlock native"), "unlimited-ocr", "unlimited-ocr-50550130", Q9, []),
        ("lightonocr3-0.8b-farmshare", "LightOnOCR-3 0.8B (your cluster)", "lightonocr3-0.8b", ("lightonocr3-0.8b", "FarmShare native"), "lightonocr3-0.8b", "lightonocr3-0.8b-1861697", P16, []),
        ("ppocrv6-medium-farmshare", "PP-OCRv6 medium (your cluster)", "ppocrv6-medium", ("ppocrv6-medium", "FarmShare pipeline"), "ppocrv6-medium", "ppocrv6-medium-1861702", P16,
         ["its Mac form is ppocrv6-kraken-blla"]),
    ]:
        add(rid, nm, "cluster", None, "measured", {"cluster": True, "gpus": fsrows[label].get("gpus")}, figs(rid, rid, hk, pk, lk), cost(rid, money=False), cluster_time(label),
            {"peak_gb": None, "measured_on": "GPU memory not tabulated", "source": None}, cav, conditions=[cluster_by(*dom)])
    for rid, nm in [("german-handwriting", "kraken German handwriting model"), ("tridis", "kraken TRIDIS"), ("catmus-medieval", "kraken CATMuS Medieval"), ("greek-minuscule", "kraken Greek minuscule"), ("biblia", "kraken BiblIA")]:
        add(f"kraken-{rid}", f"{nm} (script specialist, kraken)", "mac", None, "measured", {"mac": True},
            figs(pk=(rid, "kraken specialist")), {"usd_1000_list": 0.0, "source": None}, lfl_time(f"kraken-{rid}"), {"peak_gb": None, "source": None},
            ["only the strata it was built for; known source overlap with its training data (specialists.md)", "no reading of the 96"], ["its own script stratum only"])
    return rows


# ---------------------------------------------------------------- stage headers the notes give in prose
NOTE_OF = {}  # stage id -> note file, filled by build()

HEADERS = {
 "reading-copy": {"id": "reading-copy", "name": "The reading copy: rotation, straightening, image size", "unit": "pages", "choice": False,
   "metric": {"id": "rotation_pages_wrong", "label": "Rotation: held-out owner pages wrong at any of four turns (turns exact beside it)", "higher_is_better": False},
   "kinds": ["latin-modern", "charters-L7", "nonlatin-N1-N4-N5"],
   "routes_role": "rotation rows; the rotation-by-profile rule picks one by profile and script, the user does not"},
 "reading": {"id": "reading", "name": "Reading: OCR and HTR", "unit": "pages", "choice": True,
   "metric": {"id": "nes_answered", "label": "NES on answered pages, failures beside", "higher_is_better": True},
   "kinds": ["typewritten", "printed", "handwritten", "mixed", "forms", "newspapers", "clippings", "nonlatin", "early_modern_hands", "early_print"],
   "kind_strata": {"handwritten": ["L1", "L2", "L3"], "forms": ["L4"], "newspapers": ["L9"], "nonlatin": ["N1", "N2", "N3", "N4", "N5", "N6"],
                   "early_modern_hands": ["L2", "L5", "L6", "L7"], "early_print": ["L8"], "source": "04-reading.md §3. The rule for the settings layer"},
   "rules": [
    {"id": "rank-answered-or-strict", "text": "Rank on answered NES when a fallback is configured for failed pages; with no fallback rank on strict NES.", "source": "04-reading.md §3. The rule for the settings layer", "switch": None},
    {"id": "hands-ranked-on-hands16", "text": "Handwritten pages are ranked on hands16 and, where the route read them, the public L1-L3; the 16-page chart alone is labelled agreement with the drafters.", "source": "04-reading.md §3. The rule for the settings layer", "switch": None},
    {"id": "nonlatin-not-vision", "text": "Apple Vision is not offered on non-Latin scripts (N1-N6); a route with no reading of a stratum shows not read, never 0.", "source": "vision-27-reread.md", "switch": None},
    {"id": "newspapers-layout-first", "text": "Newspapers and multi-column clippings: the layout stage's regions run first for every reader; required for GLM-OCR and PaddleOCR-VL. Never on handwriting or registers.", "source": "layout-photo.md §Answer", "switch": None},
    {"id": "free-default", "text": "Free: typed and printed pages with Apple Vision; handwritten pages on a 16 GB Mac get LightOnOCR-3 4B 8-bit proposed as a download, else flagged needs a download or a key; a page Vision returns empty for is flagged, never skipped.", "source": "14-owner-calls.md §1. The owner's calls", "switch": None},
    {"id": "no-apple-fm", "text": "The macOS 27 on-device model is never the app's pick for reading; it is offered at the Advanced level with its figures (owner call 15).", "source": "r1-foundation.md", "switch": None},
    {"id": "lower-scoring-advanced", "text": "A route that scored below a row it is measured against (a row of its family higher on the 96 at no more cost, or more pages an hour on a cluster) is offered at the Advanced level with its figures, never as a default or the app's pick.", "source": "14-owner-calls.md §1. The owner's calls", "switch": None},
    {"id": "no-post-correction", "text": "No post-correction stage; a log-probability score is a check-this-reading flag, not a trigger.", "source": "ocr-postcorrect.md", "switch": None},
    {"id": "cascade-as-route", "text": "Each measured cascade is a route row, picked when it beats the single routes within the limits; failure is its only trigger, the Vision word-count trigger opt-in.", "source": "14-owner-calls.md §1. The owner's calls", "switch": None},
    {"id": "loop-fallback", "text": "A local reader's loop falls to a second reader or kraken PP-OCRv6 on lines, never a half-size retry.", "source": "bench-corpus/loop-rerun-20261021.md", "switch": None},
    {"id": "never-skip", "text": "No page kind skips reading; no Vision text is not no text.", "source": "ocr-truth.md", "switch": None}],
   "fallback": "fail-and-flag (CascadeExhausted)"},
 "segmentation": {"id": "segmentation", "name": "Page-stream segmentation", "unit": "pages", "choice": True,
   "metric": {"id": "pages_exact", "label": "Pages in an exact document, no checking, on common resolved documents in the two locked test boxes", "higher_is_better": True},
   "kinds": ["test-boxes", "letters", "magazine", "clippings-mixed", "manuscripts-public", "typed-gov-public"],
   "rules": [
    {"id": "magazine-article-rule", "text": "A magazine figure ranks only for a route whose prompt states the article-within-issue rule (Gemini 3.8 on g2, its figure Gemini 3.7's, since W46.seg-magazine-rule-app); every other route's is shown with ranks nothing yet.", "source": "seg-magazine-rule-app.md", "switch": None},
    {"id": "clippings-owner-weighted", "text": "The clippings-mixed comparison uses the owner-ruled weighted figure, never the all-known diagnostic.", "source": "seg-boxes-score.md §SC0122 on its owner-ruled gaps", "switch": None},
    {"id": "manuscript-warning", "text": "On handwritten manuscripts a local or cluster Qwen route carries the warning that on Lincoln's manuscripts it put 35.6% of pages in the right document; a cloud voter is recommended where feasible.", "source": "seg-lincoln-cloud.md", "switch": None},
    {"id": "window-7-stride-3", "text": "Seven-page windows at stride 3 with images and Vision text, every route; no self-voting, no collection-facts block.", "source": "seg-window-modality.md", "switch": None},
    {"id": "review-rule", "text": "Cloud routes flag by their own frozen level; the local 2B shows the gaps where it and a second model disagree, else its own level.", "source": "options.md", "switch": None},
    {"id": "labels-never-voted", "text": "Box and folder label photos are boundaries by construction and are never voted on.", "source": "options.md", "switch": None},
    {"id": "adaptation-after-200", "text": "After a reviewed box of about 200 corrected gaps of one material, the 2B's LoRA continuation is offered to cluster profiles for that material's next boxes, flagging kept on, only past the kit's gate.", "source": "14-owner-calls.md §1. The owner's calls", "switch": None}],
   "fallback": "manual: every gap is a check"},
 "dating": {"id": "dating", "name": "Dating", "unit": "documents", "choice": True,
   "metric": {"id": "not_in_text", "label": "Exact year where the year is not in the text, among routes whose non-explicit years carry checked evidence", "higher_is_better": True},
   "kinds": ["in_text", "not_in_text", "enclosure", "undated", "decade"],
   "rules": [
    {"id": "steps", "text": "Steps in order: explicit from the text; explicit from the image on documents with no year candidate in the text; inherited from a cover or a dated folder; estimated from neighbours with checked evidence, always Date Uncertain.", "source": "date-image.md", "switch": None},
    {"id": "image-every-document", "text": "The image pass on documents whose text already has a year is the user's option, off by default; on, it adds stamp dates as second-role dates, about $1.93 more per 1,000 documents (owner, 2026-11-12).", "source": "date-route-pipeline.md", "switch": {"id": "dating.image_every_document", "label": "Search the page image for dates on every document", "default": False}},
    {"id": "uncertain-by-evidence", "text": "Date Uncertain is set by the evidence class; the model's own flag may only add it to an explicit text year, never remove it (owner, 2026-11-12).", "source": "date-truth.md", "switch": None},
    {"id": "no-untraceable-guess", "text": "A reply whose evidence fails is not written as a date and not shown as a suggestion.", "source": "date-traceable.md", "switch": None},
    {"id": "no-typeface-dating", "text": "Typeface or paper dating and look-alike retrieval are not steps.", "source": "date-image-typeface.md", "switch": None},
    {"id": "not-on-labels", "text": "Box and folder label segments are not dated as documents; they are inputs to folder inheritance.", "source": "B-dating.md", "switch": None}],
   "fallback": "no year, Date Uncertain; the rule stage's explicit year stands"},
 "kinds": {"id": "kinds", "name": "Page kinds and routing by kind", "unit": "pages", "choice": False,
   "metric": {"id": "pages_right", "label": "Pages right per kind on the owner's 141 and the public 895", "higher_is_better": True},
   "kinds": ["handwritten", "typewritten", "printed", "forms"],
   "routes_role": "the classifier is a rule (kind-vision-lr); atrium-zero-shot is the measured alternative, not offered",
   "rules": [
    {"id": "classifier-shipped", "text": "The shipped classifier (Vision signals and the feature print) labels each page's kind on the Mac and measures the collection's mix from a sample.", "source": "kind-atrium.md §Verdict", "switch": None},
    {"id": "low-confidence-keeps-model", "text": "A page whose top class is under 0.8 keeps the run's model.", "source": "K-kinds.md", "switch": None},
    {"id": "mixed-to-handwritten", "text": "Mixed pages have no class: they go to the handwritten pick.", "source": "kind-classifier.md", "switch": None},
    {"id": "mixed-route", "text": "Read handwriting on typed pages (signatures, dates, notes in the margin). Measured level on typed pages, not measured on mixed pages.", "source": "mixed-route-bands.md", "switch": {"id": "mixed-route", "label": "Read handwriting on typed pages (signatures, dates, notes in the margin)", "default": False}},
    {"id": "cascade-breaker", "text": "Escalation is capped after 20 pages at 25% of the run's pages; never on a remote gateway, the Local Agent or Apple Vision as first reader.", "source": "10-kinds-and-routing.md §3. The rule for the settings layer", "switch": None}],
   "fallback": "the run's model (weights fail to load)"},
 "training-kit": {"id": "training-kit", "name": "Training on the user's own material", "unit": "gaps / lines", "choice": True,
   "metric": {"id": "paired_vs_shipped", "label": "Gap accuracy (segmentation) or NES (handwriting), paired against the route it would replace", "higher_is_better": True},
   "kinds": ["per-material", "handwritten-one-hand"],
   "routes_role": "after-training rows: shown only when the fine-tuning answer allows them, selectable only once their condition holds, never a default",
   "rules": [
    {"id": "fine-tuning-answer", "text": "No: no row shown. With a coding agent: only the Mac segmentation row, as not offered. On a cluster: the cluster rows as well.", "source": "12-training-kit.md §3. The rule for the settings layer", "switch": None},
    {"id": "gate", "text": "A segmentation candidate is used only with a manifest that passed the kit's held-out gate (paired interval's low end above -3 points, minimum known-gap support, two scored runs, anchor margin 3.2).", "source": "seg-kit-gate.md §The gate: `train_seg.py check` and the manifest", "switch": None},
    {"id": "label-floors", "text": "No continuation under 200 corrected gaps of one material.", "source": "seg-adapt-lora.md; 14-owner-calls.md §1. The owner's calls", "switch": None},
    {"id": "no-mac-seg-training", "text": "No Mac segmentation training at 16-18 GB.", "source": "kit-mac-lora.md", "switch": None}],
   "fallback": "the route it replaced"},
}

NOISE = {
 "reading-copy": {"metric": "rotation_pages_wrong", "tie": "Wilson page intervals that overlap; a gap of a few turns is a tie", "source": "rotation-routes.md §Noise"},
 "ocr-input": {"metric": "nes", "tie": "paired 95% interval across 0, or a gap under 0.49 NES points", "source": "enh-ocr-input.md §Measurement card"},
 "layout": {"metric": "nes_strict", "tie": "paired 95% page-bootstrap interval across 0, NES points; per-kind groups under 20 pages are descriptive", "source": "layout-photo.md §Measurement card"},
 "reading": {"metric": "nes", "tie": "on the 96 a paired gap under the floor only (owner, 2026-11-11: hosted 0.49, local greedy 0.00, per kind hosted typewritten 0.42, printed 0.24, handwritten 0.60; each floor twice a rerun range; the paired 95% interval is shown, makes no tie); on the 895 a pick takes the stratum's leader (the interval across 0 makes no tie there either, W46.pairs-redecide; it decides only a stratum row's admission); NES points; each pair's entry in ocr-pair-matrix.json, per kind, hands16 and L1-L3", "source": "ocr-rerun-noise.md §The tie rule; ocr-pair-matrix.md §The tie per pair"},
 "placement": {"metric": "line_pass_strict", "tie": "paired page-bootstrap 95% interval holding 0; about 2 points on 20 owner hand pages, about 10 on 14 Bentham pages", "source": "place-print.md §Measurement card"},
 "marks": {"metric": "marks_read_nes08", "tie": "a gap inside the page-bootstrap interval, about 20 marks-read points", "source": "marks-read.md §Measurement card"},
 "segmentation": {"metric": "pages_exact", "tie": "a paired 95% interval of test-box pages exact holding 0, the two routes compared page by page on the same windows (offset 0) and the truth's documents resampled; each pair's entry in the stage's pairs (seg-pair-ties.json). Replaces twice the larger window-offset range (owner review of the pipeline doc, 2026-11-17, W46.seg-truth-audit); in gap accuracy the paired interval decides as before", "source": "seg-pair-ties.md §Every pair, a minus b, in points of pages exact; seg-boxes-score.md §Paired differences"},
 "dating": {"metric": "not_in_text", "tie": "the rerun floor, same year 94% (85/90), or no paired sign-test difference", "source": "date-undated.md §Rerun"},
 "entities": {"metric": "sender_ed2_f1", "tie": "paired 95% bootstrap interval containing zero, or inside the rerun floor", "source": "ent-place-rule.md §Paired differences in ed2 F1, b minus a (95% bootstrap interval)"},
 "kinds": {"metric": "pages_right", "tie": "paired bootstrap intervals that overlap", "source": "kind-atrium.md §3. The 96: the hand, and what routing by each costs"},
 "capture": {"metric": "delta_nes_strict_paired", "tie": "a change whose 95% bootstrap interval crosses 0 is no effect", "source": "capture-ladder.md §Findings"},
 "training-kit": {"metric": "paired_vs_shipped", "tie": "a paired interval reaching zero (no gap-accuracy floor measured; kraken fixed-weight floor 0)", "source": "seg-kit-gate.md §The gate: `train_seg.py check` and the manifest"},
}

ORDER = [("01-reading-copy.md", "reading-copy"), ("02-ocr-input.md", "ocr-input"), ("03-layout.md", "layout"), ("04-reading.md", "reading"),
         ("05-placement.md", "placement"), ("06-marks.md", "marks"), ("07-segmentation.md", "segmentation"), ("08-dating.md", "dating"),
         ("09-entities.md", "entities"), ("10-kinds-and-routing.md", "kinds"), ("11-capture.md", "capture"), ("12-training-kit.md", "training-kit")]

# The figure key each stage's metric is read from: "<kind>" means the key named for the kind being ranked.
METRIC_FIGURE = {
 "reading-copy": "owner-heldout", "ocr-input": None, "layout": "<kind>", "marks": None, "capture": None,
 "reading": "overall for all pages; <kind> per kind (strict), with hands16 and public_L1-L3 beside handwritten, and reflows (the reader joins the page's lines; its hand pages get the text page)",
 "placement": "<kind>", "segmentation": "test-boxes", "dating": "not_in_text", "entities": "sender", "kinds": "<kind>",
 "training-kit": "per row: each figure names its own metric",
}

ROW_KEYS = ["id", "name", "family", "app_route", "status", "needs", "figures", "cost", "time", "memory", "caveats", "kind_rules", "fallback", "conditions"]

# W43.app-guide-refresh: the reading rows the Processor offers as the bench read them, `<provider>|<model id>` as
# `ProviderModels.swift` names them (the provider's rawValue, lower-cased). A row here is "shipped". The Gemini and
# OpenAI rows were read through the vendor's own endpoint on OpenRouter (`ocr_cloud.py`), the app calls the vendor
# directly; Mistral OCR through the app's own MistralClient (`ocr_cloud_mistral.py`); each OpenRouter row on the
# provider and precision `OpenRouterRoute.catalog` pins (`ocr_panel.py`, `ocr_cloud.py`, `ocr_cloud_full.py`).
APP_ROUTES = {
 "gemini3.5-flash-lite": "gemini|gemini-3.5-flash-lite",
 "gemini3.1-flash-lite": "gemini|gemini-3.1-flash-lite",
 "gemini3.5-flash": "gemini|gemini-3.5-flash",
 "gemini3.1-pro": "gemini|gemini-3.1-pro",
 "gpt5.4-mini": "openai|gpt-5.4-mini",
 "mistral-ocr-4-1": "mistral|mistral-ocr-latest",
 "qwen3-vl-235b": "openrouter|qwen/qwen3-vl-235b-a22b-instruct",
 "qwen3.6-27b": "openrouter|qwen/qwen3.6-27b",
 "qwen3.8-flash": "openrouter|qwen/qwen3.8-flash",
 "qwen3.5-9b": "openrouter|qwen/qwen3.5-9b",
 # W47.wh-readers-lost-clients: the lower-scoring hosted rows, on the endpoint and precision ocr_panel.py and ocr_cloud.py
 # pinned (Mistral Medium 3.5 on Mistral's own endpoint through OpenRouter, as ocr_cloud.py read it).
 "qwen3-vl-8b": "openrouter|qwen/qwen3-vl-8b-instruct",
 "qwen3-vl-30b-a3b": "openrouter|qwen/qwen3-vl-30b-a3b-instruct",
 "qwen3.5-35b-a3b": "openrouter|qwen/qwen3.5-35b-a3b",
 "mistral-medium3.5": "openrouter|mistralai/mistral-medium-3-5",
}
KEY_NAMES = {"stanford-gateway": "gateway"}


def lower(why):
    """W47.wh-readers-lost: a reading row that scored below a row it is measured against. The owner released them on
    2026-11-19 (call 15): selectable at the Advanced level with their figures, never a default or a solver pick. The
    app reads the prefix (`SettingsRouteTable.Route.lowerScoring`)."""
    return f"lower-scoring: {why}; offered at the Advanced level only, never the app's pick (owner call 15)"


def norm_needs(n, family):
    n = n or {}
    out = {"key": sorted({KEY_NAMES.get(k, k) for k in n.get("key", [])}), "plan": list(n.get("plan", [])),
           "cluster": bool(n.get("cluster", False)), "gpus": n.get("gpus") or None,
           "mac": False, "mac_gb": n.get("mac_gb") or None, "built_in": bool(n.get("built_in", False))}
    # a Mac route, or a row with no other access that states a Mac memory floor (the kit's Mac fine-tune)
    out["mac"] = bool(n.get("mac", family == "mac" or (out["mac_gb"] and not (out["key"] or out["plan"] or out["cluster"]))))
    return out


def is_prototype_source(s):
    return isinstance(s, dict) and any(str(s.get("file", "")).endswith(p) for p in PROTOTYPE_FILES)


def strip_prototype_sources(x):
    """A figure whose only source is the prototype's hand-entered tables becomes an estimate with no source."""
    if isinstance(x, dict):
        if is_prototype_source(x.get("source")):
            s = x["source"]
            x["source"] = None
            x["measured"] = False
            x["estimate"] = f"hand-entered in the 2026-11-04 settings prototype ({s['file'].split('/')[-1]}, {s.get('route', '')}: {s.get('value', '')}); no measuring file"
        for v in x.values():
            strip_prototype_sources(v)
    elif isinstance(x, list):
        for v in x:
            strip_prototype_sources(v)


def norm_row(r):
    r = copy.deepcopy(r)
    strip_prototype_sources(r)
    out = {k: r.get(k) for k in ROW_KEYS}
    for k in ("caveats", "kind_rules", "conditions"):
        out[k] = list(out[k] or [])
    out["figures"] = out["figures"] or {}
    out["needs"] = norm_needs(r.get("needs"), r.get("family"))
    for k, v in r.items():  # fields a note adds beyond the schema: step, stages, trigger, delta ...
        if k not in out:
            out[k] = v
    return out


def seg_pairs():
    """seg-pair-ties.json's pairs as the solver reads them: a minus b in points of test-box pages exact, its paired
    95% interval, and whether the interval holds 0 (the tie)."""
    m = json.load(open(os.path.join(R, "ArchiveProcessor/segbench-results/seg-pair-ties.json")))
    return [{k: p[k] for k in ("a", "b", "delta", "lo", "hi", "documents", "tie")} for p in m["pairs"]]


def check_seg_pairs(table):
    """Every segmentation row with a test-boxes figure is paired with every other, at the figures the table holds."""
    st = next(s for s in table["stages"] if s["id"] == "segmentation")
    have = {r["id"]: r["figures"]["test-boxes"]["value"] for r in st["routes"] if "test-boxes" in r["figures"]}
    m = json.load(open(os.path.join(R, "ArchiveProcessor/segbench-results/seg-pair-ties.json")))
    bad = 0
    got = {frozenset((p["a"], p["b"])) for p in st.get("pairs", [])}
    want = {frozenset((a, b)) for a in have for b in have if a < b}
    if got != want:
        print(f"FAIL segmentation pairs: {len(want - got)} missing, {len(got - want)} extra (rerun seg_pair_ties.py)"); bad += 1
    for k, v in have.items():
        if k not in m["routes"] or abs(m["routes"][k]["pct"] - v) > 0.05:
            print(f"FAIL segmentation pairs: {k} is {v} in the table, {m['routes'].get(k)} in seg-pair-ties.json"); bad += 1
    if not bad:
        print(f"PASS segmentation pairs: {len(have)} rows, each paired with every other ({len(got)} pairs)")
    return bad


def build(built):
    stages = []
    for note, sid in ORDER:
        st, rows, other = note_rows(note)
        if sid == "reading":
            rows = reading_rows() + [r for r in rows if r["id"].startswith("casc-")]
        head = copy.deepcopy(st[0]) if st else {}
        head.update({k: v for k, v in HEADERS.get(sid, {}).items() if k not in head})
        for o in other:  # 01's rules-and-fallback block
            for k in ("rules", "fallback"):
                if k in o and k not in head:
                    head[k] = o[k]
        if head.get("id") != sid:
            raise SystemExit(f"{note}: stage id {head.get('id')!r}, expected {sid!r}")
        head["note"] = f"{NOTES}/{note}"
        head["metric"] = dict(head["metric"], figure=METRIC_FIGURE[sid])
        head["routes"] = [norm_row(r) for r in (head.get("routes") or []) + rows]
        if sid == "segmentation":  # W46.seg-truth-audit: the tie is read per pair, from the paired comparisons
            head["pairs"] = seg_pairs()
        for k in ("rules", "kinds"):
            head.setdefault(k, [])
        head.setdefault("fallback", None)
        order = ["id", "name", "note", "unit", "choice", "metric", "kinds", "kind_strata", "rules", "fallback", "routes_role", "routes", "pairs"]
        stages.append({k: head[k] for k in order if k in head} | {k: v for k, v in head.items() if k not in order})
    # W41.app-openrouter-claude: Claude Sonnet 5.5's windows also go through OpenRouter on Anthropic's own endpoint
    # (`OpenRouterClaudeWindowTransport`), at Anthropic's price. Claude alone: the mix's ChatGPT half is not a measured
    # OpenRouter route, so the mix keeps its plans.
    for st in stages:
        for r in st["routes"]:
            if st["id"] == "segmentation" and r["app_route"] == "anthropic|claude-sonnet-5-5" and "openrouter" not in r["needs"]["key"]:
                r["needs"]["key"] = sorted(r["needs"]["key"] + ["openrouter"])
    ids = [r["id"] for s in stages for r in s["routes"]]
    return {"version": 1, "built": built, "item": ITEM, "method": "ArchiveProcessor/scripts/segbench/settings_routes.py",
            "schema": f"{NOTES}/00-index.md §The table schema", "noise": NOISE, "stages": stages}


# ---------------------------------------------------------------- the drift test
NUM = re.compile(r"(?:(?<![\d.])-)?\d[\d,]*(?:\.\d+)?")


def _norm_text(s):
    return s.replace("−", "-").replace("–", "-").replace(" ", " ").replace(" ", " ")


def numbers(s):
    return [n.replace(",", "") for n in NUM.findall(_norm_text(s))]


def _has(n, text):
    return re.search(r"(?<![\d.])" + re.escape(n) + r"(?![\d])", text) is not None


STOP = {"the", "and", "of", "a", "an", "on", "in", "at", "to", "by", "for", "with", "s", "is", "what", "this", "means", "line", "section", "all"}


def route_tokens(route):
    return [w for w in re.findall(r"[a-z0-9]+(?:\.[0-9]+)?", _norm_text(route or "").lower()) if w not in STOP and len(w) > 1]


LOOSE = "loose"


def check_source(s, cache):
    """None when the figure is found in the file its source names, else the reason. The source's numbers must stand
    together on one line, else in one paragraph, else in one section, and that line, paragraph or section must also
    carry a word of the source's route (or its attribute when no route is named); failing that, the route must be named
    somewhere in the file (a result file about one route often names it only in its title or its own table), and
    such a figure is counted apart as matched loosely."""
    p = resolve(s["file"])
    if not p:
        return f"no file {s['file']}"
    if p.endswith(".json"):
        return None  # the reading rows' JSON sources are checked by regenerating them from the file
    if p not in cache:
        t = _norm_text(open(p).read())
        flat = lambda x: x.replace(",", "").replace("\n", " ")
        cache[p] = (flat(t), [l.replace(",", "") for l in t.split("\n")], [flat(b) for b in re.split(r"\n\s*\n", t)],
                    [flat(x) for x in re.split(r"\n(?=#)", t)])
    text, lines, blocks, sections = cache[p]
    val = s.get("value") or s.get("attribute", "")
    toks = route_tokens(s.get("route")) or route_tokens(s.get("attribute"))
    near = lambda u: not toks or any(w in u.lower() for w in toks)
    N = numbers(val)
    if not N:
        v = _norm_text(val)
        hits = [u for u in sections if v in u]
        if not hits:
            return f"text {val!r} not in {s['file']}"
        if any(near(u) for u in hits):
            return None
        return LOOSE if near(text) else f"text {val!r}: neither its section nor {s['file']} names {s.get('route')!r}"
    for level in (lines, blocks, sections):
        hits = [u for u in level if all(_has(n, u) for n in N)]
        if any(near(u) for u in hits):
            return None
    missing = [n for n in N if not _has(n, text)]
    if missing:
        return f"{val!r}: {missing} not in {s['file']}"
    if any(all(_has(n, u) for n in N) for u in sections) and near(text):
        return LOOSE
    return f"{val!r}: not together with {s.get('route') or s.get('attribute')!r} in one line, paragraph or section of {s['file']}"


def same_figure(v, N):
    """v is one of the source's numbers, rounded, or the same quantity in a unit 100 or 1,000 times apart
    (a share against a percentage, dollars a page against dollars per 1,000, MB against GB)."""
    for n in N:
        for f in (1, 100, 0.01, 1000, 0.001):
            m = n * f
            if abs(v - m) <= max(0.006, abs(m) * 0.006):
                return True
    return False


CHECKED_FIELDS = {"source": ("value", "usd_1000_list", "usd_1000_batch", "per_unit_s", "peak_gb", "pages_per_hour_per_gpu_set"),
                  "whole_process_source": ("whole_process_gb",)}


def check_section(ref):
    """A rule's "file.md §section" source (several joined by "; "): each file exists and has the section, as a
    heading ("§Verdict"), a numbered heading ("§3 claim 36" is under "## 3. ...") or a bold card label ("§Noise")."""
    for part in ref.split("; "):
        f, _, sec = part.partition(" §")
        f = f.strip()
        p = resolve(f)
        if not p:
            return f"no file {f}"
        sec = _norm_text(sec.strip())
        if not sec:
            continue
        text = _norm_text(open(p).read())
        heads = [l.lstrip("#").strip() for l in text.split("\n") if l.startswith("#")]
        first = sec.split()[0]
        if not (any(h.startswith(sec) for h in heads) or (first.isdigit() and any(h.startswith(first + ".") for h in heads))
                or f"**{sec}" in text):
            return f"no section {sec!r} in {f}"
    return None


def walk_sources(x, where, out):
    if isinstance(x, dict):
        s = x.get("source")
        if isinstance(s, dict):
            out.append((where, s, x))
        for k, v in x.items():
            if k in ("source",):
                continue
            if k.endswith("_source") and isinstance(v, dict):
                out.append((where + "/" + k, v, x))
                continue
            walk_sources(v, where + "/" + k, out)
    elif isinstance(x, list):
        for v in x:
            walk_sources(v, where, out)


def check_pair_cover(table):
    """W46.pair-matrix-cover: every reading row with per-page scores is paired with every other such row in
    ocr-pair-matrix.json, in each of its groups (the 96's kinds and hands16, the 895's strata and L1-L3)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import ocr_pair_matrix as M
    path = os.path.join(R, "ArchiveProcessor/segbench-results/ocr-pair-matrix.json")
    m = json.load(open(path))
    want = M.coverage(M.table_routes(table))
    have = {}
    for e in m["pairs"]:
        st = M.HANDS_GROUP if e["group"] == M.HANDS_GROUP else e["set"]
        have.setdefault(st, set()).update((e["a"], e["b"]))
    bad = 0
    for st, ids in want.items():
        gone = [i for i in ids if i not in have.get(st, set()) or i not in m["routes"].get(st, [])]
        if gone:
            print(f"FAIL pair matrix: {st} has no pair entries for {', '.join(gone)} (rerun ocr_pair_matrix.py)"); bad += 1
    groups = {"owner96": ["all", *M.KINDS], M.HANDS_GROUP: [M.HANDS_GROUP]}
    for st, gs in groups.items():
        k = len(want[st])
        for g in gs:
            n = sum(1 for e in m["pairs"] if e["group"] == g and e["set"] == "owner96")
            if n != k * (k - 1) // 2:
                print(f"FAIL pair matrix: owner96/{g} holds {n} pairs, {k * (k - 1) // 2} wanted"); bad += 1
    for g in M.POOLED:
        if not any(e["group"] == g for e in m["pairs"]):
            print(f"FAIL pair matrix: no {g} group on the 895"); bad += 1
    if not bad:
        print(f"PASS pair matrix: {len(want['owner96'])} rows on the 96 ({len(want[M.HANDS_GROUP])} with hands16), "
              f"{len(want['public895'])} on the 895, each paired in every group")
    return bad


def check(table):
    bad = 0
    committed_path = os.path.join(R, OUT)
    if not os.path.isfile(committed_path):
        print(f"FAIL {OUT} is missing; run settings_routes.py")
        return 1
    committed = json.load(open(committed_path))
    fresh = build(committed.get("built"))
    if fresh != committed:
        a = json.dumps(committed, indent=1, ensure_ascii=False).splitlines()
        b = json.dumps(fresh, indent=1, ensure_ascii=False).splitlines()
        import difflib
        print(f"FAIL regenerate: {OUT} differs from what its files give now (run settings_routes.py):")
        for l in list(difflib.unified_diff(a, b, "committed", "regenerated", lineterm="", n=1))[:40]:
            print("    " + l)
        bad += 1
    else:
        print(f"PASS regenerate: {OUT} is what the result files and the stage notes give")
    ids = set()
    srcs, cache, estimates = [], {}, 0
    for st in table["stages"]:
        for r in st["routes"]:
            key = (st["id"], r["id"])
            if key in ids:
                print(f"FAIL duplicate row {key}"); bad += 1
            ids.add(key)
            missing = [k for k in ROW_KEYS if k not in r]
            if missing:
                print(f"FAIL {st['id']}/{r['id']}: missing {missing}"); bad += 1
            walk_sources(r, f"{st['id']}/{r['id']}", srcs)
            estimates += json.dumps(r).count('"estimate":')
        for rule in st.get("rules", []):
            why = check_section(rule["source"])
            if why:
                print(f"FAIL rule {st['id']}/{rule['id']}: {why}"); bad += 1
        if "kind_strata" in st and check_section(st["kind_strata"]["source"]):
            print(f"FAIL kind_strata {st['id']}: {check_section(st['kind_strata']['source'])}"); bad += 1
        if st["id"] not in table["noise"]:
            print(f"FAIL stage {st['id']} has no noise entry"); bad += 1
    for sid, n in table["noise"].items():
        why = check_section(n["source"])
        if why:
            print(f"FAIL noise {sid}: {why}"); bad += 1
    bad += check_pair_cover(table)
    bad += check_seg_pairs(table)
    shared = [r for st in table["stages"] for r in st["routes"] if r["id"] == "seg-2b-lora-k200"]
    if len(shared) == 2 and shared[0] != shared[1]:
        print("FAIL seg-2b-lora-k200 differs between notes 07 and 12 (one row shared)"); bad += 1
    for st in table["stages"]:  # W46.kit-licence-statement: the range view states each one's licence
        for r in st["routes"]:
            if r["status"] == "after-training" and not r.get("licence"):
                print(f"FAIL licence {st['id']}/{r['id']}: an after-training row states no licence"); bad += 1
    nfig = loose = 0
    for where, s, holder in srcs:
        nfig += 1
        why = check_source(s, cache)
        if why == LOOSE:
            loose += 1
        elif why:
            print(f"FAIL source {where}: {why}"); bad += 1
            continue
        if s["file"].endswith(".json"):  # regenerated from the file above
            continue
        if "derived" in holder:  # says how the stated figure becomes the value
            continue
        N = [float(n) for n in numbers(s.get("value", ""))]
        kind = "whole_process_source" if where.endswith("/whole_process_source") else "source"
        pair = "list" in s.get("attribute", "") and "batch" in s.get("attribute", "") and len(N) >= 2
        for k in CHECKED_FIELDS[kind]:
            v = holder.get(k)
            want = [N[0]] if pair and k == "usd_1000_list" else [N[1]] if pair and k == "usd_1000_batch" else N
            if isinstance(v, (int, float)) and not isinstance(v, bool) and N and not same_figure(v, want):
                print(f"FAIL value {where}: {k} {v} in the table, {s.get('value')!r} in {s['file']}"); bad += 1
    print(f"{'PASS' if not bad else 'FAIL'} sources: {nfig} figures checked against their files ({loose} found with the route named elsewhere in the file); {estimates} unmeasured estimates carried with no source; {bad} failures")
    return 1 if bad else 0


def main():
    if "--check" in sys.argv[1:]:
        sys.exit(check(json.load(open(os.path.join(R, OUT)))))
    built = datetime.date.today().isoformat()
    path = os.path.join(R, OUT)
    if os.path.isfile(path):  # keep the date when nothing else changed, so a rebuild is a no-op
        old = json.load(open(path))
        if build(old.get("built")) == old:
            built = old["built"]
    t = build(built)
    with open(path, "w") as f:
        json.dump(t, f, indent=1, ensure_ascii=False)
        f.write("\n")
    n = sum(len(s["routes"]) for s in t["stages"])
    print(f"wrote {OUT}: {len(t['stages'])} stages, {n} rows")


if __name__ == "__main__":
    main()
