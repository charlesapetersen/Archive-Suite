#!/usr/bin/env python3
"""W41.farmshare-seg. Segmentation's windows (method_openrouter's seg-large request) against an institutional cluster's vLLM server.

  cluster_seg.py pack   --out /tmp/fs-segpack [--box Deaver]     # on the Mac: every window's exact request, for scp
  cluster_seg.py pack   --out DIR --final                        # all five boxes, once, for the frozen teacher
  python method_openrouter.py report-teacher                # its five-box score, as report-five scores
  cluster_seg.py run    --pack DIR --out DIR --label L           # on a GPU node (job.sbatch, mode seg): send, check, time
  cluster_seg.py import --run DIR                                # on the Mac: answers into the cache; then
  python method_openrouter.py report Deaver                 # the FarmShare row beside the OpenRouter ones

Why a pack: a window's request holds seven page images made by ``sips`` from the bench's photos and each page's
OCR text, and neither exists on the node. So the Mac builds every request with method_openrouter's own
``L.request``, ``image_jpeg`` and ``cache_key`` (the images as the JPEG bytes the request carries, stored once per
page), the node only sends them, and the answers come home under the cache keys the Mac's ``judge`` looks up. The
node checks each answer with ``method_window.parse_answer`` and asks once more at twice the token limit, as
``collect`` does; a window still unparsed is recorded as failed and votes 0.5 on its gaps. A request the server
refuses (a 4xx: a context too short for seven images, say) stops the run rather than becoming a silent failed
window. A window the server never answered is still to do, eight in a row stop the run with exit 75, and a rerun
with the same --label skips every window already in answers.jsonl (job.sbatch labels a run by its preset, so
every submission adds to one run).

No money, no network beyond localhost. The pack carries what OpenRouter received in W41.seg-large: Deaver's page
images at 1024 px and its OCR text, a development box (method_window.refuse_test).
"""
from __future__ import annotations
import argparse
import base64
import concurrent.futures as cf
import json
import os
from pathlib import Path
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import method_openrouter as R  # noqa: E402  (no I/O at import; the node needs numpy, which vLLM brings)
import method_window as W  # noqa: E402
import method_local as L  # noqa: E402
from cluster_ocr import atomic_write, env_info, DEAD_SERVER  # noqa: E402

# The teacher by default; IC_SEG_KEY names a student or a baseline (method_openrouter.FARMSHARE), in pack and run.
KEY = os.environ.get("IC_SEG_KEY", "fs-qwen3.5-27b")  # gitleaks:allow (a model key name, not a secret)


def cmd_pack(a):
    import data
    out = Path(a.out)
    if out.exists():
        raise SystemExit(f"{out} exists; pick a new path")
    boxes = a.box or ["Deaver"]
    if a.final:  # W41.seg-27b-test: the one test-box run, all five boxes, only for the committed frozen teacher
        if KEY not in R.frozen_keys():
            raise SystemExit(f"{KEY} is not frozen for the test boxes ({R.frozen_keys()})")
        boxes = list(R.FIVE)
    else:
        W.refuse_test(boxes)
    windows, pages = [], set()
    for box in boxes:
        col = data.load(box, with_exif=False)
        for lo, hi in W.windows(len(col.pages)):
            prompt, thumbs, nums = L.request(col, lo, hi)
            for n, t in zip(nums, thumbs):
                if (box, n) not in pages:
                    atomic_write(out / "images" / box / f"{n}.jpg", R.image_jpeg(t, R.side_of(KEY)))
                    pages.add((box, n))
            windows.append({"box": box, "window": nums, "cache_key": R.cache_key(KEY, prompt, thumbs),
                            "prompt": prompt})
    atomic_write(out / "windows.jsonl", "".join(json.dumps(w) + "\n" for w in windows).encode())
    atomic_write(out / "pack.json", json.dumps({"key": KEY, "model": R.entry(KEY)[0], "side": R.side_of(KEY),
        "max_tokens": R.MAX_TOKENS, "prompt_version": R.PROMPT_VERSION, "boxes": boxes, "pages": len(pages),
        "windows": len(windows), "made": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=1).encode())
    print(f"{len(windows)} windows, {len(pages)} pages -> {out}  "
          f"(copy with: scp -r {out} <user>@<cluster-login>:)")


def send(url, body, timeout=900):
    """One request. Returns (reply json or None, status): 'ok', 'rejected' (4xx) or 'error' (no answer)."""
    req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read()), "ok"
    except urllib.error.HTTPError as e:
        if 400 <= e.code < 500:
            return {"error": f"{e.code} {e.read()[:300]!r}"}, "rejected"
        return {"error": f"{e.code}"}, "error"
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
        return {"error": repr(e)[:300]}, "error"


def read_window(url, pack, w):
    """The window's answer as ``collect`` gets it: a retry at twice the token limit if the first does not parse.
    A request may name the pages whose images it carries (``images``; [] for a text-only window, W46.seg-window-modality)
    and its own token limit (``max_tokens``, for a whole folder); without them, every page's image and R.MAX_TOKENS."""
    urls = [R.data_url((pack / "images" / w["box"] / f"{n}.jpg").read_bytes()) for n in w.get("images", w["window"])]
    rec = {"cache_key": w["cache_key"], "collection": w["box"], "window": w["window"], "status": R.FAILED}
    t0 = time.time()
    limit = w.get("max_tokens", R.MAX_TOKENS)
    for attempt, max_tokens in enumerate((limit, 2 * limit)):
        j, status = send(url, R.request_body(KEY, w["prompt"], urls, max_tokens))
        if status != "ok":
            return {**rec, "status": status, "error": j["error"], "wall_s": round(time.time() - t0, 1)}
        c = (j.get("choices") or [{}])[0]; u = j.get("usage") or {}
        text = L.strip_thinking((c.get("message") or {}).get("content") or "")
        rec.update(attempt=attempt, result=text, finish=c.get("finish_reason"), prompt_tokens=u.get("prompt_tokens"),
                   gen_tokens=u.get("completion_tokens"))
        try:
            W.parse_answer(text, w["window"])
        except (W.ParseError, TypeError, ValueError, KeyError, AttributeError) as e:
            rec["error"] = f"{type(e).__name__}: {e}"[:200]
            continue
        rec["status"] = "ok"; rec.pop("error", None)
        break
    rec["wall_s"] = round(time.time() - t0, 1)
    return rec


def answer_lines(path):
    """answers.jsonl's records; a line a killed job left half-written is skipped (its window is sent again)."""
    out = []
    for line in path.read_text().splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def cmd_run(a):
    pack, out = Path(a.pack), Path(a.out) / a.label
    meta = json.loads((pack / "pack.json").read_text())
    model = a.model or os.environ.get("IC_SERVED") or os.environ.get("IC_MODEL")
    if meta["key"] != KEY or model != meta["model"]:
        raise SystemExit(f"the pack is for {meta['model']} ({meta['key']}); the server is serving {model}")
    windows = [json.loads(l) for l in (pack / "windows.jsonl").read_text().splitlines()]
    windows = windows[:a.limit or None]   # a wave pilot (IC_LIMIT)
    answers = out / "answers.jsonl"
    done = {r["cache_key"] for r in answer_lines(answers)} if answers.exists() else set()
    todo = [w for w in windows if w["cache_key"] not in done]
    out.mkdir(parents=True, exist_ok=True)
    print(f"{len(windows)} windows, {len(todo)} to send", flush=True)
    if a.warmup and todo:  # untimed: CUDA graphs, the vision encoder's first batch
        read_window(a.url, pack, todo[0])
    lock, stop, streak, results = threading.Lock(), threading.Event(), [0], []

    def work(w):
        if stop.is_set():
            return
        rec = read_window(a.url, pack, w)
        with lock:
            results.append(rec)
            streak[0] = streak[0] + 1 if rec["status"] == "error" else 0
            if streak[0] >= DEAD_SERVER or rec["status"] == "rejected":
                stop.set()
            if rec["status"] in ("ok", R.FAILED):
                with answers.open("a") as f:
                    f.write(json.dumps({**rec, "t": time.time()}) + "\n"); f.flush(); os.fsync(f.fileno())
        print(f"{rec['collection']} {rec['window'][0]}-{rec['window'][-1]} {rec['status']} {rec.get('wall_s')}s "
              f"{rec.get('error', '')[:120]}", flush=True)

    t0 = time.time()
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        list(ex.map(work, todo))
    wall = time.time() - t0
    final = [r for r in results if r["status"] in ("ok", R.FAILED)]
    pages = sum(len(r["window"]) for r in final) * meta["pages"] / max(1, sum(len(w["window"]) for w in windows))
    summary = {"label": a.label, "boxes": meta.get("boxes") or [meta.get("box")], "windows": len(windows), "sent": len(results),
               "ok": sum(r["status"] == "ok" for r in final), "failed": sum(r["status"] == R.FAILED for r in final),
               "rejected": [r["window"] for r in results if r["status"] == "rejected"],
               "left": len(todo) - len(final), "wall_s": round(wall, 1), "concurrency": a.concurrency,
               # a box's pages an hour per GPU: each window's pages counted at the box's overlap, so a whole box
               # read in wall_s gives pages / wall_s
               "pages_per_hour_per_gpu": round(pages / wall * 3600 / a.gpus, 1) if final and wall else None,
               "mean_prompt_tokens": sum(r.get("prompt_tokens") or 0 for r in final) / len(final) if final else None,
               "mean_gen_tokens": sum(r.get("gen_tokens") or 0 for r in final) / len(final) if final else None,
               "env": env_info(), "t": time.strftime("%Y-%m-%dT%H:%M:%S")}
    atomic_write(out / f"summary-{int(t0)}.json", json.dumps(summary, indent=1).encode())
    print(json.dumps({k: v for k, v in summary.items() if k != "env"}))
    if summary["rejected"]:
        sys.exit(1)
    sys.exit(0 if summary["left"] == 0 else 75)


def cmd_import(a):
    """Mac side. Every answer under its key, and this key's call log rewritten from the run (one run per key)."""
    import data
    run = Path(a.run)
    recs = answer_lines(run / "answers.jsonl")
    want = {}
    for box in {r["collection"] for r in recs}:
        col = data.load(box, with_exif=False)
        for lo, hi in W.windows(len(col.pages)):
            prompt, thumbs, nums = L.request(col, lo, hi)
            want[R.cache_key(KEY, prompt, thumbs)] = nums
    stale = [r["window"] for r in recs if r["cache_key"] not in want]
    if stale:
        raise SystemExit(f"{len(stale)} answers are for requests this checkout no longer makes (first {stale[0]}): "
                         "the prompt, OCR text or thumbnails changed since the pack; pack and run again")
    last = {}
    for r in recs:  # a rerun after a crash cannot repeat a window, but keep the last if one ever does
        last[r["cache_key"]] = r
    where = R.entry(KEY)[2]
    log = []
    for k, r in last.items():
        R.cache(KEY).put(k, {"status": r["status"], "result": r.get("result", ""), "model": R.entry(KEY)[0],
                             "provider": where})
        log.append({"collection": r["collection"], "window": r["window"], "attempt": r.get("attempt", 0),
                    "model": R.entry(KEY)[0], "wall_s": r["wall_s"], "provider": where,
                    "prompt_tokens": r.get("prompt_tokens"), "gen_tokens": r.get("gen_tokens"), "cost": 0,
                    "finish": r.get("finish"), "t": r.get("t"), "event": r["status"], "run": run.name})
    atomic_write(R.log_path(KEY), "".join(json.dumps(x) + "\n" for x in log).encode())
    print(f"{len(last)} windows imported into window-or-{KEY} "
          f"({sum(r['status'] == 'ok' for r in last.values())} ok); now: python method_openrouter.py report")


def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack"); p.add_argument("--out", required=True); p.add_argument("--box", action="append", help="a development box (repeatable; default Deaver)")
    p.add_argument("--final", action="store_true", help="W41.seg-27b-test: all five boxes, test boxes included, "
                   "for the frozen teacher only (method_openrouter.py freeze-teacher, committed)")
    p = sub.add_parser("run")
    p.add_argument("--pack", required=True); p.add_argument("--out", required=True); p.add_argument("--label", required=True)
    p.add_argument("--url", default=os.environ.get("IC_URL", "http://127.0.0.1:8000"))
    p.add_argument("--model", help="served model name (default $IC_MODEL)")
    p.add_argument("--concurrency", type=int, default=int(os.environ.get("IC_CONCURRENCY") or 16))
    p.add_argument("--gpus", type=int, default=int(os.environ.get("IC_GPUS", 1)))
    p.add_argument("--warmup", action="store_true", help="one untimed window first")
    p.add_argument("--limit", type=int, default=int(os.environ.get("IC_LIMIT") or 0), help="first N windows only (a wave pilot)")
    p = sub.add_parser("import"); p.add_argument("--run", required=True, help="runs/seg/<label>, brought back")
    a = ap.parse_args()
    {"pack": cmd_pack, "run": cmd_run, "import": cmd_import}[a.cmd](a)


if __name__ == "__main__":
    main()
