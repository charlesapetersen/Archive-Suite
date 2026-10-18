#!/usr/bin/env python3
"""Text prompts against an institutional cluster’s vLLM server, sent as the app's local route sends a text call
(OpenAICompatibleClient.textCompletion with a local model: one user message, max_tokens, temperature 0, no reasoning
switch). First used for the dating benchmark (date_tagging.py export / import, 2026-10-17).

  cluster_text.py --pack DIR --out DIR --label L [--max-tokens 512] [--thinking-off]

The pack is requests.jsonl, one {"id", "prompt"} a line (date_tagging.py export). Each answer goes to
answers.jsonl as {"id", "raw", "finish", "usage", "wall_s"}; the reply is kept whole (the app strips reasoning
itself, so the importer does). A rerun with the same label skips answered ids. --thinking-off adds
chat_template_kwargs enable_thinking false, which the app does not send (KNOWN_ISSUES: reasoning not switched off),
to show what that costs. No network beyond localhost, no money.
"""
import argparse
import concurrent.futures as cf
import json
import os
from pathlib import Path
import threading
import time
import urllib.error
import urllib.request


def post(url, body, timeout=600):
    req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read()), None
    except urllib.error.HTTPError as e:
        return None, f"{e.code} {e.read()[:300]!r}"
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
        return None, repr(e)[:300]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", required=True); ap.add_argument("--out", required=True); ap.add_argument("--label", required=True)
    ap.add_argument("--url", default=os.environ.get("IC_URL", "http://127.0.0.1:8000"))
    ap.add_argument("--model", default=os.environ.get("IC_SERVED") or os.environ.get("IC_MODEL"))
    ap.add_argument("--max-tokens", type=int, default=512)   # TagGenerator's text call
    ap.add_argument("--thinking-off", action="store_true")
    ap.add_argument("--concurrency", type=int, default=16)
    a = ap.parse_args()
    out = Path(a.out) / a.label
    out.mkdir(parents=True, exist_ok=True)
    answers = out / "answers.jsonl"
    done = {json.loads(l)["id"] for l in answers.read_text().splitlines() if l.strip()} if answers.exists() else set()
    reqs = [json.loads(l) for l in (Path(a.pack) / "requests.jsonl").read_text().splitlines() if l.strip()]
    todo = [r for r in reqs if r["id"] not in done]
    print(f"{len(reqs)} prompts, {len(todo)} to send to {a.model}", flush=True)
    lock = threading.Lock()

    def one(r):
        body = {"model": a.model, "messages": [{"role": "user", "content": r["prompt"]}], "max_tokens": a.max_tokens,
                "temperature": 0}
        if a.thinking_off:
            body["chat_template_kwargs"] = {"enable_thinking": False}
        t0 = time.time()
        j, err = post(a.url, body)
        if j is None:
            return {"id": r["id"], "error": err}
        c = (j.get("choices") or [{}])[0]
        rec = {"id": r["id"], "raw": (c.get("message") or {}).get("content") or "", "finish": c.get("finish_reason"),
               "usage": j.get("usage") or {}, "wall_s": round(time.time() - t0, 2)}
        with lock:
            with answers.open("a") as f:
                f.write(json.dumps(rec) + "\n")
        return rec
    t0 = time.time()
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        res = list(ex.map(one, todo))
    errs = [r for r in res if "error" in r]
    summary = {"label": a.label, "model": a.model, "prompts": len(reqs), "sent": len(todo), "errors": len(errs),
               "first_error": errs[0]["error"] if errs else None, "max_tokens": a.max_tokens,
               "thinking_off": a.thinking_off, "wall_s": round(time.time() - t0, 1),
               "env": {k: os.environ.get(k) for k in ("SLURM_JOB_ID", "SLURMD_NODENAME", "IC_PRESET", "IC_VLLM_ARGS", "CLUSTER_NAME")}}
    (out / f"summary-{int(t0)}.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary), flush=True)
    raise SystemExit(1 if errs and len(errs) == len(todo) else 0)


if __name__ == "__main__":
    main()
