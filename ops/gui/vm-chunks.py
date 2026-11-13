#!/usr/bin/env python3
"""vm-chunks.py — deal an enumerated UITest selection into chunks balanced by measured test time (W40.vm-gate-unpause).

Both VM entry points use it, through tart-lib.sh: the health gate runs ONE chunk per invocation (a whole lane no
longer fits its budget on the macOS 27.2 guest: Notes ~6,250 s of tests, Reader ~3,000 s), and the runner's
VM_SPLIT=N runs all N in fresh guests. Count-split chunks were badly uneven (943, 1,919, 2,405 and 795 s), hence time.

  plan   --tests LIST --budget S [--times TSV ...] [--default S]   chunks of at most S estimated seconds
  plan   --tests LIST --chunks N [--times TSV ...] [--default S]   the smallest budget that gives at most N chunks
  select --tests LIST --plan PLAN --index K                        chunk K (0-based) of a stored plan, reconciled
  times  LOG ...                                                    passed tests' seconds from xcodebuild logs (TSV)

LIST is `-enumerate-tests` narrowed to the selectors: one Bundle/Class/test per line, in run order. A TSV row is
`Bundle/Class/test<TAB>seconds`; later files and rows win, so the gate's learned times override the committed seed
(ops/gui/vm-test-times.tsv). A test with no measurement is estimated at --default seconds (40: the Notes lane's
mean in fresh guests, 2026-11-12). A chunk line is space-separated selectors: a whole class (Bundle/Class) when the
class fits the budget, its single tests (Bundle/Class/test) when the class alone is over it. Chunks are contiguous
in run order, so a chunk runs its tests in the order the whole lane would.

`select` is what keeps a stored plan honest across a cycle: a selector that no longer matches a listed test is
dropped, and a listed test that no plan line covers (a test or class added since the plan was made) is added to
the plan's last chunk, so no test can fall out of a cycle and none runs twice in it.
  count  --tests LIST --selectors A,B                               how many listed tests the selectors cover It prints the chunk's selectors, one line, and on
stderr the number of chunks in the plan. K at or past the plan's end is an error (exit 3): the caller replans.
"""
import argparse
import re
import sys

# Passed tests only: a failure's time is often a wait running out, and a skip's (a missing fixture) is near zero.
TEST_CASE = re.compile(r"^Test Case '-\[([A-Za-z0-9_]+)\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' passed \(([0-9.]+) seconds\)")


def read_tests(path):
    tests, seen = [], set()
    with open(path) as f:
        for line in f:
            t = line.strip()
            if t.count("/") == 2 and t not in seen:
                seen.add(t)
                tests.append(t)
    return tests


def read_times(paths):
    times = {}
    for p in paths or []:
        try:
            with open(p) as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 2 and parts[0].count("/") == 2:
                        try:
                            times[parts[0]] = float(parts[1])
                        except ValueError:
                            pass
        except FileNotFoundError:
            pass
    return times


def units(tests, times, default, budget):
    """Run-ordered (selector, seconds) units: a class, or each of its tests when the class alone is over budget."""
    classes, order = {}, []
    for t in tests:
        c = t.rsplit("/", 1)[0]
        if c not in classes:
            classes[c] = []
            order.append(c)
        classes[c].append((t, times.get(t, default)))
    out = []
    for c in order:
        total = sum(s for _, s in classes[c])
        if budget is None or total <= budget:
            out.append((c, total))
        else:
            out.extend(classes[c])
    return out


def pack(us, budget):
    chunks, cur, cur_s = [], [], 0.0
    for sel, s in us:
        if cur and cur_s + s > budget:
            chunks.append(cur)
            cur, cur_s = [], 0.0
        cur.append(sel)
        cur_s += s
    if cur:
        chunks.append(cur)
    return chunks


def plan(tests, times, default, budget=None, nchunks=None):
    if budget is not None:
        return pack(units(tests, times, default, budget), budget)
    # The smallest budget that packs into at most N chunks (a class is split only when it alone is over that budget).
    lo, hi = 0.0, sum(times.get(t, default) for t in tests)
    best = pack(units(tests, times, default, hi), hi)
    for _ in range(50):
        mid = (lo + hi) / 2
        ch = pack(units(tests, times, default, mid), mid)
        if len(ch) <= nchunks:
            best, hi = ch, mid
        else:
            lo = mid
    return best


def covers(sel, test):
    return test == sel or test.startswith(sel + "/")


def select(tests, plan_lines, index):
    lines = [[s for s in l.split() if any(covers(s, t) for t in tests)] for l in plan_lines]
    if index >= len(lines):
        return None, len(lines)
    chunk = lines[index]
    if index != len(lines) - 1:
        return chunk, len(lines)
    # Only the last chunk takes what no plan line covers, so a test added mid-cycle runs once, not in every
    # remaining chunk (Tier-2 review, 2026-11-13).
    every = [s for l in lines for s in l]
    for t in tests:
        if not any(covers(s, t) for s in every):
            c = t.rsplit("/", 1)[0]
            # A new class goes in whole; a new test of a class the plan split goes in alone.
            sel = t if any(s.startswith(c + "/") for s in every) else c
            if sel not in chunk:
                chunk.append(sel)
                every.append(sel)
    return chunk, len(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--tests", required=True)
    p.add_argument("--times", action="append")
    p.add_argument("--default", type=float, default=40.0)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--budget", type=float)
    g.add_argument("--chunks", type=int)
    s = sub.add_parser("select")
    s.add_argument("--tests", required=True)
    s.add_argument("--plan", required=True)
    s.add_argument("--index", type=int, required=True)
    t = sub.add_parser("times")
    t.add_argument("logs", nargs="+")
    c = sub.add_parser("count")
    c.add_argument("--tests", required=True)
    c.add_argument("--selectors", required=True)
    a = ap.parse_args()

    if a.cmd == "count":
        sels = [x for x in a.selectors.split(",") if x]
        print(sum(1 for t in read_tests(a.tests) if any(covers(s, t) for s in sels)))
        return 0

    if a.cmd == "times":
        times = {}
        for path in a.logs:
            try:
                with open(path, errors="replace") as f:
                    for line in f:
                        m = TEST_CASE.match(line)
                        if m:
                            times["%s/%s/%s" % (m[1], m[2], m[3])] = float(m[4])
            except FileNotFoundError:
                pass
        for k in times:
            print("%s\t%d" % (k, round(times[k])))
        return 0

    tests = read_tests(a.tests)
    if not tests:
        print("vm-chunks: no Bundle/Class/test lines in %s" % a.tests, file=sys.stderr)
        return 2
    if a.cmd == "plan":
        if a.chunks is not None and a.chunks < 1:
            print("vm-chunks: --chunks must be at least 1", file=sys.stderr)
            return 2
        if a.budget is not None and a.budget <= 0:
            print("vm-chunks: --budget must be positive", file=sys.stderr)
            return 2
        for ch in plan(tests, read_times(a.times), a.default, a.budget, a.chunks):
            print(" ".join(ch))
        return 0
    with open(a.plan) as f:
        plan_lines = [l for l in f.read().splitlines() if l.strip()]
    chunk, n = select(tests, plan_lines, a.index)
    print(n, file=sys.stderr)
    if chunk is None:
        return 3
    print(" ".join(chunk))
    return 0


if __name__ == "__main__":
    sys.exit(main())
