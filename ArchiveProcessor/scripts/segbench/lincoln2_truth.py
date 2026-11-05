#!/usr/bin/env python3
"""W46.seg-adapt-lora: the truth for the second Lincoln box (lincoln_box2.py), without a Claude or owner reading.

  python3 lincoln2_truth.py --root DIR estimate   # gaps to ask and the worst-case charge; no call
  python3 lincoln2_truth.py --root DIR collect    # Gemini 3.7 Flash, one call per within-item gap
  python3 lincoln2_truth.py --root DIR freeze     # -> segbench-results/public-segmentation/lincoln2.json

THE RULE. Every Library of Congress catalogue item start is a document start (box 1 kept all 72 of its own). Inside
an item, the open question is an internal start: an enclosure, a clipping, a second copy, a separate wrapper (box 1
had nine among 81 documents). Gemini 3.7 Flash on the Stanford gateway sees the two page images of each
within-item gap with the owner's ten rules and the item's catalogue title, and answers same, new or unsure. A gap it
calls new or unsure, or that fails, is an UNSURE gap: out of every boundary count, as the owner's unsure gaps are
(score.py). Every other within-item gap is a continuation. So the truth's only model-made claims are "same", and a
wrong "same" is the one error it can carry. Gemini is not a route the item scores (the 2B against its LoRA).

MONEY. The gateway is real money on a Stanford PTA. CAP bounds the item's spend on this pass. Calls run one at a
time; each writes an fsynced reservation at its worst case before it is sent and a settle line after, so a killed
run keeps its reservation counted. Charges are estimates at list token rates (gateway_gemini.PRICE), or the
gateway's own figure when larger. The key is the Processor's gateway key, read by gateway_gemini.api_key().
Public LoC pages only (authorized as comparable benchmark uploads, owner 2026-10-25).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import time

import gateway_gemini as GW
import public_segmentation as PS

STORE = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/seg-adapt-lora/gateway"
CAP = 1.50
MAX_TOKENS = 4096
RESERVE = round((6000 * GW.PRICE[0] + MAX_TOKENS * GW.PRICE[1]) / 1e6, 6)   # two images + prompt, full output
LONG_EDGE = 1600

RULES = """The archive's ten document rules:
1. An enclosure (a complete item sent with a letter: a report, a pamphlet, someone else's letter, a printed item) is its own document.
2. An attachment made to go with the letter, with no date or heading of its own, is part of the letter.
3. A carbon or file copy of a letter is the letter.
4. Two copies of the same document kept together are two documents; the second copy's first page starts a document.
5. The same page photographed twice is part of the same document.
6. An envelope, wrapper or docketed back next to the letter it held is part of that letter; one on its own is its own document.
7. Each newspaper article is its own document; a continuation of the same article is part of it.
8. A photograph is its own document; a photo of its back is part of it.
9. A blank page or blank back of a sheet is part of the document it belongs to.
10. A full magazine or pamphlet is one document."""

PROMPT = """These are two consecutive scanned pages, A then B, from one Library of Congress catalogue item in the
Abraham Lincoln Papers. The catalogue describes the item as:
{title}

{rules}

Under these rules, does page B continue the same document as page A, or does page B begin a separate document
(for example an enclosure, a clipping, a second copy, or a separate wrapper)? Answer "same", "new", or "unsure"
when the pages do not let you tell.
Return only one JSON object: {{"decision": "same" | "new" | "unsure", "why": "<one short sentence>"}}"""


def box(root):
    m = json.loads((PS.MANIFESTS / "lincoln2-draft.json").read_text())
    for p in m["pages"]:
        if hashlib.sha256((root / p["image"]).read_bytes()).hexdigest() != p["sha256"]:
            raise ValueError(f"image changed: {p['n']}")
    return m


def gaps(m):
    """Within-item gaps as (left n, right n, item title). Catalogue starts are not asked."""
    title = {d["id"]: d["title"] for d in m["source_documents"]}
    ps = m["pages"]
    return [(a["n"], b["n"], title[b["id"]]) for a, b in zip(ps, ps[1:]) if b["page"] != 1]


def jpeg(path):
    from PIL import Image
    with Image.open(path) as im:
        im = im.convert("RGB")
        im.thumbnail((LONG_EDGE, LONG_EDGE))
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=85)
        return buf.getvalue()


def body(root, m, a, b, title):
    pages = {p["n"]: p for p in m["pages"]}
    parts = []
    for label, n in (("A", a), ("B", b)):
        parts += [{"type": "text", "text": f"Page {label}:"},
                  {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," +
                   base64.b64encode(jpeg(root / pages[n]["image"])).decode()}}]
    parts.append({"type": "text", "text": PROMPT.format(title=title, rules=RULES)})
    return {"model": GW.MODEL, "temperature": 0, "max_tokens": MAX_TOKENS, "reasoning_effort": "low",
            "response_format": {"type": "json_object"}, "messages": [{"role": "user", "content": parts}]}


def records():
    f = STORE / "calls.jsonl"
    return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []


def spent():
    """One effective charge per gap: its latest line, so an unsettled reservation still counts."""
    last = {}
    for r in records():
        last[r["gap"]] = r["charge"]
    return sum(last.values())


def append(rec):
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "calls.jsonl").open("a") as f:
        f.write(json.dumps(rec) + "\n")
        f.flush()
        os.fsync(f.fileno())


def reply_path(a, b):
    return STORE / "replies" / f"{a:04}-{b:04}.json"


def decision(a, b):
    """same / new / unsure from a cached reply; None when no usable reply exists (counted unsure at freeze)."""
    p = reply_path(a, b)
    if not p.exists():
        return None, None
    raw = json.loads(p.read_text()).get("raw") or ""
    raw = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw.strip())
    try:
        got = json.loads(raw)
    except ValueError:
        return None, None
    d = got.get("decision") if isinstance(got, dict) else None
    return (d, got.get("why")) if d in ("same", "new", "unsure") else (None, None)


def estimate(root):
    m = box(root)
    g = gaps(m)
    todo = [x for x in g if not reply_path(x[0], x[1]).exists()]
    print(f"{len(g)} within-item gaps, {len(todo)} unanswered; worst case ${RESERVE * len(todo):.2f} "
          f"(${RESERVE:.4f} each); spent so far ${spent():.4f} of the ${CAP:.2f} cap")


def collect(root):
    m = box(root)
    for a, b, title in gaps(m):
        if reply_path(a, b).exists():
            continue
        gap = f"{a}|{b}"
        if any(r["gap"] == gap and r["event"] == "reserve" for r in records()) and \
                not any(r["gap"] == gap and r["event"] == "settle" for r in records()):
            raise SystemExit(f"gap {gap} was sent without a settled reply; inspect {STORE}/calls.jsonl first")
        if spent() + RESERVE > CAP:
            raise SystemExit(f"cap: ${spent():.4f} + ${RESERVE:.4f} would pass ${CAP:.2f}")
        bd = body(root, m, a, b, title)
        sha = hashlib.sha256(json.dumps(bd, sort_keys=True).encode()).hexdigest()
        append({"gap": gap, "event": "reserve", "charge": RESERVE, "request_sha256": sha, "t": time.time()})
        t = time.time()
        r = GW.request("/chat/completions", bd)
        got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
        usage = got.get("usage") or {}
        rec = GW.with_gateway_cost({"gap": gap, "event": "settle", "http": r.status_code, "model": got.get("model"),
                                    "usage": usage, "cost": round(GW.cost(usage), 6), "request_sha256": sha,
                                    "wall_s": round(time.time() - t, 3)}, r)
        # Usage unknown on a 200 keeps the worst case counted; a refused request costs nothing known either.
        rec["charge"] = GW.charge(rec) if usage else RESERVE
        append(rec)
        choice = (got.get("choices") or [{}])[0]
        if r.status_code == 200:
            reply_path(a, b).parent.mkdir(parents=True, exist_ok=True)
            reply_path(a, b).write_text(json.dumps({"meta": {**rec, "finish": choice.get("finish_reason")},
                                                    "raw": (choice.get("message") or {}).get("content")},
                                                   ensure_ascii=False, indent=1))
            print(gap, decision(a, b)[0], f"${spent():.4f}", flush=True)
        else:
            raise SystemExit(f"gap {gap}: HTTP {r.status_code} {json.dumps(got)[:300]}")
    print(f"done; ${spent():.4f} charged of the ${CAP:.2f} cap")


def freeze(root):
    m = box(root)
    asked = {(a, b): decision(a, b) for a, b, _ in gaps(m)}
    unsure, starts = [], {}
    for p in m["pages"]:
        n = p["n"]
        if p["page"] == 1:
            p["audit"] = "Catalogue item start (every catalogue start is kept as a document start)."
        else:
            d, why = asked[(n - 1, n)]
            if d == "same":
                p["audit"] = f"Within catalogue item; Gemini 3.7 Flash (gateway): same. {why or ''}".strip()
            else:
                unsure.append({"id": f"l2u{len(unsure) + 1:02}", "left": n - 1, "right": n})
                starts[str(n)] = f"Gemini 3.7 Flash (gateway): {d or 'no usable reply'}. {why or ''}".strip()
                p["audit"] = "Within catalogue item; possible internal start, unsure (out of every boundary count)."
        p["reviewed"] = True
    m["audit"] = {"reviewed_through": len(m["pages"]), "method": (
        "Catalogue starts are document starts. Each within-item gap was read by Gemini 3.7 Flash on the Stanford "
        "gateway (two page images, the ten rules, the catalogue title); 'same' is a continuation, and 'new', "
        "'unsure' or a failed reply makes the gap unsure. No Claude or owner reading (W46.seg-adapt-lora)."),
        "possible_internal_starts": starts}
    m["unsure"] = unsure
    m["frozen_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    m["truth_spend_usd"] = round(spent(), 6)
    PS.validate(m, root)
    out = PS.MANIFESTS / "lincoln2.json"
    out.write_text(json.dumps(m, indent=1, ensure_ascii=False) + "\n")
    same = sum(1 for d, _ in asked.values() if d == "same")
    print(f"{out}: {len(m['pages'])} pages, {len(m['source_documents'])} catalogue starts, {same} same, "
          f"{len(unsure)} unsure gaps; ${spent():.4f} charged")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, type=Path)
    ap.add_argument("cmd", choices=("estimate", "collect", "freeze"))
    a = ap.parse_args()
    {"estimate": estimate, "collect": collect, "freeze": freeze}[a.cmd](a.root.resolve())


if __name__ == "__main__":
    sys.exit(main())
