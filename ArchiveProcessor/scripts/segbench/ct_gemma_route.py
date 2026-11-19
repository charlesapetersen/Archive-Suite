#!/usr/bin/env python3
"""W47.ct-capture-gemma: the Processor's Gemma 3 12B label route, timed on this Mac through a real server.

    heavy-run.py run -- <lab venv>/bin/python ct_gemma_route.py [--n 60] [--port 8091]

`ct_read.py collect` ran Gemma 3 12B (4-bit MLX) in-process. The app asks a server instead (`ContainerLabelGemma`):
mlx-vlm's OpenAI endpoint here, with the app's request (ct_read's prompt, temperature 0, 640 tokens, reasoning off,
the upright photo as a JPEG at 1600 px on its long side, quality 0.9). This starts `mlx_vlm.server` on loopback, asks
`/v1/models` and picks the model as the app does, reads a seeded sample of the truth photos, and stops the server.
It records the time a label (the first call apart), how often the four fields the app takes agree with ct_read's
in-process reading of the same photo, and how often each reading is right against the truth on the cells ct_read
scores. Counts and figures only; no label text is written.
"""
import argparse
import base64
import io
import json
import os
import random
import statistics
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ct_read as R   # noqa: E402
import model_store   # noqa: E402

MODEL = R.MODELS["gemma3-12b-mlx4"][0]
FOUR = ["repository", "collection_title", "collection_number", "date"]   # ContainerLabelReader.localModelFields
OUT = os.path.join(R.OUT, "gemma-route.json")
KNOWN = ["mlx-community/gemma-3-12b-it-4bit", "gemma3:12b", "google/gemma-3-12b"]   # ContainerLabelGemma.ids


def pick(listed):
    """ContainerLabelGemma.pick: the measured build, another server's name for it, else a plain Gemma 3 12B name."""
    for k in KNOWN:
        if k in listed:
            return k
    for m in listed:
        s = m.lower()
        if ("gemma-3-12b" in s or "gemma3:12b" in s) and "cloud" not in s and "-pt" not in s:
            return m
    return None


def jpeg(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    scale = 1600 / max(im.size)
    if scale < 1:
        im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def post(url, body, timeout):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer local"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--port", type=int, default=8091)
    a = ap.parse_args()
    model_store.use()
    base = f"http://127.0.0.1:{a.port}/v1"
    drafts = R.draft_dir("gemma3-12b-mlx4")
    rows = {r["id"]: r for r in R.truth()}
    ids = sorted(r["id"] for r in R.truth()
                 if os.path.exists(R.page_of(r["id"])) and os.path.exists(os.path.join(drafts, r["id"] + ".json")))
    random.Random(R.SEED).shuffle(ids)
    ids = ids[: a.n]
    # Started with the model, as a user serving it would: mlx-vlm 0.7.4's cache listing skips this build (its
    # model.safetensors.index.json names five shards; the repo has two), so unloaded it is not in /v1/models.
    started = time.time()
    server = subprocess.Popen([sys.executable, "-m", "mlx_vlm.server", "--host", "127.0.0.1", "--port", str(a.port),
                               "--model", MODEL],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=os.environ.copy())
    rec = {"model": MODEL, "server": "mlx_vlm.server (mlx-vlm 0.7.4)", "photos": len(ids), "calls": []}
    try:
        for _ in range(300):
            try:
                with urllib.request.urlopen(base + "/models", timeout=5) as r:
                    listed = [m["id"] for m in json.load(r).get("data", [])]
                break
            except OSError:
                time.sleep(1)
        else:
            sys.exit("the server did not answer")
        rec["server_ready_s"] = round(time.time() - started, 1)
        chosen = pick(listed)
        rec["listed_exact"] = MODEL in listed
        rec["picked"] = None if chosen is None else ("the measured id" if chosen == MODEL else
                                                     "a snapshot path" if chosen.startswith("/") else "another name")
        print(f"server up; the app's pick: {rec['picked']}", flush=True)
        if chosen is None:
            sys.exit(f"the server lists no Gemma 3 12B: the app would not use it ({len(listed)} listed: {listed[:12]})")
        for k, mid in enumerate(ids, 1):
            body = {"model": chosen, "temperature": 0, "max_tokens": 640, "stream": False,
                    "messages": [{"role": "user", "content": [
                        {"type": "image_url",
                         "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(jpeg(R.page_of(mid))).decode()}},
                        {"type": "text", "text": R.PROMPT}]}],
                    "enable_thinking": False, "chat_template_kwargs": {"enable_thinking": False}, "think": False}
            t = time.time()
            try:
                got = post(base + "/chat/completions", body, 180)
                choice = got["choices"][0]
                raw, finish = choice["message"].get("content") or "", choice.get("finish_reason")
            except (OSError, KeyError, ValueError) as e:
                raw, finish = "", f"error: {type(e).__name__}"
            wall = round(time.time() - t, 2)
            mine = R.parse(raw) if finish != "length" else None
            theirs = json.load(open(os.path.join(drafts, mid + ".json"), encoding="utf-8")).get("parsed")
            agree = {f: (mine is not None and theirs is not None and R.same(f, mine.get(f), theirs.get(f))) for f in FOUR}
            # Right against the truth, on the cells ct_read scores (`cell_class`), the same cells for both readings.
            r = rows[mid]
            right = {}
            for f in FOUR:
                if not R.cell_class(r, f).startswith("out"):
                    want = r["fields"].get(f)
                    right[f] = [R.same(f, (mine or {}).get(f), want), R.same(f, (theirs or {}).get(f), want)]
            rec["calls"].append({"wall_s": wall, "finish": finish, "parsed": mine is not None, "agree": agree,
                                 "right": right})
            print(f"[{k}/{len(ids)}] {wall}s {finish} {'ok' if mine else 'unparsed'} "
                  f"agree {sum(agree.values())}/4", flush=True)
    finally:
        server.terminate()
        try:
            server.wait(30)
        except subprocess.TimeoutExpired:
            server.kill()
    calls = rec["calls"]
    later = [c["wall_s"] for c in calls[1:]]
    rec["first_call_s"] = calls[0]["wall_s"] if calls else None
    rec["median_s"] = round(statistics.median(later), 2) if later else None
    rec["mean_s"] = round(statistics.mean(later), 2) if later else None
    rec["max_s"] = max(later) if later else None
    rec["parsed"] = sum(c["parsed"] for c in calls)
    rec["agree_by_field"] = {f: sum(c["agree"][f] for c in calls) for f in FOUR}
    # [cells, right through the server, right in-process] per field
    rec["right_by_field"] = {f: [sum(f in c["right"] for c in calls),
                                 sum(c["right"][f][0] for c in calls if f in c["right"]),
                                 sum(c["right"][f][1] for c in calls if f in c["right"])] for f in FOUR}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=1)
    print(json.dumps({k: v for k, v in rec.items() if k != "calls"}, indent=1))


if __name__ == "__main__":
    main()
