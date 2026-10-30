#!/usr/bin/env python3
"""The measurement review's cadence and checks (owner, 2026-10-30; W46.measure-review).

    measure-review.py upkeep        tick W46.measure-review-due when a review is due (the upkeep hook calls this)
    measure-review.py status        the results landed since the last review, and whether one is due
    measure-review.py done SHA      record that a review covered everything up to SHA (the review session runs this)
    measure-review.py cards [SHA]   result reports changed since SHA (default: the last review) with no measurement card
    measure-review.py deps          open plan items and gates whose prerequisites are missing, and dependency cycles

Why it exists. W47.item-fields-truth judged the app against a truth two small open models built, and the audit that
followed (execution-plans/processing-review/11-measurement-audit.md) found the same classes of flaw across the W46
review: weak or circular truth, sets chosen by a tested route or by ABBYY text, noise read as a result, unequal
comparisons, verdicts too strong for their sample, and stale dependencies. Each result is written by one engine
session, which judges its own measurement; nothing looked across them. So a standing queue item, W46.measure-review,
runs on Fable at max effort (its `(effort: max)` marker; Agent Manager policy.py maps max to the escalated model)
whenever enough new results have landed, and reworks the queue on what it finds.

Cadence. A review is due when MIN_RESULTS commits on origin/main have touched a result path since the last review, or
when CADENCE_DAYS have passed and at least one has. The last review is $STATE/measure-review/last.json
({"commit", "at"}), written by `done`; the first upkeep seeds it with SEED, the audit's own commit. Opening is
`plan-edit.py due W46.measure-review-due NOTE`, which ticks the gate in the plan's `## RECURRING` section; the
standing item then runs, and re-arms the gate when it is done. Nothing here edits a tracked file, so upkeep (which
runs between sessions in the primary checkout) never leaves an uncommitted change.

Tests: ops/agent/tests/test_measure_review.py.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "autonomous"))

GATE = "W46.measure-review-due"
ITEM = "W46.measure-review"
SEED = "66daa3c1"            # the measurement audit's commit: the first review covers what landed after it
MIN_RESULTS = 8
CADENCE_DAYS = 7
RESULT_PATHS = ["ArchiveProcessor/segbench-results", "ArchiveOCRBench/data"]
CARD = re.compile(r"(?mi)^#{1,4}\s+measurement card\b")
TAG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


class Env:
    def __init__(self, a):
        self.repo = a.repo or os.environ.get("AGENT_REPO") or os.getcwd()
        self.state = os.path.join(a.state or os.environ.get("AGENT_STATE")
                                  or os.path.expanduser("~/.local/state/archive-autonomous"), "measure-review")
        self.plan = a.plan or os.environ.get("AUTONOMOUS_PLAN") or os.path.join(self.repo, ".maintenance/AUTONOMOUS_PLAN.md")
        self.now = a.now if a.now is not None else time.time()


def git(env, *args):
    r = subprocess.run(["git", "-C", env.repo, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout


def head(env):
    for ref in ("origin/main", "HEAD"):
        try:
            return git(env, "rev-parse", "--verify", "-q", ref).strip()
        except RuntimeError:
            continue
    raise RuntimeError("no origin/main or HEAD")


def write_last(env, d):
    os.makedirs(env.state, exist_ok=True)
    path = os.path.join(env.state, "last.json")
    with open(path + ".tmp", "w") as f:
        json.dump(d, f)
    os.replace(path + ".tmp", path)


def last(env):
    """The last review, seeding it with the audit's commit the first time. Unreadable state is re-seeded, never fatal."""
    path = os.path.join(env.state, "last.json")
    try:
        with open(path) as f:
            d = json.load(f)
        if isinstance(d, dict) and isinstance(d.get("commit"), str) and isinstance(d.get("at"), (int, float)):
            return d
    except (OSError, ValueError):
        pass
    d = {"commit": SEED, "at": env.now, "seeded": True}
    write_last(env, d)
    return d


def results_since(env, commit):
    out = git(env, "rev-list", "--first-parent", "%s..%s" % (commit, head(env)), "--", *RESULT_PATHS)
    return [c for c in out.split() if c]


def gate_ticked(env):
    """Ticked in `## RECURRING` only: a quoted line elsewhere (a Daemon Report entry) must not stop the cadence."""
    try:
        text = open(env.plan).read()
    except OSError:
        return False
    m = re.search(r"(?m)^## RECURRING.*$", text)
    if not m:
        return False
    nxt = re.search(r"(?m)^## ", text[m.end():])
    text = text[m.end():m.end() + nxt.start()] if nxt else text[m.end():]
    return re.search(r"(?m)^\s*[-*]\s+\[[xX]\]\s*\**%s\b" % re.escape(GATE), text) is not None


def due(env):
    """(due?, reason, number of result commits, the last review)."""
    lr = last(env)
    n = len(results_since(env, lr["commit"]))
    days = (env.now - lr["at"]) / 86400
    if n >= MIN_RESULTS:
        return True, "%d result commits since the last review (%s)" % (n, lr["commit"][:8]), n, lr
    if n and days >= CADENCE_DAYS:
        return True, "%.0f days and %d result commit(s) since the last review (%s)" % (days, n, lr["commit"][:8]), n, lr
    return False, "%d result commit(s), %.1f days since the last review (%s)" % (n, days, lr["commit"][:8]), n, lr


def plan_edit(env, action, values):
    spec = importlib.util.spec_from_file_location("plan_edit", os.path.join(SCRIPTS, "plan-edit.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.edit(Path(env.plan), action, values)


def upkeep(env):
    if gate_ticked(env):
        print("measure-review: %s is ticked; the review has not re-armed it yet" % GATE)
        return 0
    ok, why, _, _ = due(env)
    if not ok:
        print("measure-review: not due: " + why)
        return 0
    plan_edit(env, "due", [GATE, "review due: " + why])
    print("measure-review: opened %s: %s" % (ITEM, why))
    return 0


def done(env, sha):
    full = git(env, "rev-parse", "--verify", "-q", sha + "^{commit}").strip()
    write_last(env, {"commit": full, "at": env.now})
    print("measure-review: the next review covers what lands after %s" % full[:8])
    return 0


def cards(env, since=None):
    """Result reports added or changed since `since` that carry no measurement card (root CLAUDE.md)."""
    since = since or last(env)["commit"]
    names = git(env, "diff", "--name-only", "--diff-filter=AM", "%s..%s" % (since, head(env)), "--",
                "ArchiveProcessor/segbench-results").split()
    missing = []
    for rel in names:
        if not rel.endswith(".md"):
            continue
        try:
            text = git(env, "show", "%s:%s" % (head(env), rel))
        except RuntimeError:
            continue
        if not CARD.search(text):
            missing.append(rel)
    return missing


def checkboxes(text):
    """{tag: (open?, [prerequisites])} over every checkbox line, fenced and quoted lines skipped. A tag is open when
    any of its lines is open (the resolver's rule for a prerequisite), and its prerequisites are every line's."""
    out, fence = {}, False
    for line in text.splitlines():
        if re.match(r"^\s*(```|~~~)", line):
            fence = not fence
            continue
        if fence or re.match(r"^\s*>", line):
            continue
        m = re.match(r"^\s*[-*]\s+\[([ xX])\]\s*", line)
        if not m:
            continue
        t = TAG.match(re.sub(r"^`", "", re.sub(r"^\*+\s*", "", line[m.end():])))
        if not t:
            continue
        deps = [d.replace("`", "").strip() for c in re.findall(r"\(blocked-on:([^)]*)\)", line) for d in c.split(",")]
        prev = out.get(t[0])
        is_open = m.group(1) == " "
        out[t[0]] = (is_open or (prev[0] if prev else False), (prev[1] if prev else []) + [d for d in deps if d])
    return out


def deps(env):
    """Problems in the plan's dependencies: prerequisites with no checkbox anywhere (plan, SUITE_TODO, the DONE
    archive), and cycles among open items. A missing tag blocks forever (next-queue-item.sh treats it as unmet)."""
    plan = checkboxes(open(env.plan).read())
    known = set(plan)
    for name in ("SUITE_TODO.md", "SUITE_TODO_DONE.md"):
        try:
            known |= set(checkboxes(open(os.path.join(env.repo, name)).read()))
        except OSError:
            pass
    problems = []
    for tag, (is_open, pre) in sorted(plan.items()):
        if is_open:
            for p in sorted(set(pre)):
                if p not in known:
                    problems.append("%s waits on %s, which has no checkbox anywhere" % (tag, p))
    graph = {t: sorted({p for p in pre if p in plan and plan[p][0]}) for t, (o, pre) in plan.items() if o}
    seen, stack, cycles = set(), [], []

    def walk(n):
        if n in stack:
            cyc = stack[stack.index(n):] + [n]
            if not any(set(cyc) == set(c) for c in cycles):
                cycles.append(cyc)
            return
        if n in seen:
            return
        seen.add(n)
        stack.append(n)
        for m in graph.get(n, []):
            walk(m)
        stack.pop()

    for t in sorted(graph):
        walk(t)
    problems += ["cycle: " + " -> ".join(c) for c in cycles]
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", choices=["upkeep", "status", "done", "cards", "deps"])
    ap.add_argument("sha", nargs="?")
    for k in ("repo", "state", "plan"):
        ap.add_argument("--" + k)
    ap.add_argument("--now", type=float, help=argparse.SUPPRESS)  # tests
    a = ap.parse_args(argv)
    env = Env(a)
    if a.cmd == "upkeep":
        return upkeep(env)
    if a.cmd == "done":
        if not a.sha:
            ap.error("done needs the commit the review covered")
        return done(env, a.sha)
    if a.cmd == "status":
        ok, why, _, lr = due(env)
        print(("due: " if ok else "not due: ") + why + ("; the gate is ticked" if gate_ticked(env) else ""))
        for c in results_since(env, lr["commit"]):
            print("  " + git(env, "log", "-1", "--format=%h %ad %s", "--date=short", c).strip())
        return 0
    if a.cmd == "cards":
        miss = cards(env, a.sha)
        for rel in miss:
            print("no measurement card: " + rel)
        return 1 if miss else 0
    problems = deps(env)
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as exc:
        print("measure-review: " + str(exc), file=sys.stderr)
        sys.exit(2)
