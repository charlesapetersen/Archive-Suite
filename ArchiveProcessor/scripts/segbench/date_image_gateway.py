#!/usr/bin/env python3
"""W46.date-image-paid: Gemini 3.7 Flash through the Stanford AI API gateway on W46.date-image's requests, and the
typeface probe (B test 9).

    python3 date_image_gateway.py run [--limit N]     # the images-alone requests -> PACK/gateway/<LABEL>/, cached
    python3 date_image.py score                       # the gateway arm joins the 27B and the 8B in date-image.md
    python3 date_image_gateway.py typeface            # a dozen crops asked for the typeface -> date-image-typeface.md

The arm: the 122 documents of W46.date-image's pack, the images alone (no ABBYY text variant, owner 2026-10-30), the
same prompt and the same 2,400 px JPEG originals the 27B read, temperature 0, reasoning low. Gemini 3.7, not the 3.8
the item named, because the gateway serves no 3.8 (gateway_gemini's report says how far apart they read).

The probe: twelve documents the 27B found no date on (so the letterforms would be the only cue), six crops of the top
of page 1 (letterhead) and six of the body (typewriting), each asked for the typeface or machine, the features it rests
on and the years it allows. "Checkable" means a named typeface or machine with features and an earliest year; it is
scored against the owner's year (the earliest year must not pass it). The crops are cut by position, not chosen by
reading them; the reply says what the crop shows, so a crop that missed is counted, not hidden.

The gateway is real money on a Stanford PTA (root CLAUDE.md). Spend is counted from the gateway's token usage at
Gemini 3.8 Flash's list price taken as a ceiling (gateway_gemini.PRICE) into PACK/gateway/calls.jsonl, written before
a reply is used; CAP bounds the item. The key is read by gateway_gemini.api_key, never printed or written. Replies and
crops stay in the private bench cache. Run from scripts/segbench.
"""
from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import io
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import date_image as DI
import gateway_gemini as G

LABEL = "gemini3.7-flash-gw-2400"
OUT = DI.PACK / "gateway"
CAP = 1.80            # the item's total: the arm about $1, the probe under $0.20; under the $7 rule
MAX_TOKENS = 4096     # 3.7 reasons first; the cluster's 700 would cut it off
WORST = (6000 * G.PRICE[0] + MAX_TOKENS * G.PRICE[1]) / 1e6
TYPEFACE_RESULTS = DI.RESULTS[:-3] + "-typeface.md"


def ledger():
    p = OUT / "calls.jsonl"
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


def spent():
    return sum(r.get("cost", 0) for r in ledger())


def body(images, prompt):
    content = [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(b).decode()}}
               for b in images]
    return {"model": G.MODEL, "temperature": 0, "max_tokens": MAX_TOKENS, "reasoning_effort": "low",
            "messages": [{"role": "user", "content": content + [{"type": "text", "text": prompt}]}]}


def call(key, images, prompt, dest: Path):
    """One reply, cached by destination; the ledger line is written before the reply is used."""
    if dest.exists():
        return json.loads(dest.read_text())
    if spent() + WORST > CAP:
        raise SystemExit(f"cap: ${spent():.4f} spent of ${CAP}")
    b = body(images, prompt)
    t = time.time()
    for attempt in range(3):
        r = G.request("/chat/completions", b)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    rec = {"id": key, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3), "model": got.get("model"),
           "usage": usage, "cost": round(G.cost(usage), 6),
           "request_sha256": hashlib.sha256(json.dumps(b, sort_keys=True).encode()).hexdigest()}
    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / "calls.jsonl").open("a") as fh:
        fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    text = (choice.get("message") or {}).get("content") if r.status_code == 200 else None
    out = {"id": key, "text": text, "finish": choice.get("finish_reason"), "seconds": rec["wall_s"],
           "tokens": [usage.get("prompt_tokens"), usage.get("completion_tokens")], "model": G.MODEL}
    if r.status_code == 200 and text:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        print(key, r.status_code, out["finish"], json.dumps(got)[:300], flush=True)
    return out


def cmd_run(a):
    same, n = DI.check_pack(DI.PACK, DI.CLUSTER)
    if same != n:
        raise SystemExit(f"the local pack differs from the cluster's: {same} of {n} requests match")
    reqs = [r for r in DI.load_requests(DI.PACK) if r["variant"] == "image"]
    reqs.sort(key=lambda r: (r["cls"] != "D", r["doc"]))
    dest = OUT / LABEL
    jobs = [(r["id"], [(DI.PACK / "images" / os.path.basename(p)).read_bytes() for p in r["images"]], r["prompt"],
             dest / (r["id"] + ".json")) for r in reqs][: a.limit or None]
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda j: call(*j), jobs))
    bad = [r["id"] for r in res if DI.reply(r.get("text")) is None]
    print(f"{len(res) - len(bad)}/{len(res)} parsed, ${spent():.4f} spent in all; unparsed: {bad[:20]}")


# ------------------------------------------------------------------------------------------------- typeface probe

PROBE_N = 12
CROPS = {"letterhead": (0.0, 0.22), "body": (0.35, 0.60)}      # fractions of the page height, full width
TYPEFACE_PROMPT = (
    "This is a crop of a page from a 20th-century archival document ({where}). Judge only the letterforms and the "
    "design, not any date or name written in it. If it shows typewritten text, name the typeface (for example Pica, "
    "Elite, Courier, Prestige Elite, Letter Gothic, Orator) and, if you can, the typewriter make, model or family "
    "(for example IBM Selectric, Remington, Underwood, Olympia), with the visible features you rely on. If it shows "
    "a printed letterhead, name the typeface or style and say what in its design places it in time. Then give the "
    "earliest and latest year this typeface or machine fits, or null if you cannot say.\n"
    "Respond with ONLY a JSON object:\n"
    '{{"content": "typewritten|letterhead|printed|handwritten|other", "typeface": "<name or null>", '
    '"machine": "<make/model/family or null>", "features": ["<a visible feature>", ...], '
    '"earliest_year": 1950, "latest_year": 1975, "confidence": "low|medium|high"}}')


def probe_docs():
    """PROBE_N documents the 27B read no date on (images alone), with a page-1 JPEG; by class, then id."""
    got, _ = DI.outputs(DI.CLUSTER, [])
    reqs = [r for r in DI.load_requests(DI.CLUSTER) if r["variant"] == "image"]
    none = [r for r in reqs if (rec := got.get(("qwen3.6-27b", r["id"]))) is not None
            and DI.read(rec)["ok"] and not DI.read(rec)["dates"]]
    none.sort(key=lambda r: (DI.CLASSES.index(r["cls"]), hashlib.sha1(r["doc"].encode()).hexdigest()))
    return none[:PROBE_N], len(none)


def crop(req, where):
    from PIL import Image
    lo, hi = CROPS[where]
    with Image.open(DI.PACK / "images" / os.path.basename(req["images"][0])) as im:
        w, h = im.size
        c = im.convert("RGB").crop((0, int(lo * h), w, int(hi * h)))
    buf = io.BytesIO()
    c.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def probe_row(req, where, rec):
    d = DI.reply(rec.get("text")) or {}
    truth = req["truth"].get("year")
    e, l = DI._year(d.get("earliest_year")), DI._year(d.get("latest_year"))
    named = bool(d.get("typeface") or d.get("machine"))
    checkable = named and bool(d.get("features")) and e is not None
    return {"doc": req["doc"], "cls": req["cls"], "crop": where, "truth": truth, "parsed": bool(d),
            "content": d.get("content"), "typeface": d.get("typeface"), "machine": d.get("machine"),
            "features": d.get("features") or [], "earliest": e, "latest": l, "confidence": d.get("confidence"),
            "named": named, "checkable": checkable,
            "consistent": checkable and truth is not None and e <= truth and (l is None or truth <= l),
            "width": (l - e) if checkable and l is not None else None}


def cmd_typeface(a):
    docs, pool = probe_docs()
    jobs = []
    for i, r in enumerate(docs):
        where = "letterhead" if i % 2 == 0 else "body"
        prompt = TYPEFACE_PROMPT.format(where="the top of the first page" if where == "letterhead"
                                        else "a band from the middle of the first page")
        jobs.append((r, where, (f"typeface-{where}|{r['doc']}", [crop(r, where)], prompt,
                                OUT / "typeface" / f"{where}|{r['doc']}.json")))
    with ThreadPoolExecutor(4) as ex:
        recs = list(ex.map(lambda j: call(*j[2]), jobs))
    rows = [probe_row(r, where, rec) for (r, where, _), rec in zip(jobs, recs)]
    led = [x for x in ledger() if x["id"].startswith("typeface-")]
    cost = sum(x["cost"] for x in led)
    n = len(rows)
    ck = [x for x in rows if x["checkable"]]
    cons = sum(x["consistent"] for x in ck)
    widths = sorted(x["width"] for x in ck if x["width"] is not None)
    cont = collections.Counter(str(x["content"]) for x in rows)
    L = ["# Dating: the typeface probe (W46.date-image-paid, B test 9)", "",
         "Written by `scripts/segbench/date_image_gateway.py typeface`. Gemini 3.7 Flash through the Stanford AI API "
         f"gateway (temperature 0, reasoning low) on {n} crops of the first page of documents from W46.date-image's "
         f"pack that Qwen3.6-27B found no written date on ({pool} of the 122; the first {n} by class, D first): the top "
         f"{int(100 * CROPS['letterhead'][1])}% of the page for the even ones (letterhead), the band from "
         f"{int(100 * CROPS['body'][0])}% to {int(100 * CROPS['body'][1])}% for the odd ones (typewriting), cut by "
         "position. Each was asked for the typeface or machine, the features it rests on and the years it fits, judging "
         "the letterforms only. **Checkable**: a named typeface or machine, with features and an earliest year. "
         "**Consistent**: the owner's year lies within the years it gave. "
         f"Spend about ${cost:.3f} for {len(led)} replies (3.8's list price as a ceiling).", "",
         f"- Parsed {sum(x['parsed'] for x in rows)}/{n}. What the crops show, by the reply: "
         + ", ".join(f"{k} {v}" for k, v in cont.most_common()) + ".",
         f"- Named a typeface or machine: {sum(x['named'] for x in rows)}/{n}; checkable: {len(ck)}/{n}; consistent "
         f"with the owner's year: {cons}/{len(ck)}."
         + (f" Width of the range given: median {widths[len(widths) // 2]} years (from {widths[0]} to {widths[-1]})."
            if widths else ""), "",
         "| doc | class | crop | shows | typeface | machine | years | owner's year | consistent | confidence |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for x in rows:
        yrs = f"{x['earliest'] or '?'}-{x['latest'] or '?'}" if x["earliest"] or x["latest"] else "-"
        L.append(f"| {x['doc'][2:10]} | {x['cls']} | {x['crop']} | {x['content'] or '-'} | {x['typeface'] or '-'} | "
                 f"{x['machine'] or '-'} | {yrs} | {x['truth']} | {'yes' if x['consistent'] else 'no' if x['checkable'] else '-'} "
                 f"| {x['confidence'] or '-'} |")
    out = Path(TYPEFACE_RESULTS)
    old = out.read_text() if out.exists() else ""
    kept = old[old.index(DI.READING_HEAD):] if DI.READING_HEAD in old else \
        DI.READING_HEAD + "\n(written by hand; a rerun keeps everything below this heading)\n"
    out.write_text("\n".join(L) + "\n" + kept)
    Path(TYPEFACE_RESULTS[:-3] + ".json").write_text(json.dumps(
        {"model": G.MODEL, "crops": CROPS, "pool": pool, "spent_estimate": round(cost, 4), "rows": rows}, indent=1) + "\n")
    print("\n".join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run"); p.add_argument("--limit", type=int, default=0)
    sub.add_parser("typeface")
    a = ap.parse_args()
    {"run": cmd_run, "typeface": cmd_typeface}[a.cmd](a)


if __name__ == "__main__":
    main()
