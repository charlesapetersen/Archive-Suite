#!/usr/bin/env python3
"""The app's local-route loop check (macOS LocalModelRoute.isRepetitionLoop), ported line for line, to replay it over
FarmShare's saved replies (W41.app-local-models' guards, measured 2026-10-16; segbench-results/local-route-guards.md).

  python3 app_loop_rule.py DIR...      # every reply under DIR: answered pages it would fail, capped pages it catches,
                                       # answered pages over the route's 4,096-token cap
  python3 app_loop_rule.py --self-test # the Swift test driver's cases

Swift counts unicode scalars and Python characters, which agree for this text."""
import glob, json, os, sys

def is_repetition_loop(text, min_loop_chars=2000, min_repeats=8):
    chars = text[-6000:]
    n = len(chars)
    if n < min_loop_chars:
        return False
    for period in range(4, 401):
        if period * min_repeats > n:
            break
        run, i = 0, n - 1
        while i - period >= 0 and chars[i] == chars[i - period]:
            run += 1; i -= 1
        looped = run + period
        if looped < min_loop_chars or looped < period * min_repeats:
            continue
        if len({c for c in chars[n - period:] if not c.isspace()}) >= 3:
            return True
    return False

def main(roots):
    out = {"answered": 0, "answered_fired": 0, "capped": 0, "capped_fired": 0, "answered_over_4096": 0, "with_tokens": 0}
    over = []
    for root in roots:
        for f in glob.glob(os.path.join(root, "**", "replies", "*.json"), recursive=True):
            j = json.load(open(f)); m = j.get("meta") or {}; r = j.get("reply") or {}
            raw = r.get("raw") or ""
            if m.get("finish") == "stop" and m.get("status") == "ok":
                out["answered"] += 1; out["answered_fired"] += is_repetition_loop(raw)
                if m.get("completion_tokens"):
                    out["with_tokens"] += 1
                    if m["completion_tokens"] > 4096: out["answered_over_4096"] += 1; over.append(m["completion_tokens"])
            elif m.get("finish") == "length":
                out["capped"] += 1; out["capped_fired"] += is_repetition_loop(raw)
        for f in glob.glob(os.path.join(root, "_meta", "**", "*.json"), recursive=True):  # bulk: text + token counts
            m = json.load(open(f)); t = f.replace("/_meta/", "/")[:-5] + ".txt"
            if m.get("status") != "ok" or not os.path.exists(t): continue
            out["answered"] += 1; out["answered_fired"] += is_repetition_loop(open(t, errors="replace").read())
            if m.get("completion_tokens"):
                out["with_tokens"] += 1
                if m["completion_tokens"] > 4096: out["answered_over_4096"] += 1; over.append(m["completion_tokens"])
    out["over_4096_tokens"] = sorted(over)
    print(json.dumps(out))

def self_test():
    loop = "The committee met on Tuesday and resolved to adopt the report.\n" * 60
    assert is_repetition_loop("Minutes\n" + loop)                                   # a repeated sentence
    assert not is_repetition_loop("and so on. " * 20)                                 # a short repeat
    assert not is_repetition_loop("|      |      |      |\n" * 200)                  # a form's blank rows
    assert not is_repetition_loop("Contents " + "." * 3000)                           # dot leaders
    print("the Swift driver's cases pass")


if __name__ == "__main__":
    self_test() if sys.argv[1:] == ["--self-test"] else main(sys.argv[1:])
