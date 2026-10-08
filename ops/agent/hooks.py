#!/usr/bin/python3
"""The Agent Manager's queue, holds and status hooks for this repo (CONTRACT.md section 2, in the manager's repo).

    hooks.py queue | holds | status

Thin adapters: the queue is ops/autonomous/next-queue-item.sh's answer, with its rows' lanes and uses read by
worker-state.py's own lanes() and uses(); the holds are the plan's HOLD QUEUE, the WORK QUEUE's [hold] items and
the unwalked Daemon Report entries; the status is status-digest.sh's counts. The scripts are found beside this
file (../autonomous); the data comes from $AGENT_REPO (the plan is gitignored and lives only in the primary
checkout) and $AGENT_STATE. Read-only, stdlib only, no network.
"""
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "autonomous"))
REPO = os.environ.get("AGENT_REPO") or os.path.normpath(os.path.join(HERE, "..", ".."))
STATE = os.environ.get("AGENT_STATE") or os.path.expanduser("~/.local/state/archive-autonomous")
PLAN = os.environ.get("AUTONOMOUS_PLAN") or os.path.join(REPO, ".maintenance", "AUTONOMOUS_PLAN.md")
PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HOLD_MARK = re.compile(r"\[hold\]|needs:\s*owner", re.I)     # worker-state.py's hold test
EFFORT = re.compile(r"\(effort:\s*(low|medium|high|xhigh|max)\)")
ESTIMATE = re.compile(r"~\d+(?:-\d+)?\s+sessions?\b")         # the daemon's estimate_sessions evidence
CHECKBOX = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s*")
DATE = re.compile(r"\b(20\d\d-\d\d-\d\d)\b")
WALKED = re.compile(r"^### .*✅.*[Ww]alkthrough")         # status-digest.sh's stop line
REPORT_HEADER = re.compile(r"^## (Daemon Report|Morning Review)")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def worker_state():
    spec = importlib.util.spec_from_file_location("worker_state", os.path.join(SCRIPTS, "worker-state.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def resolver_rows():
    """(rc, [(status, tag, text)]) from next-queue-item.sh, claims ignored (claims are the engine's)."""
    env = dict(os.environ, AUTONOMOUS_IGNORE_CLAIMS="1", AUTONOMOUS_PLAN=PLAN, PATH=PATH + ":" + os.environ.get("PATH", ""))
    p = subprocess.run(["/bin/bash", os.path.join(SCRIPTS, "next-queue-item.sh"), REPO], env=env,
                       capture_output=True, text=True, timeout=120)
    rows = []
    if p.returncode in (0, 4):
        for line in p.stdout.splitlines():
            f = line.split("\t", 2)
            if len(f) == 3:
                rows.append(tuple(f))
    return p.returncode, rows, (p.stdout + p.stderr).strip()


def tag_of(rest):
    """The tag rule next-queue-item.sh uses: strip a leading bold marker and one backtick, take the first token."""
    rest = re.sub(r"^\*+\s*", "", rest)
    rest = re.sub(r"^`", "", rest)
    m = re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", rest)
    return m.group(0) if m else None


def section(text, header):
    """The lines of `## <header>...` up to the next `## ` heading."""
    out, inside = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            if inside:
                break
            inside = line.startswith("## " + header)
            continue
        if inside:
            out.append(line)
    return out


def clean(s, n=200):
    s = re.sub(r"\*\*|`", "", s).strip()
    s = re.sub(r"^#+\s*", "", s)
    return s if len(s) <= n else s[:n - 3] + "..."


# ---- queue ------------------------------------------------------------------------------------------------

def queue():
    rc, rows, msg = resolver_rows()
    if rc == 3:
        return 2
    if rc not in (0, 4):
        print("next-queue-item.sh exited %d: %s" % (rc, msg[:300]), file=sys.stderr)
        return 1
    ws = worker_state()
    items, runnable = [], 0
    for status, tag, text in rows:
        d = {"tag": tag, "text": clean(text, 300), "lanes": sorted(ws.lanes(text))}
        try:
            d["uses"] = ws.uses(text).split(",")
        except ValueError as e:
            d["uses"] = []
            if status == "ok":
                status, d["reason"] = "blocked:", "worker-state refuses it: %s" % e
        if status.startswith("blocked:"):
            d["status"] = "blocked"
            unmet = [t for t in status[len("blocked:"):].split(",") if t]
            if unmet:
                d["blocked_on"] = unmet
                d.setdefault("reason", "waits for " + ", ".join(unmet))
        elif HOLD_MARK.search(text):
            d["status"], d["reason"] = "hold", "held for the owner ([hold] or needs: owner)"
        else:
            d["status"] = "ok"
            runnable += 1
        m = EFFORT.search(text)
        if m:
            d["effort"] = m.group(1)
        m = ESTIMATE.search(text)
        if m:
            d["estimate"] = m.group(0)
        n = (read(os.path.join(STATE, "item-progress", tag)) or "").strip()
        if n.isdigit():
            d["sessions_since_progress"] = int(n)
        items.append(d)
    for d in items:
        print(json.dumps(d, ensure_ascii=False, sort_keys=True))
    return 0 if runnable else (3 if items else 2)


# ---- holds ------------------------------------------------------------------------------------------------

def pending_holds(rows):
    """Tags that are the ONLY unmet blocker of some open, otherwise-runnable WORK QUEUE item."""
    out = set()
    for status, tag, text in rows:
        if HOLD_MARK.search(text):
            continue                       # held itself: not otherwise runnable
        unmet = [t for t in status[len("blocked:"):].split(",") if t] if status.startswith("blocked:") else []
        if len(unmet) == 1:
            out.add(unmet[0])
    return out


BLOCKED_ON = re.compile(r"\(blocked-on:([^)]*)\)")


def tag_states():
    """(done, pending): next-queue-item.sh's tag -> state map, from every anchored checkbox line in SUITE_TODO.md,
    SUITE_TODO_DONE.md and the plan, fenced and blockquoted lines skipped. A tag is done iff it is ticked somewhere
    and open nowhere."""
    done, pend = set(), set()
    for path in (os.path.join(REPO, "SUITE_TODO.md"), os.path.join(REPO, "SUITE_TODO_DONE.md"), PLAN):
        fence = False
        for line in (read(path) or "").splitlines():
            if re.match(r"^\s*(```|~~~)", line):
                fence = not fence
                continue
            if fence or re.match(r"^\s*>", line):
                continue
            m = CHECKBOX.match(line)
            if m:
                tag = tag_of(line[m.end():])
                if tag:
                    (pend if m.group(1) == " " else done).add(tag)
    return done, pend


def own_prerequisites_met(text, states):
    """A hold is ready to decide only when its own (blocked-on: ...) tags are all done (R1 review finding 4)."""
    done, pend = states
    for clause in BLOCKED_ON.findall(text):
        for t in clause.split(","):
            t = t.replace("`", "").strip()
            if t and (t in pend or t not in done):
                return False
    return True


def short_hash(s):
    return hashlib.sha1(s.strip().encode("utf-8")).hexdigest()[:8]


DIGEST_ENTRY = re.compile(r"^(### 20\d\d-\d\d-\d\d|- \*\*\[|\*\*\[)")   # status-digest.sh's DR_ENTRY_RE


def report_entries(plan):
    """The first lines of the Daemon Report's entries above the newest `### ✅ … walkthrough` heading, newest
    first. Each blank-separated block is an entry, and a block opening with a `### ` heading carries the blocks
    after it until the next heading. status-digest.sh's rule (a line opening `### <date>`, `- **[` or `**[`) is
    used instead when it finds every entry the block rule finds; today's entries are plain paragraphs, which it
    misses."""
    inside, body = False, []
    for line in plan.splitlines():
        if REPORT_HEADER.match(line):
            inside = True
            continue
        if inside and (line.startswith("## ") or WALKED.match(line)):
            break
        if inside:
            body.append(line)
    digest = [line for line in body if DIGEST_ENTRY.match(line)]
    blocks, cur = [], []
    for line in body + [""]:
        if line.strip():
            cur.append(line)
        elif cur:
            blocks.append(cur)
            cur = []
    entries = []
    for b in blocks:
        if b[0].startswith("### ") or not entries or not entries[-1][0].startswith("### "):
            entries.append(list(b))
        else:
            entries[-1].extend(b)
    if digest and len(digest) >= len(entries):
        return digest
    return [e[0] for e in entries]


def holds():
    plan = read(PLAN)
    if plan is None:
        print("no plan at %s" % PLAN, file=sys.stderr)
        return 1
    rc, rows, msg = resolver_rows()
    if rc not in (0, 3, 4):
        print("next-queue-item.sh exited %d: %s" % (rc, msg[:300]), file=sys.stderr)
        return 1
    pending, states, seen, out = pending_holds(rows), tag_states(), set(), []
    for line in section(plan, "HOLD QUEUE"):
        m = CHECKBOX.match(line)
        if not m or m.group(1) != " ":
            continue
        tag = tag_of(line[m.end():])
        if not tag or tag in seen:
            continue
        seen.add(tag)
        ready = tag in pending and own_prerequisites_met(line, states)
        out.append({"key": tag, "text": clean(line[m.end():]), "permanent": not ready, "source": "HOLD QUEUE"})
    for status, tag, text in rows:
        if HOLD_MARK.search(text) and tag not in seen:
            seen.add(tag)
            ready = tag in pending and not status.startswith("blocked:")
            out.append({"key": tag, "text": clean(text), "permanent": not ready, "source": "WORK QUEUE"})
    # The Daemon Report is ONE pending item, keyed by its newest unwalked entry: a new entry notifies once, and the
    # owner walks the report as a whole (decision 2026-10-08, R1 review finding 3).
    entries = report_entries(plan)
    if entries:
        newest = clean(entries[0], 100)
        d = {"key": "daemon-report:" + short_hash(entries[0]),
             "text": "Daemon Report: %d entr%s since the last walkthrough; newest: %s"
                     % (len(entries), "y" if len(entries) == 1 else "ies", newest),
             "permanent": False, "source": "Daemon Report"}
        m = DATE.search(entries[0])
        if m:
            d["since"] = m.group(1)
        out.append(d)
    for d in out:
        print(json.dumps(d, ensure_ascii=False, sort_keys=True))
    return 0


# ---- status -----------------------------------------------------------------------------------------------

def git(*args):
    p = subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True, timeout=8)
    return p.returncode, p.stdout


def count(path, pattern):
    t = read(path)
    return 0 if t is None else sum(1 for line in t.splitlines() if re.match(pattern, line))


def health():
    """status-digest.sh's Health line: a RED in last-gate.log (unless a gate is running), else how far HEAD is
    past the last green sha."""
    gate_red = ""
    running = subprocess.run(["pgrep", "-f", r"ops/autonomous/health-gate\.sh"], capture_output=True).returncode == 0
    if not running:
        for line in (read(os.path.join(STATE, "last-gate.log")) or "").splitlines():
            if line.startswith("HEALTH GATE: RED"):
                gate_red = " ".join(re.sub(r"^HEALTH GATE: RED[^A-Za-z0-9]*", "", line).split())
                break
    code = " ".join(s for s in gate_red.split() if s not in ("context-budget", "tracker-sync", "coherence"))
    if code:
        return "The last full check FAILED: %s; the build or tests are broken" % code
    if gate_red:
        return "The last full check FAILED: %s; the code built and passed, a document is over its size limit" % gate_red
    last = (read(os.path.join(STATE, "last-gate")) or "").strip()
    if last and git("cat-file", "-e", last + "^{commit}")[0] == 0:
        rc, n = git("rev-list", "--count", last + "..HEAD")
        n = int(n.strip()) if rc == 0 and n.strip().isdigit() else None
        if n == 0:
            return "Build and tests passed, on the current code"
        if n is not None:
            return "Build and tests passed, %d change%s ago" % (n, "" if n == 1 else "s")
    return "Not checked yet; the next run will do a full build and test"


def status():
    rc, out = git("log", "--since=24 hours ago", "--oneline")
    d = {"done_24h": len(out.splitlines()) if rc == 0 else 0,
         "left": count(os.path.join(REPO, "SUITE_TODO.md"), r"^\s*[-*]\s+\[ \]"),
         "finished": count(os.path.join(REPO, "SUITE_TODO.md"), r"^\s*[-*]\s+\[[xX]\]")
         + count(os.path.join(REPO, "SUITE_TODO_DONE.md"), r"^\s*[-*]\s+\[[xX]\]"),
         "health": health()}
    if not os.path.exists(os.path.join(STATE, "keychain-partition-fixed")):
        d["note"] = "Keychain not set up; it may ask for a password. Run once: ./ops/autonomous/fix-keychain-access.sh"
    print(json.dumps(d, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    cmds = {"queue": queue, "holds": holds, "status": status}
    if len(sys.argv) != 2 or sys.argv[1] not in cmds:
        print("usage: hooks.py queue|holds|status", file=sys.stderr)
        sys.exit(64)
    sys.exit(cmds[sys.argv[1]]())
