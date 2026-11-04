#!/usr/bin/env python3
"""W46.seg-window-modality-paid: Gemini 3.7 Flash's window size and text-only windows, through the gateway.

  python3 seg_window_gateway.py plan              # the arms, request counts and an allowance (no calls)
  python3 seg_window_gateway.py collect [--limit N] [--arm ARM]   # paid calls, cached, one item ledger
  python3 seg_window_gateway.py score             # no calls -> segbench-results/seg-window-gateway.{json,md}

The paid half of W46.seg-window-modality, whose open arms found the trained 2B flat in window size with images and
4.6-19.7 points worse on text alone. This asks whether a strong model is as insensitive to the images as A04 says.

FIXED BEFORE ANY ANSWER:
- Route: Gemini 3.7 Flash through the Stanford AI API gateway (root CLAUDE.md: gateway first), temperature 0,
  reasoning_effort low, JSON mode, the request seg_lincoln_gateway builds (g1 prompt with its schema appended, the
  bench's 1600 px thumbnails, cached Apple Vision text, 4096 output tokens a window; whole folders wh1 at JPEG
  quality 45 and 64 tokens a gap, at least 8192). The bench's dev-box Gemini figures are 3.8 Flash (direct key),
  which the gateway does not serve, so every arm here is compared with the K = 7 3.7 control, never with 3.8 (SEG-9).
- Arms, in the order they are collected:
    k7-it   K = 7 with images, all three development boxes (551 pages): the control, method_window.windows exactly
    k7-t    K = 7 text only, all 551 pages
    k3-it, k5-it, k10-it, folder-it   Deaver only (149 pages, the development box nearest the 150-page subset
            seg-window-modality.md recommended; a whole box, so no folder is cut)
    k3-t, k5-t, k10-t   Deaver only, run last and only while the item's total stays under the cap
  A K-page window steps (K - 1) // 2 pages (seg_window_modality.spans); the folder unit is method_whole.folders.
- Text only drops the images and their "Page n:" parts and replaces g1's one paragraph about them; every other word
  is the same request.
- A reply that fails (HTTP, unfinished, unparsed) is re-sent once at the same settings; a window still failed votes
  0.5 on its gaps, as in seg_window_modality, and is counted in the report; a failed folder leaves its arm unscored.
- Scored with truth photos, as every development-box figure is; pages in an exact document pooled over boxes, and a
  paired bootstrap over truth documents for each comparison. (Fixed before any answer as folder runs; changed after
  the first score because Deaver has only five, too few to resample, and an interval over five runs is not a test.
  The folder-run interval is still written to the JSON, as `by_folder_run`.)
- Money: ITEM_CAP_USD 8.00 (owner, 2026-10-21, STATE Phase 2 decision 6). The gateway offers no batch route, so list
  rates are the estimate: $0.75 / $3.75 per million input / output tokens, reasoning included, as seg_lincoln_gateway.
  Each call reserves its allowance in the ledger before it is sent (fsynced), settles at the larger of the token
  estimate and the gateway's own figure, and the next call is refused when reservation would pass the cap.
Owner images, text and replies stay in STORE, outside git (the repo is public).
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import concurrent.futures as cf
import fcntl
import hashlib
import json
import os
from pathlib import Path
import random
import sys
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import data  # noqa: E402
from methods import METHODS  # noqa: E402,F401 -- registered modules load in their normal order
import gateway_gemini as GW  # noqa: E402
import method_whole as H  # noqa: E402
import method_window as W  # noqa: E402
import seg_lincoln_gateway as LG  # noqa: E402
import seg_window_modality as SM  # noqa: E402

TAG = "W46.seg-window-modality-paid"
STORE = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/seg-window-gateway"
RESULTS = HERE.parents[1] / "segbench-results"
ITEM_CAP_USD = 8.00
PRICE = (0.75, 3.75)
DEV = ("Dean", "Deaver", "Herrnstein")
SUBSET = "Deaver"
ARMS = [("k7-it", DEV), ("k7-t", DEV), ("k3-it", (SUBSET,)), ("k5-it", (SUBSET,)), ("k10-it", (SUBSET,)),
        ("folder-it", (SUBSET,)), ("k3-t", (SUBSET,)), ("k5-t", (SUBSET,)), ("k10-t", (SUBSET,))]
OPTIONAL = ("k3-t", "k5-t", "k10-t")
CONCURRENCY = 6
_lock = threading.Lock()


def load(box):
    return data.load(box, with_exif=False)


def units(col, arm):
    head = arm.split("-")[0]
    return H.folders(col) if head == "folder" else SM.spans(len(col.pages), int(head[1:]))


OLD_PARA = ("The\n{k} images above are consecutive photographs from that stream, each introduced by its page number.\n"
            "Answer from the images. The OCR text below is automatic and has errors; the image wins when they\n"
            "disagree.")
NEW_PARA = ("This\nwindow holds {k} consecutive photographs from that stream, pages {a} to {b}. The photographs are "
            "not shown: answer\nfrom the OCR text below alone. It is automatic and has errors.")


def request(col, a, b, arm):
    """(body, request sha256, page numbers) for one unit of an arm."""
    whole = arm.startswith("folder")
    body, key, nums = LG.request("gemini", col, a, b, whole)
    if arm.endswith("-t"):
        parts = body["messages"][0]["content"]
        prompt = parts[-1]["text"]
        old = OLD_PARA.format(k=len(nums))
        if prompt.count(old) != 1:
            raise ValueError(f"{col.name} {nums[0]}-{nums[-1]}: the image paragraph is not unique in the prompt")
        prompt = prompt.replace(old, NEW_PARA.format(k=len(nums), a=nums[0], b=nums[-1]), 1)
        body = {**body, "messages": [{"role": "user", "content": [{"type": "text", "text": prompt}]}]}
        key = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    return body, key, nums


def parse(raw, nums, whole):
    if whole:
        return {"pages": {n: "document" for n in nums}, "boundaries": LG.parse(raw, nums, True)}
    return LG.parse(raw, nums, False)


# --- the ledger -----------------------------------------------------------------------------------

def records():
    p = STORE / "calls.jsonl"
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


def latest():
    out = {}
    for r in records():
        out[r["id"]] = r
    return out


def spent():
    """One charge per call id, the latest line's: a reservation a killed process never settled stays charged."""
    return sum(r["charge"] for r in latest().values())


def append(rec):
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "calls.jsonl").open("a") as f:
        f.write(json.dumps(rec) + "\n")
        f.flush()
        os.fsync(f.fileno())


def reply(key):
    p = STORE / "replies" / f"{key}.json"
    return json.loads(p.read_text()) if p.exists() else None


def attempts(key):
    return sum(r["event"] == "reserve" and r["request_sha256"] == key for r in records())


def allowance(body):
    """Input: one token a UTF-8 text byte, 2048 an image (Gemini bills about 1,090 at 1600 px), 2048 overhead; output:
    the full cap. A bound to stop on, not a billing figure."""
    parts = body["messages"][0]["content"]
    text = sum(len(p["text"].encode()) for p in parts if p["type"] == "text")
    images = sum(p["type"] == "image_url" for p in parts)
    return ((text + 2048 * images + 2048) * PRICE[0] + body["max_tokens"] * PRICE[1]) / 1e6


def call(arm, col, a, b):
    """One unit: cached, else reserved, sent, settled. Returns 'cached', 'ok', 'failed' or 'skipped'."""
    body, key, nums = request(col, a, b, arm)
    hit = reply(key)
    if hit and hit["valid"]:
        return "cached"
    whole = arm.startswith("folder")
    with _lock:
        n = attempts(key)
        if n >= 2:
            return "failed"
        reserve = allowance(body)
        if spent() + reserve > ITEM_CAP_USD:
            return "skipped"
        rec = {"id": uuid.uuid4().hex, "event": "reserve", "charge": reserve, "arm": arm, "box": col.name,
               "span": [nums[0], nums[-1]], "attempt": n + 1, "model": body["model"],
               "max_tokens": body["max_tokens"], "request_sha256": key, "t": time.time()}
        append(rec)
    r = None
    for wait in (0, 20, 60, 120):
        time.sleep(wait)
        try:
            r = GW.request("/chat/completions", body, timeout=900 if whole else 300)
        except Exception as e:  # transport ended: usage unknown, the reservation stays charged
            with _lock:
                append({**rec, "event": "unknown", "error": type(e).__name__, "wall_s": round(time.time() - rec["t"], 1)})
            return "failed"
        if r.status_code != 429:     # a rate-limit refusal ran no inference; wait and send again
            break
    try:
        got = r.json()
    except ValueError:
        got = {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    known = all(isinstance(usage.get(k), int) for k in ("prompt_tokens", "completion_tokens"))
    estimate = (usage["prompt_tokens"] * PRICE[0] + usage["completion_tokens"] * PRICE[1]) / 1e6 if known else None
    gw = GW.gateway_cost(r)
    if estimate is None and gw is None:
        charge = 0.0 if r.status_code in (400, 413, 429) else reserve   # refused before inference, or unknown
    else:
        charge = max(estimate or 0, gw or 0)
    choice = (got.get("choices") or [{}])[0]
    raw = (choice.get("message") or {}).get("content") or ""
    error = None
    try:
        if r.status_code != 200 or choice.get("finish_reason") != "stop" or not known:
            raise ValueError(f"HTTP {r.status_code}, finish {choice.get('finish_reason')}, usage known {known}")
        parse(raw, nums, whole)
    except (ValueError, KeyError, TypeError, W.ParseError) as e:
        error = str(e)[:300]
    with _lock:
        dest = STORE / "replies" / f"{key}.json"
        dest.parent.mkdir(parents=True, exist_ok=True)
        if error is None or not dest.exists():
            tmp = dest.with_suffix(f".{rec['id']}.tmp")
            tmp.write_text(json.dumps({"valid": error is None, "raw": raw, "response": got, "request": rec},
                                      ensure_ascii=False))
            tmp.replace(dest)
        append({**rec, "event": "settle", "charge": charge, "estimate": estimate,
                **({} if gw is None else {"gateway_cost": gw}), "usage": usage, "valid": error is None,
                "error": error, "http": r.status_code, "finish": choice.get("finish_reason"),
                "returned_model": got.get("model"), "wall_s": round(time.time() - rec["t"], 1)})
    print(f"{arm:9} {col.name:10} {nums[0]}-{nums[-1]} {'ok' if error is None else 'FAILED ' + error[:80]}  "
          f"item ${spent():.4f}", flush=True)
    return "ok" if error is None else "failed"


def jobs(arms=None):
    out = []
    cols = {b: load(b) for b in DEV}
    for arm, boxes in ARMS:
        if arms and arm not in arms:
            continue
        for box in boxes:
            out += [(arm, cols[box], a, b) for a, b in units(cols[box], arm)]
    return out


def cmd_plan(a):
    total = 0.0
    per = Counter()
    for arm, col, lo, hi in jobs():
        body, _, _ = request(col, lo, hi, arm)
        per[arm] += 1
        total += allowance(body)
    for arm, _ in ARMS:
        print(f"{arm:9} {per[arm]:4} units")
    print(f"allowance ${total:.2f} at full output caps; ledger so far ${spent():.4f} of ${ITEM_CAP_USD:.2f}")


def cmd_collect(a):
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        todo = jobs([a.arm] if a.arm else None)
        for rnd in (1, 2):            # the second round re-sends each failure once
            pending = [j for j in todo if not ((h := reply(request(j[1], j[2], j[3], j[0])[1])) and h["valid"])]
            if a.limit:
                pending = pending[:a.limit]
            print(f"round {rnd}: {len(pending)} units to send, item ${spent():.4f}", flush=True)
            res = Counter()
            with cf.ThreadPoolExecutor(CONCURRENCY) as ex:
                for out in ex.map(lambda j: call(*j), pending):
                    res[out] += 1
            print(f"round {rnd}: {dict(res)}, item ${spent():.4f}", flush=True)
            if res["skipped"]:
                print("cap reached: the rest are left unsent", flush=True)
                break


# --- scoring --------------------------------------------------------------------------------------

def judge_for(arm, failed):
    def judge(col, a, b):
        body, key, nums = request(col, a, b, arm)
        hit = reply(key)
        if hit and hit["valid"]:
            return parse(hit["raw"], nums, arm.startswith("folder"))
        if attempts(key) == 0:
            return None
        failed[(arm, col.name)] += 1
        return None if arm.startswith("folder") else SM._seg()[1].neutral(nums)
    return judge


def exact_pages(truth, pred):
    """Per page: None for a label photo, else whether its document is exactly the predicted one."""
    from score import PHOTO, segment_ids
    ti, pi = segment_ids(list(truth)), segment_ids(list(pred))
    tg, pg = defaultdict(set), defaultdict(set)
    for k, (x, y) in enumerate(zip(ti, pi)):
        tg[x].add(k)
        pg[y].add(k)
    return [None if t in PHOTO else tg[ti[k]] == pg[pi[k]] and pred[k] not in PHOTO for k, t in enumerate(truth)]


def clusters(col):
    """Folder runs: the document pages between label photos, the bootstrap's resampling unit."""
    from score import PHOTO
    out, cur = [], []
    for k, t in enumerate(col.labels):
        if t in PHOTO:
            if cur:
                out.append(cur)
            cur = []
        else:
            cur.append(k)
    return out + ([cur] if cur else [])


def documents(col):
    """The truth's documents as page-index lists (label photos left out), the bootstrap's resampling unit."""
    from score import PHOTO, segment_ids
    out = defaultdict(list)
    for k, (t, s) in enumerate(zip(col.labels, segment_ids(list(col.labels)))):
        if t not in PHOTO:
            out[s].append(k)
    return list(out.values())


def bootstrap(pages_a, pages_b, groups, rounds=10000, seed=0):
    """Paired difference in pooled pages exact, a less b, resampling the groups given; 95% percentile interval."""
    rows = [(sum(pages_a[k] for k in g), sum(pages_b[k] for k in g), len(g)) for g in groups]
    n = sum(r[2] for r in rows)
    delta = (sum(r[0] for r in rows) - sum(r[1] for r in rows)) / n
    rng = random.Random(seed)
    ds = []
    for _ in range(rounds):
        s = [rows[rng.randrange(len(rows))] for _ in rows]
        ds.append((sum(r[0] for r in s) - sum(r[1] for r in s)) / sum(r[2] for r in s))
    ds.sort()
    return {"delta": delta, "lo": ds[int(0.025 * rounds)], "hi": ds[int(0.975 * rounds) - 1], "pages": n,
            "runs": len(rows)}


TWO_B_PACK = Path(os.environ.get("AGENT_STATE", Path.home() / ".local/state/archive-autonomous")) / \
    "artifacts/seg-window-modality-20261029"


def two_b_pages(cols, pack=TWO_B_PACK):
    """The 2B's per-page exact flags at K = 7 with images and text only on the development boxes, rebuilt from
    W46.seg-window-modality's Sherlock answers kept with its pack (no calls); None when the pack is not on disk."""
    if not (Path(pack) / "runs/2b-sweep/answers.jsonl").exists():
        return None
    judge_for, _, _ = SM.judges(pack, Path(pack) / "runs", "2b-sweep")
    return {(arm, box): exact_pages(col.labels, W.assemble(
                col, SM.combine_units(col, SM.units(col, arm), judge_for(arm)), True).labels)
            for arm in ("k7-it", "k7-t") for box, col in cols.items()}


def cmd_score(a):
    import rescore
    from dataclasses import asdict
    from score import score_labels, derived
    rescore.no_network()
    import method_gemini as G
    cols = {b: load(b) for b in DEV}
    failed = Counter()
    preds, rows, missing = {}, [], []
    for arm, boxes in ARMS:
        for box in boxes:
            col = cols[box]
            try:
                comb = SM.combine_units(col, units(col, arm), judge_for(arm, failed), arm.startswith("folder"))
            except RuntimeError as e:
                missing.append(f"{arm} {e}")
                continue
            preds[(arm, box)] = W.assemble(col, comb, True).labels
    for box, col in cols.items():
        with H.gemini_variant("gemini-3.8-flash", "low", "window-gemini-3.8-flash-low",
                              "window-gemini-3.8-flash-low-calls.jsonl"):
            preds[("3.8-k7-it", box)] = W.assemble(col, W.combine(col, G.judge_window), True).labels
        preds[("3.8-folder-it", box)] = METHODS["whole-gemini"].predict(col).labels
    sm = json.loads((RESULTS / "seg-window-modality.json").read_text())
    per_page = {}
    for (arm, box), labels in preds.items():
        col = cols[box]
        c = score_labels(col.labels, labels, box)
        m = derived(c)
        ex = exact_pages(col.labels, labels)
        if sum(bool(x) for x in ex) != c.pages_exact:
            raise SystemExit(f"{arm} {box}: per-page exact {sum(bool(x) for x in ex)} != scorer's {c.pages_exact}")
        per_page[(arm, box)] = ex
        rows.append({"arm": arm, "box": box, "pages": c.doc_pages, "pages_exact": m["pages_in_exact_doc"],
                     "boundary_f1": m["boundary_f1"], "false_splits": c.false_splits, "false_merges": c.false_merges,
                     "failed_units": failed[(arm, box)], "counts": asdict(c)})

    def pool(arm, boxes):
        rs = [r for r in rows if r["arm"] == arm and r["box"] in boxes]
        if len(rs) != len(boxes):
            return None
        c = Counter()
        for r in rs:
            c.update({k: r["counts"][k] for k in ("doc_pages", "pages_exact", "tp", "false_splits", "false_merges")})
        return {"arm": arm, "boxes": list(boxes), "pages": c["doc_pages"], "pages_exact": c["pages_exact"] / c["doc_pages"],
                "boundary_f1": 2 * c["tp"] / (2 * c["tp"] + c["false_splits"] + c["false_merges"]),
                "false_splits": c["false_splits"], "false_merges": c["false_merges"],
                "failed_units": sum(r["failed_units"] for r in rs)}

    def paired(x, y, boxes):
        if not all((x, b) in per_page and (y, b) in per_page for b in boxes):
            return None
        pa, pb, docs, runs, off = [], [], [], [], 0
        for b in boxes:
            ea, eb = per_page[(x, b)], per_page[(y, b)]
            pa += [bool(v) for v in ea]
            pb += [bool(v) for v in eb]
            docs += [[off + k for k in g] for g in documents(cols[b])]
            runs += [[off + k for k in g] for g in clusters(cols[b])]
            off += len(ea)
        by_run = bootstrap(pa, pb, runs)
        return {"a": x, "b": y, "boxes": list(boxes), **bootstrap(pa, pb, docs),
                "by_folder_run": {k: by_run[k] for k in ("lo", "hi", "runs")}}

    pooled = [p for arm in [x for x, _ in ARMS] + ["3.8-k7-it", "3.8-folder-it"]
              for boxes in (DEV, (SUBSET,)) if (p := pool(arm, boxes))]
    comparisons = [c for c in (
        paired("k7-t", "k7-it", DEV), paired("3.8-k7-it", "k7-it", DEV), paired("3.8-k7-it", "k7-it", (SUBSET,)),
        *(paired(f"k{k}-it", "k7-it", (SUBSET,)) for k in (3, 5, 10)), paired("folder-it", "k7-it", (SUBSET,)),
        *(paired(f"k{k}-t", f"k{k}-it", (SUBSET,)) for k in (3, 5, 10)), paired("k7-t", "k7-it", (SUBSET,)),
        paired("3.8-folder-it", "3.8-k7-it", DEV), paired("k7-t", "k7-it", ("Dean",)),
        paired("3.8-k7-it", "k7-it", ("Dean",)), paired("3.8-folder-it", "3.8-k7-it", (SUBSET,)),
        paired("3.8-folder-it", "3.8-k7-it", ("Dean",))) if c]
    # The difference of the two models' text-only losses (Gemini's less the 2B's) over the same truth documents:
    # per page, (Gemini text - Gemini images) against (2B text - 2B images), resampled together (P7-1).
    tb_pages = two_b_pages(cols)
    loss_difference = None
    if tb_pages:
        ga, gb, docs, off = [], [], [], 0
        for b in DEV:
            gt, gi = per_page[("k7-t", b)], per_page[("k7-it", b)]
            bt, bi = tb_pages[("k7-t", b)], tb_pages[("k7-it", b)]
            ga += [int(bool(x)) - int(bool(y)) for x, y in zip(gt, gi)]
            gb += [int(bool(x)) - int(bool(y)) for x, y in zip(bt, bi)]
            docs += [[off + k for k in g] for g in documents(cols[b])]
            off += len(gt)
        loss_difference = {"a": "gemini 3.7 k7-t less k7-it", "b": "2b k7-t less k7-it", "boxes": list(DEV),
                           "two_b_pages_exact": {arm: sum(bool(v) for b in DEV for v in tb_pages[(arm, b)]) /
                                                 sum(v is not None for b in DEV for v in tb_pages[(arm, b)])
                                                 for arm in ("k7-it", "k7-t")},
                           **bootstrap(ga, gb, docs)}
    calls = list(latest().values())
    settled = [r for r in calls if r["event"] == "settle"]
    usage = defaultdict(Counter)
    for r in settled:
        u = r.get("usage") or {}
        usage[r["arm"]].update({"calls": 1, "valid": int(bool(r["valid"])), "in": u.get("prompt_tokens") or 0,
                                "out": u.get("completion_tokens") or 0,
                                "reasoning": (u.get("completion_tokens_details") or {}).get("reasoning_tokens") or 0,
                                "wall_s": r.get("wall_s") or 0})
    cost = defaultdict(float)
    for r in calls:
        cost[r["arm"]] += r["charge"]
    two_b = {r["arm"]: r for r in sm["pooled"] if r["model"] == "2b" and r["pool"] == "development"}
    out = {"tag": TAG, "model": "gemini-3.7-flash via the Stanford AI API gateway", "price": PRICE,
           "item_cap_usd": ITEM_CAP_USD, "spent": spent(), "billed": GW.billed(settled, "estimate"),
           "rows": rows, "pooled": pooled, "paired": comparisons, "incomplete": missing,
           "usage": {k: dict(v) for k, v in usage.items()}, "cost_by_arm": dict(cost),
           "two_b_development": two_b, "loss_difference": loss_difference}
    (RESULTS / "seg-window-gateway.json").write_text(json.dumps(out, indent=1, default=str) + "\n")
    report(out)


def pct(x):
    return f"{100 * x:.1f}%"


# Written after the 2026-11-04 score, corrected by W46.seg-gateway-wording (measurement review pass 7, P7-1); the
# figures are the report's tables above and seg-window-gateway.json (paired, loss_difference).
FINDINGS = [
    "- **Text alone costs Gemini little at K = 7.** Over the 551 pages the text-only arm is 2.7 points below the image "
    "control (89.6% against 92.3%; interval -9.5 to +1.6), a tie at this size, with the same boundary F1 (97.6 against "
    "97.3: three fewer false splits, one more merge). The loss is one boundary: on Dean the text-only arm makes one "
    "extra false split, at pages 37|38, which cuts a 16-page document and moves Dean from 93.4% to 85.2% (-8.2, "
    "-22.9 to 0.0); Gemini 3.8 with images makes the same split. Herrnstein is level at 91.2% and Deaver gains 1.4 "
    "points. Text only costs 46% of the image arm ($0.89 against $1.92 for the 187 windows) and answers in 4.6 s "
    "against 6.7 s.",
    "- **Gemini loses less than the 2B on these pages; the difference is not resolved.** The 2B lost 8.3 points on "
    "the same pages (90.9% to 82.6%). Gemini's loss less the 2B's, paired over the same 318 truth documents, is +5.6 "
    "points (-2.9 to +13.2), so the two losses are not shown to differ. The two routes also send different requests "
    "(the 2B's l1 prompt with 1,024 px images, Gemini's g1 with 1,600 px), so the comparison is of routes, not of "
    "models alone. A04's claim, that the neighbouring text makes the images redundant, is not contradicted for Gemini "
    "here and does not hold for the 2B.",
    "- **Window size is flat for Gemini too.** On Deaver, K = 3, 5, 7 and 10 lie within 1.4 points of each other, "
    "with images (92.2-93.6%) and without (93.6-95.0%): one document or less, every interval spanning zero. K = 7 and "
    "K = 10 are the cheapest image windows on Deaver ($0.56 and $0.57, against $0.64 at K = 5, which carries one "
    "unsettled 502's reservation, and $0.81 at K = 3), since smaller windows send each page more often.",
    "- **On Deaver, the whole folder is no better.** Gemini 3.7's whole folders on Deaver put 88.7% of pages in the "
    "exact document, 3.5 points under K = 7 (interval -11.3 to +3.6), with twice the false splits (8 against 4), for "
    "$0.20 against $0.56. The 3.7 folder arm was run on Deaver alone, the one box where 3.8's folders did worst "
    "(93.6% against 97.9% at K = 7, -4.3, -12.7 to 0.0); over the three boxes 3.8's folders were 2.3 points above its "
    "windows (-2.8 to +9.4) and on Dean 9.2 above (0.0 to +23.9), so this says nothing about 3.7's folders elsewhere.",
    "- **3.7 and 3.8 can sit 5-8 points apart on a box, and are level overall (SEG-9).** Pooled, the cached 3.8 "
    "windows are 1.5 points under 3.7's (-8.3 to +2.8, a tie). On Deaver 3.8 is 5.7 points higher: +1.3 to +11.8 "
    "over truth documents, 0.0 to +9.2 over the five folder runs (the unit fixed before the first score, too few to "
    "resample, so that interval is degenerate rather than a test). On Dean 3.7 is 8.2 points higher (-22.9 to 0.0 "
    "over truth documents; that is the same one 37|38 split). Neither box gap is clear of zero under both units, so "
    "this is not a ranking; it is why a 3.8 figure is not a stand-in for 3.7's on any one box, and why every arm here "
    "is read against the 3.7 control.",
    "",
    "## What this means",
    "",
    "1. **The cloud route keeps K = 7 with images.** No size beats it, none is cheaper, and on Deaver the whole folder "
    "is not better.",
    "2. **A text-only cloud window is a lead for a cheaper tier, not a default.** It roughly halves the token cost "
    "and lands within noise over three boxes; its point estimate is a loss of one boundary on one box. Phase 4 "
    "(W46.review-phase4) weighs it against the cost profiles; a test-box run would be needed before it ships.",
    "3. **The local 2B keeps its images** (seg-window-modality.md). Gemini loses less without them on these pages, "
    "but the difference between the two losses is not resolved.",
]


def report(o):
    P = {(p["arm"], tuple(p["boxes"])): p for p in o["pooled"]}
    D, S = tuple(DEV), (SUBSET,)

    def cell(arm, boxes):
        p = P.get((arm, boxes))
        if not p:
            return "not run"
        f = f" ({p['failed_units']} failed)" if p.get("failed_units") else ""
        return f"{pct(p['pages_exact'])} ({100 * p['boundary_f1']:.1f}; {p['false_splits']} / {p['false_merges']}){f}"

    def diff(a, b, boxes):
        c = next((c for c in o["paired"] if c["a"] == a and c["b"] == b and tuple(c["boxes"]) == boxes), None)
        if not c:
            return "—"
        return f"{100 * c['delta']:+.1f} ({100 * c['lo']:+.1f} to {100 * c['hi']:+.1f})"

    L = ["# W46.seg-window-modality-paid — Gemini 3.7 Flash: window size and text-only windows", "",
         "The paid half of W46.seg-window-modality (`seg-window-modality.md`), whose open arms found the trained 2B "
         "flat in window size with images and 4.6 to 19.7 points worse on text alone. This asks the same of a strong "
         "model: Gemini 3.7 Flash through the Stanford AI API gateway, low reasoning, temperature 0, the bench's g1 "
         "request (1600 px images, cached Apple Vision text), on the owner's development boxes. Arms, settings and "
         "the subset were fixed in `seg_window_gateway.py`'s docstring before any answer; the K = 7 image arm is the "
         "control every other arm is read against (SEG-9: 3.7 is never compared with the cached 3.8 figures, which "
         "are shown only for reference). Scores: `seg-window-gateway.json` (`seg_window_gateway.py score`).", "",
         "Pages in an exact document, with truth photos; boundary F1 and false splits / merges in brackets. The "
         "paired column is the arm less the control, in points, with a 95% paired bootstrap interval over the truth's documents.", "",
         "## Images against text alone (K = 7, all 551 pages)", "",
         "| Arm | Dean + Deaver + Herrnstein | Less the control |", "|---|---|---|",
         f"| Gemini 3.7, images and text (control) | {cell('k7-it', D)} | — |",
         f"| Gemini 3.7, text only | {cell('k7-t', D)} | {diff('k7-t', 'k7-it', D)} |",
         f"| Gemini 3.8, images and text (cached, reference) | {cell('3.8-k7-it', D)} | {diff('3.8-k7-it', 'k7-it', D)} |",
         ""]
    tb = o["two_b_development"]
    if tb.get("k7-it") and tb.get("k7-t"):
        L += [f"For the 2B on the same pages (`seg-window-modality.json`): {pct(tb['k7-it']['pages_exact'])} with images, "
              f"{pct(tb['k7-t']['pages_exact'])} text only (the l1 prompt with 1,024 px images, a different request).",
              ""]
    ld = o.get("loss_difference")
    if ld:
        L += [f"Gemini's text-only loss less the 2B's, paired over the same {ld['runs']} truth documents (both arms' "
              f"cached decisions; the 2B's rebuilt from W46.seg-window-modality's answers to "
              f"{pct(ld['two_b_pages_exact']['k7-it'])} and {pct(ld['two_b_pages_exact']['k7-t'])}): "
              f"{100 * ld['delta']:+.1f} points ({100 * ld['lo']:+.1f} to {100 * ld['hi']:+.1f}).", ""]
    else:
        L += ["The 2B's per-page decisions were not on disk, so the difference of the two losses is not computed.", ""]
    L += ["## Window size on Deaver (149 pages)", "",
          "| K | Images and text | Less K = 7 | Text only | Text less images |", "|---|---|---|---|---|"]
    for k in (3, 5, 7, 10):
        L.append(f"| {k} | {cell(f'k{k}-it', S)} | {diff(f'k{k}-it', 'k7-it', S) if k != 7 else '—'} | "
                 f"{cell(f'k{k}-t', S)} | {diff(f'k{k}-t', f'k{k}-it', S)} |")
    L += [f"| Whole folder | {cell('folder-it', S)} | {diff('folder-it', 'k7-it', S)} | not run | — |", "",
          f"Gemini 3.8 on Deaver for reference: {cell('3.8-k7-it', S)} at K = 7, {cell('3.8-folder-it', S)} whole folder.",
          ""]
    L += ["## Calls and cost", "",
          "| Arm | Calls | Parsed | Input tokens | Output tokens (reasoning) | Cost estimate | Mean seconds |",
          "|---|---:|---:|---:|---:|---:|---:|"]
    for arm, _ in ARMS:
        u = o["usage"].get(arm)
        if not u:
            continue
        L.append(f"| {arm} | {u['calls']} | {u['valid']} | {u['in']:,} | {u['out']:,} ({u['reasoning']:,}) | "
                 f"${o['cost_by_arm'].get(arm, 0):.3f} | {u['wall_s'] / u['calls']:.1f} |")
    L += ["", f"Item total ${o['spent']:.4f} of the ${o['item_cap_usd']:.2f} cap, at list token rates "
          f"(${PRICE[0]} / ${PRICE[1]} per million, reasoning included; the gateway offers no batch route); "
          f"{GW.billed_note([r for r in latest().values() if r['event'] == 'settle'], 'estimate')}. Every attempt "
          "is counted, failed ones included.", ""]
    if o["incomplete"]:
        L += ["Not scored: " + "; ".join(o["incomplete"]), ""]
    L += ["## Findings", ""] + FINDINGS + [""]
    import seg_card
    L += seg_card.card(
        truth="The owner-ruled development boxes Dean, Deaver and Herrnstein (no unsure gaps), with truth photos, "
              "as every development-box figure is. No drafter's or tested route's labels enter the truth.",
        selection="Every page of the three development boxes for K = 7; Deaver whole for the other sizes, chosen as "
                  "the box nearest the 150-page subset seg-window-modality.md recommended, before any answer. "
                  "Arms and settings fixed in the docstring before any call; no ABBYY text.",
        comparison="One model (Gemini 3.7 Flash), one route, one prompt family, temperature 0, low reasoning, in one "
                   "collection; each arm is read against the K = 7 image control on the same pages. Text-only "
                   "changes only the images and one paragraph. The whole-folder arm uses JPEG quality 45 and the "
                   "wh1 prompt, and the 3.8 figures are a different model on a different route, reference only.",
        noise="One run per arm (n = 518 document pages, 318 truth documents, on the three boxes; 141 pages, 89 "
              "documents on Deaver). Paired bootstrap intervals over truth documents cover document sampling, not "
              "rerun variation; the rerun floor is 1.4-3.2 points a box (SEG-10), so a gap inside it is a tie. The "
              "resampling unit was changed from folder runs after the first score: Deaver has five, too few to "
              "resample (the JSON keeps those intervals as by_folder_run, and the findings give both where they "
              "disagree on whether a gap clears zero). Deaver's documents are 1-6 pages, so one "
              "boundary moves Deaver by up to about 4 points.",
        scope="Whether a strong cloud model needs the images at K = 7 on the owner's photographs, and whether its "
              "window size matters on one box. It does not set the app's cloud window (that is options.md's and "
              "Phase 4's), does not rank 3.7 against 3.8, and the size sweep on one 149-page box cannot separate "
              "sizes within a few points.")
    (RESULTS / "seg-window-gateway.md").write_text("\n".join(L) + "\n")
    print("\n".join(L[:40]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("plan", "collect", "score"))
    ap.add_argument("--limit", type=int)
    ap.add_argument("--arm", choices=[x for x, _ in ARMS])
    a = ap.parse_args()
    {"plan": cmd_plan, "collect": cmd_collect, "score": cmd_score}[a.command](a)


if __name__ == "__main__":
    main()
