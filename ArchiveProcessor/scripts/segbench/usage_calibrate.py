"""W36.seg-opt-usage: how much of a subscription's usage windows the Claude window route draws.

    uv run -q --python 3.12 --with numpy python usage_calibrate.py idle 240   # meter drift, no calls of ours
    uv run -q --python 3.12 --with numpy python usage_calibrate.py run Dean [max_windows]

(system python has no numpy, which ``method_window`` imports through ``methods``). ``idle`` is the control;
``run`` makes the window calls and reads the meter on every one. Results: ``segbench-results/usage.md``.

The bench's own Claude route (``method_window.py``) with one change: ``--output-format stream-json``,
whose ``rate_limit_event`` carries the account's meter (``unifiedWindows.five_hour`` / ``seven_day``
utilization, a fraction) on every call, beside the call's own tokens and notional list price. The
meter is reported in whole percent (0.26, never 0.2613; seen 2026-10-11), so a run must move it by
several points before a share can be read off it; the calls' notional price is exact and is the
quantity the share is scaled from.

Development boxes only (``refuse_test``); nothing is cached or scored, the answers are thrown away.
Each call is logged to ``usage-calibrate-calls.jsonl`` in the bench cache.
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import shutil
import subprocess
import sys
import threading
import time

import data
import method_window as W

LOG = data.CACHE_DIR / "usage-calibrate-calls.jsonl"
WORK = data.CACHE_DIR / "usage-calibrate"
GUARD_FIVE_HOUR = 0.70  # stop before the five-hour window gets near its limit
_lock = threading.Lock()


def call(prompt: str, workdir) -> dict:
    cmd = [W.CLAUDE_BIN, "-p", prompt, "--model", W.MODEL, "--output-format", "stream-json", "--verbose",
           "--allowedTools", "Read", "--permission-mode", "default", "--no-session-persistence"]
    t0 = time.time()
    r = subprocess.run(cmd, cwd=workdir, env=W.clean_env(), stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=W.CALL_TIMEOUT_S)
    rec = {"t0": t0, "wall_s": round(time.time() - t0, 1), "rc": r.returncode}
    for line in r.stdout.splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "rate_limit_event":
            u = ev["rate_limit_info"].get("unifiedWindows", {})
            rec["five_hour"] = u.get("five_hour", {}).get("utilization")
            rec["seven_day"] = u.get("seven_day", {}).get("utilization")
        elif ev.get("type") == "result":
            us = ev.get("usage", {})
            rec.update(notional_usd=ev.get("total_cost_usd"), turns=ev.get("num_turns"),
                       is_error=ev.get("is_error"), input=us.get("input_tokens"),
                       cache_write=us.get("cache_creation_input_tokens"),
                       cache_read=us.get("cache_read_input_tokens"), output=us.get("output_tokens"))
    return rec


def log(rec: dict) -> None:
    with _lock, open(LOG, "a") as fh:
        fh.write(json.dumps(rec) + "\n")


def probe(tag: str) -> dict:
    WORK.mkdir(parents=True, exist_ok=True)
    rec = call("Reply with only: OK", WORK)
    rec["event"] = tag
    log(rec)
    return rec


def idle(seconds: int) -> None:
    a = probe("idle-start")
    time.sleep(seconds)
    b = probe("idle-end")
    print(f"idle {seconds}s: five_hour {a.get('five_hour')} -> {b.get('five_hour')}, "
          f"seven_day {a.get('seven_day')} -> {b.get('seven_day')}")


def run(name: str, max_windows: int) -> None:
    W.refuse_test([name])
    col = data.load(name, with_exif=False)
    jobs = W.windows(len(col.pages))[:max_windows]
    stop = threading.Event()

    def one(i, a, b, delay):
        time.sleep(delay)
        if stop.is_set():
            return
        prompt, thumbs, nums = W.build_request(col, a, b)
        wd = WORK / name / f"{nums[0]:04d}-{nums[-1]:04d}"
        if wd.exists():
            shutil.rmtree(wd)
        wd.mkdir(parents=True)
        for n, t in zip(nums, thumbs):
            shutil.copyfile(t, wd / W.fname(n))
        rec = call(prompt, wd)
        rec.update(event="window", collection=name, window=nums, i=i)
        log(rec)
        if (rec.get("five_hour") or 0) >= GUARD_FIVE_HOUR:
            stop.set()
        print(f"{i} {nums[0]}-{nums[-1]} 5h={rec.get('five_hour')} 7d={rec.get('seven_day')} "
              f"${rec.get('notional_usd')}", flush=True)

    first = probe("run-start")
    with cf.ThreadPoolExecutor(W.CONCURRENCY) as ex:
        list(ex.map(lambda j: one(j[0], *j[1], j[0] * W.STAGGER_S if j[0] < W.CONCURRENCY else 0),
                    enumerate(jobs)))
    last = probe("run-end")
    print(f"run {name}: {len(jobs)} windows, five_hour {first.get('five_hour')} -> {last.get('five_hour')}, "
          f"seven_day {first.get('seven_day')} -> {last.get('seven_day')}")


if __name__ == "__main__":
    if sys.argv[1] == "idle":
        idle(int(sys.argv[2]))
    elif sys.argv[1] == "run":
        run(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 10**6)
    else:
        sys.exit(__doc__)
