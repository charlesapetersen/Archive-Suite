#!/usr/bin/env python3
"""Copy the stage-04 table rows' figures from the bench's own files (no figure computed; values rounded to 2 places)."""
import json, sys
R = "/Users/cp1/Claude/Archive Suite"
PD = "ArchiveOCRBench/data/panel-data.json"
HR = "ArchiveProcessor/segbench-results/ocr-hands-rescore.json"
SC = "ArchiveProcessor/segbench-results/ocr-scorers.json"
PH = "ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.json"
d = json.load(open(f"{R}/{PD}"))
head = {r["id"]: r for r in d["headline"]["rows"]}
charts = {c["key"]: c["scores"] for c in d["charts"]}
routes = {r["id"]: r for r in d["routes"]}
fsrows = {r["label"]: r for r in d["farmshare"]["truth"]}
hands = {r["route"]: r for r in json.load(open(f"{R}/{HR}"))["routes"]}
sc = json.load(open(f"{R}/{SC}"))["summary"]
pub = {}
for r in sc:
    if r["set"] == "public895":
        pub.setdefault((r["route"], r["family"]), {})[r["stratum"]] = r
ph = json.load(open(f"{R}/{PH}"))
l13 = {r["route"]: r for r in ph["public"]}
ownhand = ph["owner_hand"]

def src(f, route, attr, val):
    return {"file": f, "route": route, "attribute": attr, "value": str(val)}

def r2(x):
    return round(x, 2)

def figs(hid=None, cid=None, hk=None, pk=None, lk=None, ohk=None, truth_note=None):
    F = {}
    if hid and hid in head:
        h = head[hid]
        fail = {k: h[k] for k in ("transport", "model", "cap", "refusal", "empty") if h[k]}
        v = h["vs_baseline"]
        F["overall"] = {"value": h["nes_answered"], "n": f"{h['answered']}/{h['pages']} answered, p081 apart", "strict": h["strict"],
                        "failures": fail, "vs_qwen3.6-27b": (f"{v['delta']} ({v['lo']} to {v['hi']}, n {v['n']})" if v else "baseline"),
                        "truth": "owner-96", "source": src(PD, hid, "headline.rows.nes_answered", h["nes_answered"])}
    if cid and cid in charts["overall"]:
        K = {k: charts[k][cid] for k in ("typewritten", "printed", "handwritten") if charts[k].get(cid)}
        F["kinds"] = {"basis": "strict, failure as 0; [NES, answered, n]", "truth": "owner-96",
                      **{k: [r2(v[0]), v[1], v[2]] for k, v in K.items()},
                      "source": src(PD, cid, "charts.<kind>.scores", {k: v[0] for k, v in K.items()})}
    if hk and hk in hands:
        h = hands[hk]
        F["hands16"] = {"value": r2(h["after"]), "n": 16, "failed": h["failed"], "unresolved_range": f"{r2(h['lo'])} to {r2(h['hi'])}",
                        "truth": "owner-96 after the 2026-10-31 hand sheet (drafter-biased, OCR-1)", "source": src(HR, hk, "routes.after", h["after"])}
    if ohk and ohk in ownhand:
        F["hands16"] = {"value": r2(ownhand[ohk]), "n": 16, "truth": "owner-96 after the hand sheet", "source": src(PH, ohk, "owner_hand", ownhand[ohk])}
    if lk and lk in l13:
        x = l13[lk]
        F["public_L1-L3"] = {"value": r2(x["nes"]), "n": x["n"], "strata": {k: r2(v) for k, v in x["strata"].items()}, "empty": x["empty"],
                             "truth": "public (independent)", "source": src(PH, lk, "public.nes", x["nes"])}
    if pk and pk in pub:
        P = pub[pk]
        F["public"] = {"basis": "[NES strict, NES answered, answered/n]", "truth": "public (independent of the routes)",
                       **{st: [r2(x["nes"] * 100), (r2(x["nes_answered"] * 100) if x["nes_answered"] is not None else None), f"{x['ok']}/{x['n']}"] for st, x in sorted(P.items())},
                       "source": src(SC, f"{pk[0]} ({pk[1]})", "summary[set=public895, stratum].nes", {st: round(x["nes"], 4) for st, x in sorted(P.items())})}
    if truth_note:
        for v in F.values():
            v["truth_note"] = truth_note
    return F

def cost(cid, money=True):
    r = routes.get(cid)
    if not r:
        return None
    c = {"usd_1000_list": r["std"], "usd_1000_batch": r["batch"], "price_read": "2026-10 (panel run)", "source": src(PD, cid, "routes.std", r["std"])}
    if not money:
        c = {"usd_1000_list": 0.0, "openrouter_equivalent_usd_1000": r["std"], "source": src(PD, cid, "routes.std (OpenRouter rate for the run's tokens)", r["std"])}
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
    rows.append({"id": id, "name": name, "family": family, "app_route": app_route, "status": status, "needs": needs, "figures": F,
                 "cost": cost_, "time": time_, "memory": mem, "caveats": list(caveats), "kind_rules": list(kind_rules), "fallback": fallback, "conditions": list(conditions)})

ML = "ArchiveProcessor/segbench-results/ocr-mac-local-hw.md"
M8 = "ArchiveProcessor/segbench-results/ocr-mac-local.md"
def mac_time(s, f):
    return {"per_unit_s": s, "measured": True, "measured_on": "M3 Pro 18 GB, median, one page at a time", "source": src(f, "", "seconds a page median", s)}
def mac_mem(peak, whole, f):
    return {"peak_gb": peak, "whole_process_gb": whole, "measured_on": "M3 Pro 18 GB", "source": src(f, "", "MLX peak memory max / guard peak physical footprint MB", f"{peak} / {whole}")}

# ---- Mac (R1, R2)
add("apple-vision", "Apple Vision (built in, macOS 27.2)", "mac", None, "shipped", {"mac": True, "built_in": True},
    figs("apple-vision", "apple-vision", "apple-vision", ("apple-vision", "Mac")),
    cost("apple-vision"),
    {"per_unit_s": 0.21, "measured": True, "measured_on": "kind classifier's Vision text-lines step; not a like-for-like reading wall (P11-4)", "source": src("ArchiveProcessor/segbench-results/kind-classifier.md", "Vision text lines (accurate) + ink periodicity", "s_page", 0.21)},
    {"peak_gb": None, "measured_on": "runs in the OS", "source": None},
    ["every figure is the macOS 27.2 reading (vision-27-reread.md)", "the 96 were drawn through a 20-word Vision filter: no owner page Vision reads as empty is in them (P8-3, ocr-truth.md)",
     "public: Latin-script pages of the 440 only (L5-L8), 305 of 320 answered; empty on 15 of 80 L7 pages (P8-2)", "on 27.2 a few handwritten pages vary run to run, up to 3.7 NES a page (vision-27-reread.md Noise)"],
    ["non-Latin scripts: not measured (the bench ran Vision on the 320 Latin-script pages of the 440 only); figure absent, not zero"], None)
add("xiaomi-ocr-0-bf16", "Xiaomi-OCR-0 bf16 (Mac)", "mac", None, "measured", {"mac": True},
    figs("xiaomi-ocr-0-bf16", "xiaomi-ocr-0-bf16", "xiaomi-ocr-0-bf16"), cost("xiaomi-ocr-0-bf16"), mac_time(8.8, ML), mac_mem(2.92, 4.46, ML),
    ["public figures are the Sherlock build's (row xiaomi-ocr-0-sherlock); Mac 88.66 against Sherlock 88.67 on the 96 (R-13)", "Markdown output; +2.14 on the 96 if stripped (ocr-scorers.md markup diagnostic)"])
add("paddleocr-vl1.6-bf16", "PaddleOCR-VL 1.6 bf16 (Mac)", "mac", None, "measured", {"mac": True},
    figs("paddleocr-vl1.6-bf16", "paddleocr-vl1.6-bf16", "paddleocr-vl1.6-bf16"), cost("paddleocr-vl1.6-bf16"), mac_time(4.8, ML), mac_mem(2.74, 3.46, ML),
    ["3 of 99 pages hit the 8,192-token cap (ocr-mac-local-hw.md)", "public figures are the Sherlock build's; fails every newspaper (open-sweep-20261019.md)"],
    ["newspapers, ledgers: not without a layout stage (open-sweep: L9 0.0, L4 28.2 for 1.5)"])
add("lightonocr-3-4b-mlx8", "LightOnOCR-3 4B 8-bit (Mac)", "mac", None, "measured", {"mac": True},
    figs("lightonocr-3-4b-mlx8", "lightonocr-3-4b-mlx8", "lightonocr-3-4b-mlx8"), cost("lightonocr-3-4b-mlx8"), mac_time(23.8, ML), mac_mem(6.45, 7.89, ML),
    ["0 of 99 failed on the Mac", "public figures are the FarmShare build's (lightonocr3-4b-farmshare): 89.38 there against 89.15 on the Mac, answered, p081 apart", "Markdown output: +2.86 on the 96 if stripped (ocr-scorers.md markup diagnostic)"])
add("qwen3.5-9b-mlx4", "Qwen3.5 9B 4-bit (Mac)", "mac", None, "measured", {"mac": True},
    figs("qwen3.5-9b-mlx4", "qwen3.5-9b-mlx4", "qwen3.5-9b-mlx4"), cost("qwen3.5-9b-mlx4"), mac_time(37.6, ML), mac_mem(7.48, 9.1, ML),
    ["96 only: no public reading of this build (P5-1)", "1 of 99 failed (format)"])
add("qwen3-vl-8b-mlx4", "Qwen3-VL 8B 4-bit (Mac)", "mac", None, "measured", {"mac": True},
    figs("qwen3-vl-8b-mlx4", "qwen3-vl-8b-mlx4", "qwen3-vl-8b-mlx4"), cost("qwen3-vl-8b-mlx4"), mac_time(40.8, M8), mac_mem(7.64, 8.37, M8),
    ["3 of 99 looped to the cap at 7.3 minutes each; needs the loop stop (ocr-mac-local.md)", "memory pressure 'warn' on 18 GB with the owner's apps open", "deterministic: two readings 15 days apart byte-identical (ocr-rerun-noise.md)"])
add("apple-fm-27", "macOS 27 on-device model", "mac", None, "measured", {"mac": True, "built_in": True},
    figs(None, "apple-fm-27"), cost("apple-fm-27"),
    {"per_unit_s": 9.5, "mean_s": 32.1, "measured": True, "measured_on": "M3 Pro 18 GB, median (mean 32.1)", "source": src("ArchiveProcessor/segbench-results/r1-foundation.md", "", "Speed and tokens, the owner's 96", "9.5 / 32.1")},
    {"peak_gb": None, "measured_on": "runs in the OS", "source": None},
    ["not a reader: 42.4 strict against Vision's 83.1, both 27.2, -40.7 (-49.0 to -32.5); 33 of 96 loop (r1-foundation.md)", "not in the ranking table (no ocr-pages.csv rows)", "its 100 public pages are L5-L8 of the 440, drawn where Vision is cached (P7-6); off the public tables"],
    ["every kind: not offered as a reader"])
add("ppocrv6-kraken-blla", "kraken PP-OCRv6 medium on blla lines (Mac CPU)", "mac", None, "measured", {"mac": True},
    figs(lk="ppocrv6-kraken-blla", ohk="ppocrv6-kraken-blla"), {"usd_1000_list": 0.0, "source": None},
    {"per_unit_s": None, "measured": False, "measured_on": "not tabulated per page", "source": None},
    {"peak_gb": 6.0, "measured_on": "2-6 GB a page call on the CPU (ocr-ppocrv6-hands.md Verdict)", "source": src("ArchiveProcessor/segbench-results/ocr-ppocrv6-hands.md", "ppocrv6-kraken-blla", "Verdict", "2-6 GB")},
    ["no typed or printed page of the 96 read; not on the 96 ranking", "Latin script only; cannot loop (CTC)"],
    ["role: loop fallback and low-memory hands reader, not a default"], None)

# ---- cheap API (R3)
for rid, nm, hid, cid, hk, pk, lk, cav in [
    ("qwen3.6-35b-a3b", "Qwen3.6 35B-A3B (OpenRouter)", "qwen3.6-35b-a3b", "qwen3.6-35b-a3b", "qwen3.6-35b-a3b", None, None, ["public figures are the FarmShare bf16 run, a different build (OCR-9)"]),
    ("qwen3.6-27b", "Qwen3.6 27B (OpenRouter, hosted fp8)", "qwen3.6-27b", "qwen3.6-27b", "qwen3.6-27b", None, None, ["the bench's paired baseline; public figures are the FarmShare run (R-5, R-6)"]),
    ("qwen3-vl-235b", "Qwen3-VL 235B (OpenRouter)", "qwen3-vl-235b", "qwen3-vl-235b", "qwen3-vl-235b", ("qwen3-vl-235b", "reference"), None, ["public: the 440 only; 25 of 40 Hebrew pages loop (C-ocr §5)"]),
    ("qwen3.8-flash", "Qwen3.8 Flash (OpenRouter)", "qwen3.8-flash", "qwen3.8-flash", "qwen3.8-flash", None, None, ["96 only; 3 of 96 refused"]),
    ("gemini3.5-flash-lite", "Gemini 3.5 Flash-Lite", "gemini3.5-flash-lite", "gemini3.5-flash-lite", "gemini3.5-flash-lite", None, None, ["96 only; drafter's family (OCR-1)"]),
    ("gemini3.1-flash-lite", "Gemini 3.1 Flash-Lite", "gemini3.1-flash-lite", "gemini3.1-flash-lite", "gemini3.1-flash-lite", None, None, ["96 only; drafter's family"]),
    ("gpt5.6-luna", "GPT-5.6 Luna (OpenRouter)", "gpt5.6-luna", "gpt5.6-luna", "gpt5.6-luna", None, None, ["96 only"]),
    ("qwen3.5-397b", "Qwen3.5 397B (OpenRouter)", "qwen3.5-397b", "qwen3.5-397b", "qwen3.5-397b", None, None, ["96 only"]),
]:
    keys = ["openrouter"] if not rid.startswith(("gemini", "gpt")) else (["gemini", "openrouter"] if rid.startswith("gemini") else ["openai", "openrouter"])
    add(rid, nm, "cloud", None, "measured", {"key": keys}, figs(hid, cid, hk, pk, lk), cost(rid),
        {"per_unit_s": None, "measured": False, "measured_on": "cloud seconds not tabulated (12-settings-design.md 3.9)", "source": None}, {"peak_gb": 0, "source": None}, cav)

# ---- premium API (R4) and vendors (R6)
add("gemini3.8-flash", "Gemini 3.8 Flash", "cloud", "gemini|gemini-3.8-flash", "shipped", {"key": ["gemini", "openrouter"]},
    figs("gemini3.8-flash", "gemini3.8-flash", "gemini3.8-flash", ("gemini3.8-flash", "reference")), cost("gemini3.8-flash"),
    {"per_unit_s": None, "measured": False, "measured_on": "not tabulated; Gemini 3.7 on the gateway 9.43 s median on the 96", "source": None}, {"peak_gb": 0, "source": None},
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
        {"per_unit_s": None, "measured": False, "measured_on": "not tabulated", "source": None}, {"peak_gb": 0, "source": None}, cav)

# ---- plans (R5)
add("claude-sonnet5.5", "Claude Sonnet 5.5 (your Claude plan)", "plan", None, "measured", {"plan": ["claude"]},
    figs("claude-sonnet5.5", "claude-sonnet5.5", "claude-sonnet5.5"),
    {"usd_1000_list": 0.0, "api_equivalent_usd_1000": 11.5, "plan_share": "five-hour and weekly windows; measured on the user's account (usage.md)", "source": src(PD, "claude-sonnet5.5", "routes.std (estimated API price, data/inputs.json)", 11.5)},
    {"per_unit_s": 10.0, "measured": True, "measured_on": "mean, three at once through claude -p", "source": src("ArchiveProcessor/segbench-results/ocr-panel-cloud.md", "claude-sonnet5.5", "mean s a page", 10)},
    {"peak_gb": 0, "source": None},
    ["Claude Opus 5.5 drafted the truth: same family (OCR-1)", "read through claude -p, whose harness may resize the image (ocr-panel-cloud.md)", "96 only"])

# ---- cluster (R7)
for rid, nm, hid, cid, hk, pk, lk, label, cav in [
    ("qwen3.6-27b-farmshare", "Qwen3.6 27B fp8 (your cluster)", "qwen3.6-27b-farmshare", "qwen3.6-27b-farmshare", None, ("qwen3.6-27b", "FarmShare panel"), "qwen3.6-27b", "qwen3.6-27b-1849739", ["the 96 run (fp8 KV) and the 895 run (BF16 KV) are different runs (R-6)"]),
    ("qwen3.5-27b-farmshare", "Qwen3.5 27B (your cluster)", "qwen3.5-27b-farmshare", "qwen3.5-27b-farmshare", "qwen3.5-27b (FarmShare panel)", ("qwen3.5-27b", "FarmShare panel"), "qwen3.5-27b", "qwen3.5-27b", ["96 and 895 are different runs"]),
    ("qwen3.6-35b-a3b-farmshare", "Qwen3.6 35B-A3B (your cluster)", "qwen3.6-35b-a3b-farmshare", "qwen3.6-35b-a3b-farmshare", None, ("qwen3.6-35b-a3b", "FarmShare panel"), "qwen3.6-35b-a3b", "qwen3.6-35b-a3b-1850004", ["96 fp8 KV against 895 BF16 KV (R-6)"]),
    ("infinity-parser2-pro-sherlock", "Infinity-Parser2-Pro 35B-A3B (your cluster)", "infinity-parser2-pro-sherlock", "infinity-parser2-pro-sherlock", "infinity-parser2-pro", ("infinity-parser2-pro", "Sherlock native"), "infinity-parser2-pro", "infinity-parser2-pro-50536490", ["two GPUs", "the 96 is run infinity-parser2-pro-50536490; the public figures are the 895 run (ocr-scorers.json, Sherlock native), named apart; whether one job or two is not recorded here (R-6) [?]"]),
    ("lightonocr3-4b-farmshare", "LightOnOCR-3 4B (your cluster)", "lightonocr3-4b-farmshare", "lightonocr3-4b-farmshare", "lightonocr3-4b", ("lightonocr3-4b", "FarmShare native"), "lightonocr3-4b", "lightonocr3-4b-1861698", ["Markdown output", "the 96 is run lightonocr3-4b-1861698; the public figures are the 895 run (ocr-scorers.json, FarmShare native), a different run (R-6)"]),
    ("paddleocr-vl1.6-sherlock", "PaddleOCR-VL 1.6 (your cluster)", "paddleocr-vl1.6-sherlock", "paddleocr-vl1.6-sherlock", "paddleocr-vl1.6", ("paddleocr-vl1.6", "Sherlock native"), None, "paddleocr-vl1.6-49202331", ["12,327.9 pages an hour, the most of the 96 cluster runs (panel-data farmshare.truth)", "the 96 is run paddleocr-vl1.6-49202331; the public figures are the 895 run (ocr-scorers.json, Sherlock native), named apart; whether one job or two is not recorded here (R-6) [?]"]),
    ("xiaomi-ocr-0-sherlock", "Xiaomi-OCR-0 (your cluster)", "xiaomi-ocr-0-sherlock", "xiaomi-ocr-0-sherlock", "xiaomi-ocr-0", ("xiaomi-ocr-0", "Sherlock native"), "xiaomi-ocr-0", "xiaomi-ocr-0-49202334", ["Markdown output", "the 96 is run xiaomi-ocr-0-49202334; the public figures are the 895 run (ocr-scorers.json, Sherlock native), named apart; whether one job or two is not recorded here (R-6) [?]"]),
    ("qwen3.5-9b-sherlock", "Qwen3.5 9B (your cluster)", "qwen3.5-9b-sherlock", "qwen3.5-9b-sherlock", None, None, None, "qwen3.5-9b-49202328", ["96 only in the scorer tables"]),
]:
    add(rid, nm, "cluster", None, "measured", {"cluster": True, "gpus": fsrows[label].get("gpus")}, figs(hid, cid, hk, pk, lk), cost(rid, money=False), cluster_time(label),
        {"peak_gb": None, "measured_on": "GPU memory not tabulated", "source": None}, cav)
for rid, nm in [("german-handwriting", "kraken German handwriting model"), ("tridis", "kraken TRIDIS"), ("catmus-medieval", "kraken CATMuS Medieval"), ("greek-minuscule", "kraken Greek minuscule"), ("biblia", "kraken BiblIA")]:
    add(f"kraken-{rid}", f"{nm} (script specialist, kraken)", "mac", None, "measured", {"mac": True},
        figs(pk=(rid, "kraken specialist")), {"usd_1000_list": 0.0, "source": None}, {"per_unit_s": None, "measured": False, "source": None}, {"peak_gb": None, "source": None},
        ["only the strata it was built for; known source overlap with its training data (specialists.md)", "no reading of the 96"], ["its own script stratum only"])

print("[")
print(",\n".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in rows))
print("]")
