"""The owner's-cues prompt through Claude and Codex, on one development box (owner, 2026-10-05).

    python method_window_cues.py collect claude [Deaver]   # claude -p, subscription (cached)
    python method_window_cues.py collect opus [Deaver]     # claude -p with Opus 5.5 (cached)
    python method_window_cues.py collect codex [Deaver]    # codex exec, subscription (cached)
    python method_window_cues.py report [Deaver]           # scores; segbench-results/cues-models-<box>.md

Owner, 2026-10-05, after Gemini 3.8 Flash matched window-claude on Deaver: "Test Claude on just that box so
we can compare. Also try Codex for comparison." So the three models get the SAME prompt: method_gemini's
g1 (the owner's domain cues and the approved rules), with only the parts that say how the images arrive and
how to answer changed for each route. Windows, combining and assembly are method_window's.

CLAUDE: ``claude -p`` with Sonnet 5.5 (window-claude's model), images as files read with the Read tool,
exactly method_window's route; OPUS is the same route with Opus 5.5 (owner, 2026-10-05: "make sure to
test Claude on Opus as well. Use only the one box"). CODEX: ``codex exec`` with gpt-6.1-sol at reasoning effort low (the
cheapest Gemini 3.8 Flash setting matched its high one), images attached with ``-i``, read-only sandbox,
run from a scratch folder outside git. Each route has its own response cache and call log. Both run on
the owner's subscriptions: no money, but usage. USAGE GUARD: calls stop when the five-hour window passes
70% (Claude; Vision OCR has priority on it) or 85% (Codex).
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

import data
from methods import METHODS  # noqa: F401  (loads method_window and method_gemini in order)
import method_window as W
import method_gemini as G
from score import derived, score_labels

PROMPT_VERSION = "c1"
CODEX_BIN = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
CODEX_MODEL, CODEX_EFFORT = "gpt-6.1-sol", "low"
USAGE_SH = Path("/Users/cp1/Claude/Archive Suite/ops/autonomous/usage-window.sh")
ROUTES = ("claude", "opus", "codex")
CLAUDE_MODELS = {"claude": "claude-sonnet-5-5", "opus": "claude-opus-5-5"}
CLAUDE_READING_LOG = Path.home() / ".local/state/visionocr-autonomous/last-session.log"
GUARD = {"claude": 70, "opus": 70, "codex": 85}
CONCURRENCY = 3
STAGGER_S = 4.0

_IMAGES_G = ("The\n{k} images above are consecutive photographs from that stream, each introduced by its page "
             "number.\nAnswer from the images.")
_ANSWER_G = "ANSWER in the JSON schema given:"
_ANSWER = ('ANSWER with one JSON object and nothing else (no prose, no code fence), shaped\n'
           '{{"pages": [{{"page": <n>, "kind": "box" | "folder" | "document"}}, ...], "boundaries": '
           '[{{"between": [<n>, <n+1>], "decision": "new" | "continue", "cue": "<text>", "confidence": <0-1>}}, '
           '...]}}.')
_IMAGES = {
    "claude": ("This window\nholds {k} consecutive photographs from that stream. Their files are in the current "
               "directory:\n\n{files}\n\nFIRST read every one of these image files with the Read tool (issue all "
               "the Read calls together, in one turn).\nThen answer from the images."),
    "codex": ("The\n{k} images attached are consecutive photographs from that stream, attached in this order:\n\n"
              "{files}\n\nAnswer from the images; do not run commands."),
}


def prompt_template(route: str) -> str:
    assert G.PROMPT.count(_IMAGES_G) == 1 and G.PROMPT.count(_ANSWER_G) == 1, "prompt g1 changed"
    return G.PROMPT.replace(_IMAGES_G, _IMAGES["codex" if route == "codex" else "claude"]).replace(_ANSWER_G, _ANSWER)


def build_request(route, col, a, b):
    nums = [col.pages[i].n for i in range(a, b)]
    thumbs = [data.thumbnail(col.name, col.pages[i], W.THUMB_PX) for i in range(a, b)]
    if any(t is None for t in thumbs):
        raise RuntimeError(f"{col.name} {nums}: thumbnail failed")
    files = "\n".join(f"- {W.fname(n)}  (page {n})" for n in nums)
    texts = "\n".join(f"--- page {n} ---\n{W.page_text(col, i)}" for n, i in zip(nums, range(a, b)))
    gaps = ", ".join(f"[{x}, {x + 1}]" for x in nums[:-1])
    prompt = prompt_template(route).format(k=len(nums), files=files, texts=texts, gaps=gaps, max_text=W.MAX_TEXT,
                                           pages=", ".join(str(n) for n in nums))
    return prompt, thumbs, nums


def model_of(route):
    return CLAUDE_MODELS.get(route) or f"{CODEX_MODEL}/{CODEX_EFFORT}"


CACHES = {r: data.ResponseCache(f"window-cues-{r}") for r in ROUTES}
LOGS = {r: data.CACHE_DIR / f"window-cues-{r}-calls.jsonl" for r in ROUTES}
_log_lock = threading.Lock()


def log(route, rec):
    with _log_lock:
        with open(LOGS[route], "a") as fh:
            fh.write(json.dumps(rec) + "\n")


def call_codex(prompt, wd: Path, files: list[Path]) -> dict:
    out = wd / "answer.txt"
    cmd = [CODEX_BIN, "exec", "--skip-git-repo-check", "-s", "read-only", "-m", CODEX_MODEL,
           "-c", f'model_reasoning_effort="{CODEX_EFFORT}"', "-C", str(wd), "-o", str(out)]
    for f in files:
        cmd += ["-i", str(f)]
    cmd.append("-")
    env = {k: v for k, v in os.environ.items() if not k.startswith("CODEX_") or k == "CODEX_HOME"}
    t0 = time.time()
    r = subprocess.run(cmd, cwd=wd, env=env, input=prompt, capture_output=True, text=True,
                       timeout=W.CALL_TIMEOUT_S)
    msg = (r.stdout + r.stderr)[-600:]
    if r.returncode != 0 or not out.exists():
        if any(s in msg.lower() for s in ("usage limit", "rate limit", "429")):
            raise W.UsageLimit(msg)
        raise RuntimeError(f"codex exit {r.returncode}: {msg}")
    return {"result": out.read_text(), "_wall_s": time.time() - t0}


def judge(route):
    def judge_window(col, a, b, allow_call=True):
        prompt, thumbs, nums = build_request(route, col, a, b)
        key = data.response_cache_key(model_of(route), PROMPT_VERSION, prompt, [data.file_hash(t) for t in thumbs])
        hit = CACHES[route].get(key)
        if hit is not None:
            return W.parse_answer(hit["result"], nums)
        if not allow_call:
            return None
        wd = W.WORK / f"cues-{route}" / col.name / f"{nums[0]:04d}-{nums[-1]:04d}"
        shutil.rmtree(wd, ignore_errors=True)
        wd.mkdir(parents=True)
        files = []
        for n, t in zip(nums, thumbs):
            shutil.copyfile(t, wd / W.fname(n))
            files.append(wd / W.fname(n))
        last = None
        for attempt in range(3):
            try:
                out = call_codex(prompt, wd, files) if route == "codex" else W.call_claude(prompt, wd)
            except W.UsageLimit:
                log(route, {"collection": col.name, "window": nums, "event": "usage-limit", "t": time.time()})
                raise
            except Exception as e:  # noqa: BLE001 - logged and retried with back-off
                last = e
                log(route, {"collection": col.name, "window": nums, "event": "error", "attempt": attempt,
                            "error": str(e)[:400], "t": time.time()})
                time.sleep(30 * (attempt + 1) ** 2)
                continue
            rec = {"collection": col.name, "window": nums, "event": "call", "attempt": attempt,
                   "model": model_of(route), "wall_s": round(out["_wall_s"], 1), "t": time.time()}
            try:
                parsed = W.parse_answer(out.get("result") or "", nums)
            except W.ParseError as e:
                last = e
                rec.update(event="parse-failure", error=str(e)[:300])
                log(route, rec)
                continue
            log(route, rec)
            CACHES[route].put(key, {"result": out["result"], "model": model_of(route), "wall_s": out["_wall_s"]})
            shutil.rmtree(wd, ignore_errors=True)
            return parsed
        raise RuntimeError(f"{col.name} {nums}: gave up after 3 attempts: {last}")
    return judge_window


def used_pct(route) -> int:
    # Claude: the Vision OCR daemon's live session log carries the account's readings; claude -p --output-format
    # json carries none, and this script's default LOG (the Archive Suite daemon's) is a Codex session now.
    args = ["--raw"] + (["--codex-latest"] if route == "codex" else [str(CLAUDE_READING_LOG)])
    r = subprocess.run(["bash", str(USAGE_SH), *args], capture_output=True, text=True)
    try:
        return int(float(r.stdout.split()[0]))
    except (ValueError, IndexError):
        return 100  # no reading: stop rather than spend blind (the 16:55 run spent past its guard this way)


def collect(route, names):
    W.refuse_test(names)
    if route in CLAUDE_MODELS:
        W.MODEL = CLAUDE_MODELS[route]  # read by W.call_claude; one route per process
    jw = judge(route)
    jobs = [(c, a, b) for n in names for c in [data.load(n, with_exif=False)] for a, b in W.windows(len(c.pages))]
    todo = [j for j in jobs if jw(*j, allow_call=False) is None]
    print(f"{route}: {len(jobs)} windows, {len(todo)} to call", flush=True)
    stop, done, t0 = threading.Event(), [0], time.time()

    def work(job, delay):
        time.sleep(delay)
        if stop.is_set():
            return
        if done[0] % 6 == 0 and (u := used_pct(route)) >= GUARD[route]:
            stop.set()
            print(f"USAGE GUARD: {route} window {u}% >= {GUARD[route]}%, stopping", flush=True)
            return
        col, a, b = job
        try:
            jw(col, a, b)
        except W.UsageLimit as e:
            stop.set()
            print(f"USAGE LIMIT, stopping: {str(e)[:300]}", flush=True)
            return
        except Exception as e:  # noqa: BLE001
            print(f"FAILED {col.name} {col.pages[a].n}-{col.pages[b - 1].n}: {str(e)[:200]}", flush=True)
            return
        done[0] += 1
        print(f"[{done[0]}/{len(todo)} {time.time() - t0:.0f}s] {col.name} {col.pages[a].n}-{col.pages[b - 1].n}",
              flush=True)

    with cf.ThreadPoolExecutor(CONCURRENCY) as ex:
        futs = [ex.submit(work, j, STAGGER_S * k if k < CONCURRENCY else 0) for k, j in enumerate(todo)]
        for f in cf.as_completed(futs):
            f.result()
    print(f"{route}: done in {time.time() - t0:.0f}s", flush=True)


def score(name, judge_fn) -> dict:
    col = data.load(name)
    pred = W.assemble(col, W.combine(col, judge_fn), False)
    return derived(score_labels(col.labels, pred.labels, name))


def report(name) -> str:
    import compare_gemini as CG
    rows = []
    rows.append(("Claude Sonnet 5.5, old prompt w1 (window-claude)", score(name, W.judge_window)))
    CG.use("gemini-3.8-flash", "low", 0.75, 3.75)
    rows.append(("Gemini 3.8 Flash, low, prompt g1", score(name, G.judge_window)))
    for route, label in (("claude", "Claude Sonnet 5.5, cues prompt"), ("opus", "Claude Opus 5.5, cues prompt"),
                         ("codex", f"Codex {CODEX_MODEL}, {CODEX_EFFORT}, cues prompt")):
        try:
            rows.append((label, score(name, judge(route))))
        except RuntimeError as e:
            rows.append((label, {"missing": str(e)[:120]}))
    lines = [f"# The owner's-cues prompt across models, {name} (development box)", "",
             "Same windows and assembly; the cues prompt is method_gemini's g1 with only the image-delivery and "
             "answer-format lines changed per route (method_window_cues.py). Own photo labels. One box.", "",
             "| model and prompt | pages in exact doc | false splits | false merges |", "|---|---|---|---|"]
    for label, r in rows:
        if "missing" in r:
            lines.append(f"| {label} | not collected | | |")
        else:
            lines.append(f"| {label} | {100 * r['pages_in_exact_doc']:.1f}% | {r['false_splits']} | {r['false_merges']} |")
    return "\n".join(lines) + "\n"


def main(argv) -> int:
    if len(argv) >= 2 and argv[0] == "collect" and argv[1] in ROUTES:
        collect(argv[1], argv[2:] or ["Deaver"])
    elif argv and argv[0] == "report":
        for name in argv[1:] or ["Deaver"]:
            W.refuse_test([name])
            text = report(name)
            print(text)
            (data.HERE.parent.parent / "segbench-results" / f"cues-models-{name}.md").write_text(text)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
