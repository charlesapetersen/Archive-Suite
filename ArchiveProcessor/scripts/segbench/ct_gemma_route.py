#!/usr/bin/env python3
"""W47.ct-capture-gemma: the Processor's Gemma 3 12B label route, timed on this Mac through a real server.

    heavy-run.py run -- <lab venv>/bin/python ct_gemma_route.py [--n 60] [--port 8091]
    python3 ct_gemma_route.py --report      # segbench-results/ct-gemma-route.md from the run's JSON (no model)

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


def sample(n):
    """The seeded draw: truth photos that ct_read's in-process Gemma also read."""
    drafts = R.draft_dir("gemma3-12b-mlx4")
    ids = sorted(r["id"] for r in R.truth()
                 if os.path.exists(R.page_of(r["id"])) and os.path.exists(os.path.join(drafts, r["id"] + ".json")))
    random.Random(R.SEED).shuffle(ids)
    return ids[:n]


def report():
    rec = json.load(open(OUT, encoding="utf-8"))
    rows = {r["id"]: r for r in R.truth()}
    ids = sample(rec["photos"])
    per = []   # per photo: right through the server, in-process, Vision + parser; cells
    by_field = {f: [0, 0, 0, 0] for f in FOUR}
    for mid, c in zip(ids, rec["calls"]):
        r, v = rows[mid], R.reading(rows[mid], "vision") or {}
        t = [0, 0, 0, 0]
        for f, (a, b) in c["right"].items():
            got = [a, b, R.same(f, v.get(f), r["fields"].get(f)), 1]
            t = [x + y for x, y in zip(t, got)]
            by_field[f] = [x + y for x, y in zip(by_field[f], got)]
        per.append(t)

    def gap(k):
        rng, g = random.Random(R.SEED), []
        for _ in range(4000):
            smp = [per[rng.randrange(len(per))] for _ in per]
            g.append(100 * sum(p[0] - p[k] for p in smp) / sum(p[3] for p in smp))
        g.sort()
        n = sum(p[3] for p in per)
        return f"{100 * sum(p[0] - p[k] for p in per) / n:+.1f} ({g[100]:+.1f} to {g[3899]:+.1f})"

    n = sum(p[3] for p in per)
    pc = lambda k, m: f"{k} of {m} ({100 * k / m:.1f}%)"   # noqa: E731
    L = ["# Gemma 3 12B for a label's titles, through the app's route (W47.ct-capture-gemma)", "",
         "The Processor asks Gemma 3 12B on a server on this Mac for a box or folder label's repository, collection "
         "title, collection number and date when the gateway is off or local (`ContainerLabelGemma`). `ct-read.md` "
         "scored Gemma in-process (`mlx_vlm` `stream_generate` on the photo file); this times and checks the app's "
         f"request through {rec['server']}: `ct_read.py`'s prompt, temperature 0, 640 tokens, reasoning off, the "
         "upright photo as a JPEG at 1600 px, quality 0.9. Built by `scripts/segbench/ct_gemma_route.py --report`.", "",
         "## Time a label on this Mac", "",
         f"- {rec['photos']} label photos, one at a time, on the 18 GB M3 Pro: median **{rec['median_s']} s** a photo "
         f"(mean {rec['mean_s']}, slowest {rec['max_s']}), the first call apart ({rec['first_call_s']} s). The server "
         f"answered {rec['server_ready_s']} s after starting with the model preloaded. In-process, `ct-read.md` "
         "measured a median 14.93 s and an 8.04 GB peak; the server's memory was not measured here (MLX's is Metal "
         "memory, not the process's resident size).",
         f"- {rec['parsed']} of {rec['photos']} replies parsed (an unparsed one gives no Gemma values; the parser's stand).",
         f"- The app picked {rec['picked']} because the server was started with it: mlx-vlm 0.7.4's "
         "cache listing skips this build, whose `model.safetensors.index.json` names five shards where the repo "
         "has two, so a server that has not loaded it does not list it, and the app does not use it.", "",
         "## Right against the truth, on the same cells", "",
         f"The cells `ct_read.py` scores on these photos ({n}: the owner's, rule-settled and unanimous cells, less "
         "carried ones). Each reading against the truth; gaps are the server route less each other, with a 95% "
         "bootstrap interval over photos.", "",
         "| field | cells | through the server | in-process (ct-read) | Vision + parser |", "|---|---|---|---|---|"]
    for f in FOUR:
        s, i, v, m = by_field[f]
        L.append(f"| {f.replace('_', ' ')} | {m} | {pc(s, m)} | {pc(i, m)} | {pc(v, m)} |")
    S, I, V = (sum(p[k] for p in per) for k in range(3))
    L += [f"| **all four** | {n} | {pc(S, n)} | {pc(I, n)} | {pc(V, n)} |", "",
          f"- Server less in-process: {gap(1)} points, a tie within this sample's noise, though "
          "the point estimate is lower (collection number and title most); the two readings differ on some photos (a "
          "resized JPEG through the server's chat template, against the photo file).",
          f"- Server less Vision + parser: {gap(2)} points, on these {rec['photos']} photos a lead whose interval "
          "touches zero; `ct-read.md`'s 195 photos are the figure for choosing the route.", "",
          "## Measurement card", "",
          "- **Truth:** W47.ct-truth-final's (as `ct-read.md`): the owner's answers and notes, his rules, and for the "
          "rest the three drafters unanimous. Gemma drafted none of it.",
          f"- **Selection:** {rec['photos']} photos drawn with seed {R.SEED} from the truth photos the in-process run "
          "read; not by any tested route.",
          "- **Comparison:** the same photos and cells for all three readings; the same prompt and temperature for "
          "both Gemma readings, which differ in the image path (the app's 1600 px JPEG through the server's template "
          "against `mlx_vlm`'s own load of the photo) and in run date.",
          "- **Noise:** one pass each at temperature 0; paired bootstrap over photos; no rerun floor measured, so a gap "
          "inside its interval is a tie.",
          "- **Scope:** mlx-vlm only (LM Studio and Ollama serve other builds, unmeasured); labels alone on an idle "
          "Mac, not interleaved with a local OCR model on the same server; this researcher's photos.", ""]
    path = os.path.join(R.HERE, "..", "..", "segbench-results", "ct-gemma-route.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))
    print(os.path.normpath(path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--port", type=int, default=8091)
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()
    if a.report:
        return report()
    model_store.use()
    base = f"http://127.0.0.1:{a.port}/v1"
    drafts = R.draft_dir("gemma3-12b-mlx4")
    rows = {r["id"]: r for r in R.truth()}
    ids = sample(a.n)
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
