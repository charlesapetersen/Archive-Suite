#!/usr/bin/env python3
"""W46.date-enclosure-paid: Gemini 3.7 Flash through the Stanford AI API gateway on W46.date-enclosure's 225 starts.

Two arms, both with images, on the set `date_enclosure.py set` built (owner 15, A 60, A' 45, matched negatives 105):
  marker   the app's own OCR call on the gateway route: OCRPrompt.build with the cover's last page as previous text and
           no previous image (the app's default, sendPreviousImage false), the candidate's first page at the app's
           2048 px; line 1 read by the app's parseEnclosureFlag (date_enclosure's helper). Only the header is read,
           so the reply is capped at MARKER_TOKENS and a page cut off mid-transcription still counts.
  relate   the relation classifier's prompt (date_enclosure.relate_prompt, the one the 2B and the 27B answered) with
           the two pages as images: the cover's last page first, the candidate's first page second.

    python3 date_enclosure_gateway.py render              # the 2048 px pages (sips, read-only on the corpus)
    python3 date_enclosure_gateway.py run --arm marker|relate [--limit N]   # cached by destination; CAP bounds spend
    python3 date_enclosure.py score                       # the gateway arms join the page beside the free ones

The gateway is real money on a Stanford PTA (root CLAUDE.md). Spend is counted from the gateway's token usage at
Gemini 3.8 Flash's list price taken as a ceiling (gateway_gemini.PRICE; the gateway returns no cost) into the ledger
CACHE/calls.jsonl, written before a reply is used. The key is read by gateway_gemini.api_key, never printed or written.
Images and replies stay in the private bench cache. Gemini 3.7, not 3.8: the gateway serves no 3.8. Run from
scripts/segbench.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.getcwd())
import corpus_pairs as CP
import corpus_survey as CS
import date_enclosure as E
import date_tagging as DT
import gateway_gemini as G

CACHE = os.path.join(E.OUT, "gateway")
PAGES = os.path.join(CACHE, "pages-2048")
LABELS = {"marker": "gemini3.7-flash-gw-marker", "relate": "gemini3.7-flash-gw-relate"}
SIDE = 2048           # ImageEncoding.maxOCRDimension, what the app sends
CAP = 4.00            # the item's total; estimate $1.50-2.50 (10-gap-audit.md §5 item 15), under the $7 rule
MARKER_TOKENS = 2048  # 3.7 reasons first (a 20-token cap returned no text at the gate check); line 1 is all we read
RELATE_TOKENS = 2048
WORST = {"marker": (6000 * G.PRICE[0] + MARKER_TOKENS * G.PRICE[1]) / 1e6,
         "relate": (9000 * G.PRICE[0] + RELATE_TOKENS * G.PRICE[1]) / 1e6}
IMAGES_LEAD = ("Two page images are attached. The FIRST image is the last page of Document 1. The SECOND image is the "
               "first page of Document 2. The text below was read from them by OCR.\n\n")


def ledger():
    p = os.path.join(CACHE, "calls.jsonl")
    return [json.loads(x) for x in open(p)] if os.path.exists(p) else []


def spent():
    return sum(r.get("cost", 0) for r in ledger())


def cover_last_page(d):
    """The corpus path of the cover's last page: the page before the candidate's first page in folder order (the cover
    is the immediately preceding segment, enclosure_split.neighbour), checked against the text the set recorded."""
    ps = [p for p, _, _ in CP.folder_pages(d["folder"], {})]
    k = ps.index(d["first_page"])
    assert k > 0, d["id"]
    prev = ps[k - 1]
    assert (DT.page_text(prev) or "") == (d["cover_last_page"] or ""), d["id"]
    return prev


def page(rel):
    return os.path.join(PAGES, rel.replace("/", "__").rsplit(".", 1)[0] + ".jpg")


def cmd_render(a):
    os.makedirs(PAGES, exist_ok=True)
    rels = []
    for d in E.load_set():
        rels += [d["first_page"], cover_last_page(d)]
    bad = 0
    for rel in dict.fromkeys(rels):
        out = page(rel)
        if not os.path.exists(out):
            subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(SIDE), os.path.join(CS.CORPUS, rel), "--out", out],
                           capture_output=True, check=False)
        bad += not os.path.exists(out)
    print(f"{len(set(rels))} pages, {bad} not rendered; {PAGES}")


def _img(path):
    return {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," +
                                               base64.b64encode(open(path, "rb").read()).decode()}}


def request_body(arm, d, marker_prompt=None):
    if arm == "marker":
        content, cap = [_img(page(d["first_page"])), {"type": "text", "text": marker_prompt}], MARKER_TOKENS
    else:
        content = [_img(page(cover_last_page(d))), _img(page(d["first_page"])),
                   {"type": "text", "text": IMAGES_LEAD + E.relate_prompt(d)}]
        cap = RELATE_TOKENS
    return {"model": G.MODEL, "temperature": 0, "max_tokens": cap, "reasoning_effort": "low",
            "messages": [{"role": "user", "content": content}]}


def call(arm, d, body):
    path = os.path.join(E.answers_dir(LABELS[arm]), d["id"] + ".json")
    if os.path.exists(path):
        return json.load(open(path))
    if spent() + WORST[arm] > CAP:
        raise SystemExit(f"cap: ${spent():.4f} spent of ${CAP}")
    t = time.time()
    for attempt in range(3):
        r = G.request("/chat/completions", body)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    rec = {"arm": arm, "id": d["id"], "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3),
           "model": got.get("model"), "usage": usage, "cost": round(G.cost(usage), 6)}
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    out = {"id": d["id"], "raw": (choice.get("message") or {}).get("content") if r.status_code == 200 else None,
           "usage": usage, "wall_s": rec["wall_s"], "finish": choice.get("finish_reason")}
    if r.status_code == 200 and out["raw"]:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        json.dump(out, open(path, "w"), ensure_ascii=False, indent=1)
    else:
        print(d["id"], r.status_code, out.get("finish"), json.dumps(got)[:300])
    return out


def cmd_run(a):
    items = E.load_set()
    done = set(E.load_answers(LABELS[a.arm]))
    todo = [d for d in items if d["id"] not in done][: a.limit or None]
    prompts = E.marker_prompts(todo) if a.arm == "marker" and todo else {}
    jobs = [(a.arm, d, request_body(a.arm, d, prompts.get(d["id"]))) for d in todo]
    print(f"{a.arm}: {len(jobs)} calls, ${spent():.4f} spent before", flush=True)
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda j: call(*j), jobs))
    empty = [r["id"] for r in res if not r.get("raw")]
    calls = [r for r in ledger() if r.get("arm") == a.arm]
    mean = sum(r["cost"] for r in calls) / len(calls) if calls else 0
    print(f"{len(res) - len(empty)}/{len(res)} answered, ${spent():.4f} spent in all; {a.arm} ${mean:.5f} a call; "
          f"no text: {empty[:20]}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("render")
    r = sub.add_parser("run")
    r.add_argument("--arm", choices=sorted(LABELS), required=True)
    r.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    {"render": cmd_render, "run": cmd_run}[a.cmd](a)


if __name__ == "__main__":
    main()
