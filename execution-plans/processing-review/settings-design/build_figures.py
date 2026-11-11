#!/usr/bin/env python3
"""Build figures.json for the settings-design prototype from the rule table.

Reads ArchiveProcessor/segbench-results/settings-routes.json (W46.settings-routes-table; built from the bench's result
files and the stage notes by ArchiveProcessor/scripts/segbench/settings_routes.py, every figure with its source) and
flattens its rows into the shape prototype.template.html draws. It enters no figure of its own: the hand-entered tables
this script held until 2026-11-11 are gone, and so are their defects (the cascade cost divided by 96, overall figures
joined across runs, counts in `unflagged_per_500`, GLM's batch price, the 2B's footprint as its peak, Gemini under an
OpenRouter key for segmentation, the marks text). The one assumption left is the prototype's own: a cloud route with no
measured seconds is drawn at CLOUD_S, marked est.

Usage: build_figures.py <repo root> <out.json>; then inject.py puts the JSON into prototype.html.
"""
import json, sys, datetime
root, out = sys.argv[1], sys.argv[2]
T = json.load(open(f"{root}/ArchiveProcessor/segbench-results/settings-routes.json"))
S = {s["id"]: s for s in T["stages"]}
CLOUD_S = 6.0  # the prototype's assumption for a cloud call with no measured time (12-settings-design.md 3.9)


def val(f, k):
    x = f.get(k)
    v = x.get("value") if isinstance(x, dict) else x
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def needs(r):
    """The prototype's needs: any one key, every plan, a cluster, a memory floor for Mac routes."""
    n = r["needs"]
    o = {}
    if n["key"]:
        o["key"] = n["key"]
    if n["plan"]:
        o["plan"] = n["plan"]
    if n["cluster"]:
        o["cluster"] = True
    if r["family"] == "mac":
        o["mac_gb"] = n["mac_gb"] or 0
    return o


def seconds(r):
    t = r.get("time") or {}
    if t.get("per_unit_s") is not None:
        return t["per_unit_s"], not t.get("measured", False)
    if t.get("per_unit_ms") is not None:
        return t["per_unit_ms"] / 1000, not t.get("measured", False)
    if t.get("pages_per_hour_per_gpu_set"):
        return round(3600 / t["pages_per_hour_per_gpu_set"], 2), False
    return (CLOUD_S, True) if r["family"] in ("cloud", "plan") else (None, True)


def cost(r):
    c = r.get("cost") or {}
    return (c.get("usd_1000_list") or 0.0), c.get("usd_1000_batch")


def common(r, unit_key):
    s, est = seconds(r)
    usd, batch = cost(r)
    return {"id": r["id"], "name": r["name"], "family": r["family"], "needs": needs(r), "usd_1000": usd, "usd_1000_batch": batch,
            unit_key: s, "s_est": est, "peak_gb": (r.get("memory") or {}).get("peak_gb") or 0, "note": "; ".join(r["caveats"][:2]),
            "source": f"settings-routes.json, stage {r['_stage']}, row {r['id']}"}


def routes(sid):
    for r in S[sid]["routes"]:
        yield dict(r, _stage=sid)


# ---- reading: the routes read on the owner's 96 (per kind strict, failure as 0)
ocr_rows = []
for r in routes("reading"):
    f = r["figures"]
    if "kinds" not in f or r["id"].startswith("casc-"):
        continue
    k = f["kinds"]
    nes = {kk: k[kk][0] for kk in ("typewritten", "printed", "handwritten") if kk in k}
    n = {kk: [k[kk][1], k[kk][2]] for kk in nes}
    o = f.get("overall")
    if o:
        nes["overall"] = o["strict"]
        a, p = o["n"].split(" ")[0].split("/")
        n["overall"] = [int(a), int(p)]
    pub = (f.get("public") or {}).get("all")
    ocr_rows.append({**common(r, "s_page"), "nes": nes, "n": n, "hands16": val(f, "hands16"),
                     "public895": pub[0] if pub else None, "public_n": [int(x) for x in pub[2].split("/")] if pub else None})

# ---- segmentation: the routes scored on the two locked test boxes, with their checking figures
seg_rows = []
for r in routes("segmentation"):
    f = r["figures"]
    if r["family"] != "manual" and None in (val(f, "test-boxes"), val(f, "test-boxes.checks_per_100"), val(f, "test-boxes.after_checking")):
        continue
    seg_rows.append({**common(r, "s_page"), "nocheck": val(f, "test-boxes"), "checks_per_100": val(f, "test-boxes.checks_per_100"),
                     "after": val(f, "test-boxes.after_checking"), "unflagged_per_500": val(f, "test-boxes.unflagged_per_500")})

# ---- dating: one point per step row, in the template's year keys
date_rows = []
for r in routes("dating"):
    f = r["figures"]
    year = {}
    if val(f, "in_text") is not None:
        year["in text"] = val(f, "in_text")
    nit = val(f, "not_in_text") if val(f, "not_in_text") is not None else val(f, "unprinted_122_doc_year")
    if nit is not None:
        year["not in text"] = nit
    if r["id"] == "none":
        year = {"all": 0}
    if not year:
        continue
    du = val(f, "du_uncertain_unflagged")
    date_rows.append({**common(r, "s_doc"), "year": year, "pool_weighted": val(f, "all_pool_weighted"),
                      "uncertain_marked": round(100 - du, 1) if du is not None else None,
                      "false_year_undated": val(f, "undated_false_year"), "image_pass_finds": val(f, "unprinted_122_on_page")})

# ---- entities: ed2 F1, sender / recipient / sending place
ent_rows = []
for r in routes("entities"):
    f = r["figures"]
    n = next((x.get("n") for x in f.values() if isinstance(x, dict) and x.get("n")), 0)
    ent_rows.append({**common(r, "s_doc"), "f1": {"sender": val(f, "sender") or 0, "recipient": val(f, "recipient") or 0, "place": val(f, "sending_place") or 0}, "n": n})

# ---- cascades (the reading stage's casc- rows: split-half NES, difficulty.md's $ / 1,000)
casc = [{"id": r["id"], "label": r["name"], "stages": r.get("stages"), "trigger": r.get("trigger"), "nes": r["figures"]["overall"]["value"],
         "usd_1000": cost(r)[0], "escalated_of_96": r["figures"]["overall"].get("escalated")} for r in routes("reading") if r["id"].startswith("casc-")]


# ---- the no-choice stages' rules, as the rules tab shows them
def rules(*sids):
    rs = [x for sid in sids for x in S[sid]["rules"]]
    return {"rule": " ".join(x["text"] for x in rs), "source": "; ".join(dict.fromkeys(x["source"] for x in rs))}


fixed = {"kinds": rules("kinds"), "placement": rules("placement"), "enhancement": rules("ocr-input", "reading-copy"),
         "layout": rules("layout"), "marks": rules("marks")}

figures = {
 "built": datetime.date.today().isoformat(), "table_built": T["built"],
 "noise": {"ocr_tie": T["noise"]["reading"]["tie"], "seg_rerun_pages_exact_points": T["noise"]["segmentation"]["tie"],
           "truth_note": "The 96's truth was drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner; close rows among those families are provisional. Ties: " + T["noise"]["reading"]["tie"] + " (" + T["noise"]["reading"]["source"] + ")."},
 "ocr": ocr_rows, "seg": seg_rows, "date": date_rows, "ent": ent_rows, "cascades": casc, "fixed": fixed,
}
json.dump(figures, open(out, "w"), indent=1, ensure_ascii=False)
print("wrote", out, "ocr", len(ocr_rows), "seg", len(seg_rows), "date", len(date_rows), "ent", len(ent_rows), "cascades", len(casc))
