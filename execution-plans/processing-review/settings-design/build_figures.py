#!/usr/bin/env python3
"""Build figures.json for the settings-design prototype from the bench's own data.

Reads ArchiveOCRBench/data/panel-data.json (the bench page's consolidated figures) and adds the
facts the bench keeps in prose: seconds a page and peak memory on the Mac (ocr-mac-local*.md),
cluster throughput (farmshare rows), what each route needs (a key, a plan, a cluster, memory),
and the segmentation routes' timing. Every hand-entered figure names its source file.

Usage: build_figures.py <repo root> <out.json>; then inject.py puts the JSON into prototype.html.
"""
import json, sys, datetime
root, out = sys.argv[1], sys.argv[2]
d = json.load(open(f"{root}/ArchiveOCRBench/data/panel-data.json"))
charts = {c["key"]: c["scores"] for c in d["charts"]}          # route -> [nes, ok, n] per kind
routes = {r["id"]: r for r in d["routes"]}                       # std/batch = $ per 1,000 pages
owner96 = {r["route"]: r for r in d["ocr_scorers"]["owner96"]}
public = {r["route"]: r for r in d["ocr_scorers"]["public895"]}
hands = {r["route"]: r for r in d["ocr_scorers"]["hands_rescore"]["routes"]}
fs = {r["label"].rsplit("-", 1)[0] if r["label"][-1].isdigit() else r["label"]: r for r in d["farmshare"]["truth"]}

def kinds(rid):
    return {k: {"nes": charts[k][rid][0], "ok": charts[k][rid][1], "n": charts[k][rid][2]}
            for k in ("overall", "typewritten", "printed", "handwritten") if rid in charts[k]}

# ---- OCR routes. needs: any one of the listed credentials, plus a memory floor for Mac routes.
# s_page: Mac figures are medians from ocr-mac-local.md / ocr-mac-local-hw.md (M3 Pro, 18 GB);
# cluster figures are pages an hour per GPU from the FarmShare/Sherlock truth runs (farmshare rows);
# cloud figures are not tabulated by the bench and are marked est (gateway OCR calls ran at
# 5.3 s median in date-image.md; Claude through claude -p at 10 s a page, three at once, ocr-panel-cloud.md).
CLOUD_S = 6.0
OCR = [
 # id, name, family, needs, s_page, est, peak_gb, note
 ("apple-vision", "Apple Vision (built in)", "mac", {"mac_gb": 0}, 1.0, True, 0.3, "macOS 27.2 reading; free; reads nothing on 15 of 80 charter pages (L7)"),
 ("paddleocr-vl1.6-bf16", "PaddleOCR-VL 1.6 (Mac)", "mac", {"mac_gb": 8}, 4.8, False, 2.6, "3 of 99 pages looped to the cap"),
 ("xiaomi-ocr-0-bf16", "Xiaomi-OCR-0 (Mac)", "mac", {"mac_gb": 8}, 8.8, False, 2.9, ""),
 ("lightonocr-3-4b-mlx8", "LightOnOCR-3 4B 8-bit (Mac)", "mac", {"mac_gb": 16}, 23.8, False, 6.4, "the lab's handwriting pick; no page failed"),
 ("qwen3.5-9b-mlx4", "Qwen3.5 9B 4-bit (Mac)", "mac", {"mac_gb": 16}, 37.6, False, 7.5, "9.1 GB whole-process footprint"),
 ("qwen3-vl-8b-mlx4", "Qwen3-VL 8B 4-bit (Mac)", "mac", {"mac_gb": 16}, 40.8, False, 7.6, "3 of 99 pages looped, 7 minutes each; needs a loop stop"),
 ("apple-fm-27", "macOS 27 on-device model", "mac", {"mac_gb": 0}, 9.5, False, 1.0, "not a reader: a third of pages loop; shown for completeness"),
 ("gemini3.8-flash", "Gemini 3.8 Flash", "cloud", {"key": ["gemini", "openrouter"]}, CLOUD_S, True, 0, "the app's default; 2 of 96 refused; price doubles 1 Jan 2027"),
 ("gemini3.1-pro", "Gemini 3.1 Pro", "cloud", {"key": ["gemini", "openrouter"]}, CLOUD_S, True, 0, "2 refusals"),
 ("gemini3.5-flash", "Gemini 3.5 Flash", "cloud", {"key": ["gemini", "openrouter"]}, CLOUD_S, True, 0, ""),
 ("gemini3.5-flash-lite", "Gemini 3.5 Flash-Lite", "cloud", {"key": ["gemini", "openrouter"]}, CLOUD_S, True, 0, ""),
 ("gemini3.1-flash-lite", "Gemini 3.1 Flash-Lite", "cloud", {"key": ["gemini", "openrouter"]}, CLOUD_S, True, 0, ""),
 ("qwen3.5-397b", "Qwen3.5 397B (OpenRouter)", "cloud", {"key": ["openrouter"]}, CLOUD_S, True, 0, "open weights, hosted"),
 ("qwen3-vl-235b", "Qwen3-VL 235B (OpenRouter)", "cloud", {"key": ["openrouter"]}, CLOUD_S, True, 0, "open weights, hosted"),
 ("qwen3.6-27b", "Qwen3.6 27B (OpenRouter)", "cloud", {"key": ["openrouter"]}, CLOUD_S, True, 0, "open weights, hosted fp8; the same model runs on a cluster"),
 ("qwen3.6-35b-a3b", "Qwen3.6 35B-A3B (OpenRouter)", "cloud", {"key": ["openrouter"]}, CLOUD_S, True, 0, "open weights, hosted"),
 ("qwen3.8-flash", "Qwen3.8 Flash (OpenRouter)", "cloud", {"key": ["openrouter"]}, CLOUD_S, True, 0, "3 of 96 failed"),
 ("gpt5.4-mini", "GPT-5.4 Mini", "cloud", {"key": ["openai", "openrouter"]}, CLOUD_S, True, 0, ""),
 ("gpt5.6-luna", "GPT-5.6 Luna", "cloud", {"key": ["openai", "openrouter"]}, CLOUD_S, True, 0, ""),
 ("mistral-large4", "Mistral Large 4", "cloud", {"key": ["mistral", "openrouter"]}, CLOUD_S, True, 0, ""),
 ("mistral-ocr-4-1", "Mistral OCR 4.1", "cloud", {"key": ["mistral"]}, CLOUD_S, True, 0, "text only, no kind label; $4 per 1,000 pages flat"),
 ("claude-sonnet5.5", "Claude Sonnet 5.5 (your Claude plan)", "plan", {"plan": ["claude"]}, 10.0, False, 0, "no money; draws on the plan's five-hour and weekly windows; the truth leans toward this family"),
 ("qwen3.6-27b-farmshare", "Qwen3.6 27B (your cluster)", "cluster", {"cluster": True}, None, False, 0, "one L40S; fp8 KV cache"),
 ("qwen3.5-27b-farmshare", "Qwen3.5 27B (your cluster)", "cluster", {"cluster": True}, None, False, 0, "one L40S"),
 ("qwen3.6-35b-a3b-farmshare", "Qwen3.6 35B-A3B (your cluster)", "cluster", {"cluster": True}, None, False, 0, "one L40S; the fast cluster route"),
 ("qwen3.5-9b-sherlock", "Qwen3.5 9B (your cluster)", "cluster", {"cluster": True}, None, False, 0, ""),
 ("lightonocr3-4b-farmshare", "LightOnOCR-3 4B (your cluster)", "cluster", {"cluster": True}, None, False, 0, ""),
 ("paddleocr-vl1.6-sherlock", "PaddleOCR-VL 1.6 (your cluster)", "cluster", {"cluster": True}, None, False, 0, "12,000 pages an hour a GPU"),
]
FS_LABEL = {"qwen3.6-27b-farmshare": "qwen3.6-27b-1849739", "qwen3.5-27b-farmshare": "qwen3.5-27b",
            "qwen3.6-35b-a3b-farmshare": "qwen3.6-35b-a3b-1850004", "qwen3.5-9b-sherlock": "qwen3.5-9b-49202328",
            "lightonocr3-4b-farmshare": "lightonocr3-4b-1861698", "paddleocr-vl1.6-sherlock": "paddleocr-vl1.6-49202331"}
fsrows = {r["label"]: r for r in d["farmshare"]["truth"]}
PUBLIC_KEY = {"qwen3.6-27b-farmshare": "qwen3.6-27b", "qwen3.5-27b-farmshare": "qwen3.5-27b", "qwen3.6-35b-a3b-farmshare": "qwen3.6-35b-a3b",
              "lightonocr3-4b-farmshare": "lightonocr3-4b", "paddleocr-vl1.6-sherlock": "paddleocr-vl1.6", "qwen3-vl-8b-mlx4": None,
              "lightonocr-3-4b-mlx8": None, "qwen3.5-9b-mlx4": None, "xiaomi-ocr-0-bf16": "xiaomi-ocr-0", "paddleocr-vl1.6-bf16": "paddleocr-vl1.6"}
HANDS_KEY = {"mistral-ocr-4-1": "mistral-ocr"}
ocr_rows = []
for rid, name, fam, needs, s_page, est, gb, note in OCR:
    r = routes[rid]
    k = kinds(rid)
    if fam == "cluster":
        fr = fsrows[FS_LABEL[rid]]
        per_hour = fr["per_hour"]; s_page = 3600 / per_hour
        k = {"overall": {"nes": fr["nes"], "ok": fr["ok"], "n": fr["n"]}, **{kk: vv for kk, vv in k.items() if kk != "overall"}}
    pk = PUBLIC_KEY.get(rid, rid)
    pub = public.get(pk) if pk else None
    h = hands.get(HANDS_KEY.get(rid, rid.replace("-farmshare", "").replace("-sherlock", "")))
    ocr_rows.append({
        "id": rid, "name": name, "family": fam, "needs": needs,
        "nes": {kk: round(vv["nes"], 2) for kk, vv in k.items()},
        "n": {kk: [vv["ok"], vv["n"]] for kk, vv in k.items()},
        "hands16": round(h["after"], 2) if h else None,
        "public895": round(pub["nes"] * 100, 1) if pub else None,
        "public_n": [pub["ok"], pub["n"]] if pub else None,
        "usd_1000": r["std"], "usd_1000_batch": r["batch"],
        "s_page": round(s_page, 1) if s_page is not None else None, "s_est": est, "peak_gb": gb, "note": note,
        "source": "ocr-panel-cloud.md / ocr-panel-local.md / ocr-mac-local-hw.md / farmshare/truth96-20261020.md; per-kind rows from the bench's panel-data.json charts",
    })

# ---- Segmentation (test boxes Stanton + RG 165, 363 pages; options.md, cheap-models.md, seg-students.md)
SEG_META = {
 "Full manual": ("manual", {}, 0, False, "every gap is a check"),
 "Claude only": ("plan", {"plan": ["claude"]}, 1.5, False, "25 min per 1,000 pages at three calls at once (usage.md); about 5% of a five-hour window per 100 pages on the owner's plan"),
 "Gemini only": ("cloud", {"key": ["gemini", "openrouter"]}, 5.3, True, "16 s a seven-page window at stride 3 (seg-boxes-score.md)"),
 "ChatGPT only": ("plan", {"plan": ["chatgpt"]}, 5.0, True, "Sign in with ChatGPT; no meter the app can read"),
 "Claude and ChatGPT together": ("plan", {"plan": ["claude", "chatgpt"]}, 5.0, True, ""),
 "GLM-5.3 Flash only (budget)": ("cloud", {"key": ["openrouter"]}, 5.0, True, ""),
 "GPT-5.6 Luna": ("cloud", {"key": ["openai", "openrouter"]}, 5.0, True, ""),
 "Qwen3.5 Flash": ("cloud", {"key": ["openrouter"]}, 5.0, True, "5 of 259 windows failed to parse"),
 "Corpus-trained Qwen3.5 2B on this Mac (no key) (scored at full precision on FarmShare)": ("mac", {"mac_gb": 16}, 6.0, False, "about 6 s a page, 6.8 GB footprint (seg-students.md, local-seg-proof-runtime.json); the shipped build"),
 "Qwen3.5 27B on FarmShare (the corpus teacher)": ("cluster", {"cluster": True}, None, False, "not fine-tuned; the 2B beats it on letters"),
 "Qwen3.5 4B, fine-tuned (trained on the corpus; FarmShare figures)": ("cluster", {"cluster": True}, None, False, ""),
}
SEG_NAME = {"Corpus-trained Qwen3.5 2B on this Mac (no key) (scored at full precision on FarmShare)": "Trained Qwen3.5 2B (Mac, no key)",
            "Qwen3.5 27B on FarmShare (the corpus teacher)": "Qwen3.5 27B (your cluster)",
            "Qwen3.5 4B, fine-tuned (trained on the corpus; FarmShare figures)": "Trained Qwen3.5 4B (your cluster)",
            "GLM-5.3 Flash only (budget)": "GLM-5.3 Flash (OpenRouter)", "Claude only": "Claude Sonnet 5.5 (your Claude plan)",
            "Gemini only": "Gemini 3.8 Flash", "ChatGPT only": "ChatGPT (your plan)", "Claude and ChatGPT together": "Claude and ChatGPT together (both plans)",
            "GPT-5.6 Luna": "GPT-5.6 Luna", "Qwen3.5 Flash": "Qwen3.5 Flash (OpenRouter)", "Full manual": "No model: check every gap by hand"}
seg_rows = []
for s in d["segmentation"]:
    if s["name"] not in SEG_META: continue
    fam, needs, s_page, est, note = SEG_META[s["name"]]
    seg_rows.append({"id": s["name"], "name": SEG_NAME[s["name"]], "family": fam, "needs": needs,
        "nocheck": s["nocheck"], "checks_per_100": s["checks"], "after": s["after"], "unflagged_per_500": s["unflagged"],
        "usd_1000": s["std"] if fam not in ("mac", "cluster", "manual") else 0.0, "usd_1000_batch": s["batch"] if fam == "cloud" else None,
        "s_page": s_page, "s_est": est, "peak_gb": 6.8 if fam == "mac" else 0, "note": note, "source": s["source"]})
# the three locked boxes, by kind of material (seg-boxes-score.md): gap accuracy
boxes = d["seg_boxes_score"]["boxes"]; labels = d["seg_boxes_score"]["labels"]
BOX_KIND = {"Sasha": "letters, typed and handwritten (held out from every student)", "IllustratedReview": "a magazine: articles within issues", "SC0122": "typed office files"}
seg_boxes = {}
for row in boxes:
    if row["route"] not in ("gemini", "mac-2b", "teacher"): continue
    seg_boxes.setdefault(labels[row["route"]], {})[row["box"]] = {"kind": BOX_KIND.get(row["box"], ""), "gap_acc": round(100 * row["gap accuracy"], 1), "pages_exact": round(100 * row["pages exact"], 1), "split": row["split"]}

# ---- Dating (owner corpus, 250 documents with a year tag; date-tagging.md, date-model.md, date-image.md, date-undated.md)
dt = d["dating"]; dm = d["seg_date"]["dating_mac"]["owner"]
def yr(y):
    return {k: round(100 * v["exact"][0] / v["exact"][1], 1) for k, v in y.items() if v["exact"][1]}
date_rows = [
 {"id": "gemini-oneshot", "name": "Gemini 3.8 Flash, the app's one-shot tagging call", "family": "cloud", "needs": {"key": ["gemini", "openrouter"]},
  "year": yr(dt["year"]), "pool_weighted": dt["pool_weighted"]["exact"], "uncertain_marked": round(100 * dt["uncertain"]["owner_uncertain"][0] / dt["uncertain"]["owner_uncertain"][1]),
  "false_year_undated": 6.7, "usd_1000": dt["usd_per_1000"], "s_doc": 3.0, "s_est": True, "note": "text and three neighbouring segments; false year on undated documents 6.7% owner-ruled (13% model-scored)", "source": "date-tagging.md, date-undated.md"},
 {"id": "gemini-oneshot-image", "name": "Gemini one-shot plus an image pass on the unprinted ones", "family": "cloud", "needs": {"key": ["gemini", "openrouter"]},
  "year": {**yr(dt["year"]), "not in text": 63.4}, "pool_weighted": dt["pool_weighted"]["exact"], "uncertain_marked": 88, "false_year_undated": 6.7,
  "usd_1000": round(dt["usd_per_1000"] + 2.8, 2), "s_doc": 8.0, "s_est": True, "image_pass_finds": 46, "note": "the image pass finds the date on the page for 46% of documents whose year is not in the text (Gemini 3.7, 122 documents); traceable: the quote and its place", "source": "date-image.md"},
 {"id": "mac-2b", "name": "Trained Qwen3.5 2B 8-bit (Mac, no key)", "family": "mac", "needs": {"mac_gb": 8}, "peak_gb": 2.7,
  "year": yr(dm["year"]), "pool_weighted": None, "uncertain_marked": 0, "false_year_undated": None, "usd_1000": 0.0, "s_doc": 1.4, "s_est": False,
  "note": "never marks Date Uncertain; 41% where the year is not in the text; not recommended as the default tagger", "source": "date-model.md"},
 {"id": "cluster-27b-image", "name": "Qwen3.6 27B image pass (your cluster)", "family": "cluster", "needs": {"cluster": True},
  "year": {"not in text": 39.0}, "pool_weighted": None, "uncertain_marked": None, "false_year_undated": None, "usd_1000": 0.0, "s_doc": 17.5, "s_est": False, "image_pass_finds": 43,
  "note": "finds the page date for 43% of unprinted-year documents; the app's text one-shot prompt looped on this model (300 of 300 unparsed)", "source": "date-image.md, dating open_models"},
 {"id": "mac-8b-image", "name": "Qwen3-VL 8B image pass (Mac)", "family": "mac", "needs": {"mac_gb": 16}, "peak_gb": 7.6,
  "year": {"not in text": 16.0}, "pool_weighted": None, "uncertain_marked": None, "false_year_undated": None, "usd_1000": 0.0, "s_doc": 12.0, "s_est": False, "image_pass_finds": 32,
  "note": "finds the page date for 32% of unprinted-year documents", "source": "date-image.md"},
 {"id": "none", "name": "No dating", "family": "manual", "needs": {}, "year": {"all": 0}, "pool_weighted": 0, "usd_1000": 0.0, "s_doc": 0, "s_est": False, "note": "", "source": ""},
]

# ---- Entities (138 correspondence documents, edit-distance-2 F1; ent-score.md, ent-score-paid.md)
ent_rows = [
 {"id": "gemini-tagging", "name": "Gemini, inside the tagging call", "family": "cloud", "needs": {"key": ["gemini", "openrouter"]}, "f1": {"sender": 0.706, "recipient": 0.717, "place": 0.617}, "n": 138, "usd_1000": 0.0, "s_doc": 0, "s_est": True, "note": "no extra call; the first 3,000 characters only", "source": "ent-score-paid.md (tagging arm)"},
 {"id": "gemini-entity8k", "name": "Gemini, a dedicated entity prompt (8k)", "family": "cloud", "needs": {"key": ["gemini", "openrouter"]}, "f1": {"sender": 0.759, "recipient": 0.876, "place": 0.843}, "n": 138, "usd_1000": 3.0, "s_doc": 3.0, "s_est": True, "note": "one more text call per document; cost estimated from the tagging call's size", "source": "ent-score-paid.md"},
 {"id": "qwen27b", "name": "Qwen3.6 27B (your cluster or OpenRouter)", "family": "cluster", "needs": {"cluster": True, "key": ["openrouter"]}, "f1": {"sender": 0.603, "recipient": 0.590, "place": 0.489}, "n": 82, "usd_1000": 1.4, "s_doc": 5.0, "s_est": True, "note": "", "source": "ent-score.md"},
 {"id": "qwen8b-mac", "name": "Qwen3-VL 8B (Mac)", "family": "mac", "needs": {"mac_gb": 16}, "peak_gb": 7.6, "f1": {"sender": 0.562, "recipient": 0.552, "place": 0.444}, "n": 82, "usd_1000": 0.0, "s_doc": 8.0, "s_est": True, "note": "", "source": "ent-score.md"},
 {"id": "qwen4b-mac", "name": "Qwen3.5 4B (Mac)", "family": "mac", "needs": {"mac_gb": 8}, "peak_gb": 4.9, "f1": {"sender": 0.496, "recipient": 0.420, "place": 0.311}, "n": 82, "usd_1000": 0.0, "s_doc": 4.0, "s_est": True, "note": "", "source": "ent-score.md"},
 {"id": "nltagger", "name": "Apple NLTagger (built in)", "family": "mac", "needs": {"mac_gb": 0}, "peak_gb": 0, "f1": {"sender": 0.045, "recipient": 0.124, "place": 0.022}, "n": 82, "usd_1000": 0.0, "s_doc": 0.1, "s_est": False, "note": "cannot replace the LLM", "source": "ent-score.md"},
 {"id": "none", "name": "No entities", "family": "manual", "needs": {}, "f1": {"sender": 0, "recipient": 0, "place": 0}, "n": 0, "usd_1000": 0.0, "s_doc": 0, "s_est": False, "note": "", "source": ""},
]

# ---- Cascades (R8): first reader checked against a second, escalate on disagreement; difficulty.cascades.frontier
casc = [{"label": c["label"], "stages": c["stages"], "trigger": c["trigger"], "nes": c["nes"], "usd_1000": round(c["usd"] / 96 * 1000, 2), "escalated_of_96": c["escalated"]} for c in d["difficulty"]["cascades"]["frontier"]]

# ---- fixed rules (no trade-off to show; the measured reason)
fixed = {
 "kinds": {"rule": "The app measures the collection's mix itself: Vision signals and a feature print, 139 of 144 pages right, 0.2 s a page, free.", "source": "kind-classifier.md", "speed": d["kind_classifier"]["speed"]},
 "placement": {"rule": "Print: Apple Vision's own layer (free). Handwriting: kraken line detection with the reading aligned to the lines, about 6 s a page on the CPU; a page whose alignment confidence is under 0.67 falls back to a text page.", "source": "place-print.md, place-hands.md"},
 "enhancement": {"rule": "No content-removing enhancement helps any reader as OCR input, and DocRes dewarp harms every one; so there is no OCR-input enhancement to choose. The reading copy's deskew or dewarp is a user switch, content-preserving methods only (owner, 2026-10-20).", "source": "enh-ocr-input.md, enh-dewarp.md"},
 "layout": {"rule": "Newspapers get a layout stage (PP-DocLayoutV3 regions); every other kind reads the whole page; a layout detector never runs on handwriting or registers (it drops them).", "source": "layout-photo.md"},
 "marks": {"rule": "No detector found a mark (0 of 45 boxes). Nothing to offer yet; marks are preserved on the reading copy by the enhancement rule.", "source": "marks-detect.md"},
}

figures = {
 "built": datetime.date.today().isoformat(),
 "noise": {"ocr_tie_points": 0.5, "seg_rerun_pages_exact_points": "1.4 to 3.2 a box", "truth_note": "The 96's truth was drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner; close rows among those families are provisional. Differences under half a point of NES are ties (ocr-rerun-noise.md)."},
 "ocr": ocr_rows, "seg": seg_rows, "seg_boxes": seg_boxes, "date": date_rows, "ent": ent_rows, "cascades": casc, "fixed": fixed,
}
json.dump(figures, open(out, "w"), indent=1, ensure_ascii=False)
print("wrote", out, "ocr", len(ocr_rows), "seg", len(seg_rows), "date", len(date_rows), "ent", len(ent_rows), "cascades", len(casc))
