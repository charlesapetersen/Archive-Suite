#!/usr/bin/python3
"""The engine's weekly token-efficiency pass (W40.token-pass, owner 2026-10-28).

    token-audit.py upkeep              the cadence: run a pass only when one is due (the upkeep hook calls this)
    token-audit.py run [--no-open]     run a pass now, whatever the cadence says
    token-audit.py sizes               the always-loaded files against their budgets, nothing else (instant)

A pass reads this project's Claude Code session transcripts since the last pass (the ~/.claude/projects folders
for the primary checkout and for every engine worktree) and the engine ledger ($AGENT_STATE/ledger.jsonl), and
reports: the first-call context of each engine session, the context per call, the tokens per finished item (its
sessions and their subagents), each against the last pass; the always-loaded files against their budgets; the
files sessions read whole most often; tool results over 20k characters, by command; and the same file read whole
twice in one session. Free and deterministic: no model, no network. It writes to $AGENT_STATE/token-audit/ only,
never the repo: the report (report-DATE.md, and latest.md), one line of figures per pass (passes.jsonl), and the
dated stamp of each pass (pass-DATE).

THE CADENCE. `upkeep` runs a pass at most once every 7 days (CADENCE_DAYS) and only when at least 20 engine
Claude sessions of this project (MIN_SESSIONS) have run since the last one, so a quiet week costs one ledger read.
The last pass is the last one recorded in passes.jsonl (a manual `run` counts), so the cadence and the window agree.
A dated stamp is created with O_EXCL before the work, as cluster-reach.py does, so two upkeep runs cannot both run a
pass that day; a pass that fails removes it, and one killed outright leaves it, so it is retried the next day. Trends
are compared only when the window has MIN_COMPARE measured sessions, and against the last BASELINE pass (one that
found nothing, or opened the fix), so a regression nobody was handed is never absorbed into the baseline.

WHAT A PASS DOES WITH ITS RESULT. When an always-loaded file is over its budget, or a trend figure is 10% or more
worse than the last pass (WORSE_PCT), it opens the fix item; otherwise it records the figures and stops. Opening is
`plan-edit.py due W40.token-fix-due NOTE`, which ticks the gate in the plan's `## RECURRING` section; the standing
item `W40.token-fix` (SUITE_TODO.md and the plan's WORK QUEUE, both `(blocked-on: W40.token-fix-due)`) then
becomes runnable. The fix session reads latest.md, fixes what it can, records a dated `W40.token-fix-YYYYMMDD`
entry in SUITE_TODO_DONE.md and re-arms the gate (`plan-edit.py rearm`), so the standing item waits again. Why
this filing: SUITE_TODO.md and the plan agree on W40.token-fix (both open, always), so check-tracker-sync.sh
passes; SUITE_TODO.md never holds a ticked line, so check-todo-stubs.sh passes; and the pass never edits a tracked
file, which upkeep (the primary checkout, between sessions) could not commit.

Budgets: the repo files' figures are read from context-budget.sh's BUDGETS table, the single source (app guides
24000, CLAUDE.md 40000, the prompt 31000: W40.docs-startup-size's result). The 20 KB app-guide target is reported
beside them; it does not open a fix on its own, because the Processor guide sits over it by rules a reviewer
restored (SUITE_TODO_DONE.md, W40.docs-startup-size). ~/Claude/CLAUDE.md and the memory index have their budgets
here (EXTRA_BUDGETS).

Tests: ops/agent/tests/test_token_audit.py (a synthetic transcript folder with known figures).
"""
import argparse
import datetime
import glob
import importlib.util
import json
import os
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "autonomous"))
HOME = os.path.expanduser("~")

CADENCE_DAYS = 7
MIN_SESSIONS = 20
MIN_COMPARE = MIN_SESSIONS  # a window with fewer measured sessions reports its figures but compares no trend
WORSE_PCT = 10            # a trend figure this many percent above the last pass opens the fix item
BIG_RESULT = 20000        # a tool result over this many characters is listed
APP_GUIDE_TARGET = 20000  # W40.docs-startup-size's target; reported, not enforced (see the header)
FIX_GATE = "W40.token-fix-due"
FIX_ITEM = "W40.token-fix"
EXTRA_BUDGETS = {          # always loaded, outside the repo, so not in context-budget.sh
    "~/Claude/CLAUDE.md": 12000,
    "memory/MEMORY.md": 12000,
}
ALWAYS = ["CLAUDE.md", "ops/autonomous/resume-prompt.txt", "ArchiveProcessor/CLAUDE.md",
          "ArchiveReader/CLAUDE.md", "ArchiveNotes/CLAUDE.md"]
TRENDS = [("first_call_median", "first-call context, median (tokens)"),
          ("context_per_call", "context per call, mean (tokens)"),
          ("tokens_per_item_median", "tokens per finished item, median")]
ITEM_RE = re.compile(r"Your item: (\S+)")
MEDIA = re.compile(r"\.(png|jpe?g|gif|webp|heic|tiff?|pdf)$", re.I)   # an image or PDF read costs its render, not its bytes
WT_RE = re.compile(r"/Users/[^/]+/Claude/(?:\.worktrees/archive-suite/)?suite-wt-[^/\s\"']+")  # any engine worktree


def encode(path):
    """Claude Code's project-folder name for a working directory."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


class Env:
    def __init__(self, a):
        self.repo = os.path.abspath(a.repo or os.environ.get("AGENT_REPO") or os.path.join(HERE, "..", ".."))
        self.state = a.state or os.environ.get("AGENT_STATE") or os.path.join(HOME, ".local/state/archive-autonomous")
        self.out = os.path.join(self.state, "token-audit")
        self.ledger = a.ledger or os.path.join(self.state, "ledger.jsonl")
        self.plan = a.plan or os.environ.get("AUTONOMOUS_PLAN") or os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")
        root = a.projects or os.environ.get("TOKEN_AUDIT_PROJECTS") or os.path.join(HOME, ".claude", "projects")
        wt_root = os.path.join(HOME, "Claude", ".worktrees", "archive-suite")
        self.folders = [os.path.join(root, encode(self.repo))] + sorted(glob.glob(os.path.join(root, encode(wt_root) + "-*")))
        self.memory = os.path.join(root, encode(self.repo), "memory", "MEMORY.md")
        self.umbrella = os.environ.get("TOKEN_AUDIT_UMBRELLA") or os.path.join(HOME, "Claude", "CLAUDE.md")
        self.project = a.project or os.environ.get("AGENT_PROJECT") or "Archive Suite"
        self.now = a.now if a.now is not None else time.time()


# ---- transcripts ----------------------------------------------------------------------------------------------

def ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def norm(path, repo):
    """A repo-relative name for a path in the primary checkout or any worktree."""
    p = WT_RE.sub(repo, path or "")
    if p.startswith(repo + "/"):
        p = p[len(repo) + 1:]
    return p


def result_chars(content):
    if isinstance(content, str):
        return len(content)
    if isinstance(content, list):
        return sum(len(b.get("text", "")) for b in content if isinstance(b, dict))
    return 0


def parse(path, repo):
    """One transcript: its start, first prompt, calls [(context, output)] deduped by message id, and its tools."""
    s = {"path": path, "start": None, "prompt": None, "calls": {}, "order": [], "uses": {}, "reads": [], "big": [], "media": 0}
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None
    with f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            t = ts(d.get("timestamp"))
            if t is not None and s["start"] is None:
                s["start"] = t
            kind = d.get("type")
            if kind == "queue-operation" and s["prompt"] is None and isinstance(d.get("content"), str):
                s["prompt"] = d["content"]
            msg = d.get("message") if isinstance(d.get("message"), dict) else {}
            content = msg.get("content")
            if kind == "user":
                if s["prompt"] is None and isinstance(content, str):
                    s["prompt"] = content
                for b in content if isinstance(content, list) else []:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text" and s["prompt"] is None:
                        s["prompt"] = b.get("text", "")
                    if b.get("type") == "tool_result":
                        use = s["uses"].get(b.get("tool_use_id"))
                        n = result_chars(b.get("content"))
                        if use is None:
                            continue
                        name, inp = use
                        if name == "Read" and "offset" not in inp and "limit" not in inp and "pages" not in inp:
                            fp = norm(inp.get("file_path", ""), repo)
                            if MEDIA.search(fp):
                                s["media"] += 1
                            else:
                                s["reads"].append((fp, n))
                        # An oversized result is persisted to a file and only a ~2 KB preview enters the context;
                        # it is still listed (at its full size, marked), because that command is the noisy one.
                        tur = d.get("toolUseResult") if isinstance(d.get("toolUseResult"), dict) else {}
                        full = tur.get("persistedOutputSize")
                        if isinstance(full, int) and full > BIG_RESULT:
                            s["big"].append((name, command_key(name, inp, repo) + " [persisted]", full))
                        elif n > BIG_RESULT:
                            s["big"].append((name, command_key(name, inp, repo), n))
            elif kind == "assistant":
                u = msg.get("usage")
                mid = msg.get("id") or d.get("requestId") or d.get("uuid")
                ctx = out = 0
                if isinstance(u, dict):
                    ctx = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
                    out = int(u.get("output_tokens") or 0)
                if mid and ctx:  # a zero-usage record (Claude Code's "<synthetic>" placeholder) is not a call
                    if mid not in s["calls"]:
                        s["order"].append(mid)
                        s["calls"][mid] = (ctx, out)
                    else:  # one call is written as several records; keep the fullest usage
                        c0, o0 = s["calls"][mid]
                        s["calls"][mid] = (max(c0, ctx), max(o0, out))
                for b in content if isinstance(content, list) else []:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        s["uses"][b.get("id")] = (b.get("name", ""), b.get("input") if isinstance(b.get("input"), dict) else {})
    s["calls"] = [s["calls"][m] for m in s["order"]]
    del s["order"], s["uses"]
    m = ITEM_RE.search(s["prompt"] or "")
    s["engine"] = bool(s["prompt"] and s["prompt"].startswith("ENGINE ASSIGNMENT"))
    s["item"] = m.group(1) if m and s["engine"] else None
    return s


def command_key(name, inp, repo):
    if name == "Bash":
        c = (inp.get("command") or "").strip().splitlines()
        return WT_RE.sub("<worktree>", c[0])[:120] if c else "Bash"
    for k in ("file_path", "path", "pattern", "url", "query", "description"):
        if inp.get(k):
            return "%s %s" % (name, norm(str(inp[k]), repo)[:110])
    return name


def sessions(env, since):
    """Main transcripts that started at or after SINCE, each with its subagents' tokens attached."""
    out = []
    for folder in env.folders:
        for path in sorted(glob.glob(os.path.join(folder, "*.jsonl"))):
            if os.path.getmtime(path) < since:
                continue
            s = parse(path, env.repo)
            if not s or s["start"] is None or s["start"] < since:
                continue
            sub = 0
            for sp in sorted(glob.glob(os.path.join(path[:-len(".jsonl")], "subagents", "*.jsonl"))):
                t = parse(sp, env.repo)
                if t:
                    sub += sum(c + o for c, o in t["calls"])
            s["subagent_tokens"] = sub
            out.append(s)
    return out


# ---- the ledger ----------------------------------------------------------------------------------------------

def ledger(env):
    rows = []
    try:
        with open(env.ledger) as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if isinstance(d, dict) and d.get("project") == env.project and isinstance(d.get("started"), (int, float)):
                    rows.append(d)
    except OSError:
        pass
    return rows


def match(sess, rows):
    """Attach each engine session to its ledger row: same item, transcript started inside the row's run."""
    for s in sess:
        s["ledger"] = None
        if not s["engine"]:
            continue
        for r in rows:
            if r.get("item") == s["item"] and r["started"] - 120 <= s["start"] <= (r.get("at") or r["started"]) + 60:
                s["ledger"] = r
                break


# ---- figures -------------------------------------------------------------------------------------------------

def budgets(env):
    """[(name, path, bytes or None, budget, target or None)] for the always-loaded files."""
    table = {}
    try:
        text = open(os.path.join(SCRIPTS, "context-budget.sh")).read()
        m = re.search(r"BUDGETS=\$\(cat <<'EOF'\n(.*?)\nEOF", text, re.S)
        for line in (m.group(1).splitlines() if m else []):
            f = line.split("\t")
            if len(f) == 2 and f[1].strip().isdigit():
                table[f[0].strip()] = int(f[1])
    except OSError:
        pass
    out = []
    for rel in ALWAYS:
        p = os.path.join(env.repo, rel)
        size = os.path.getsize(p) if os.path.exists(p) else None
        target = APP_GUIDE_TARGET if rel.startswith("Archive") else None
        out.append((rel, p, size, table.get(rel), target))
    for name, budget in EXTRA_BUDGETS.items():
        p = env.umbrella if name.startswith("~") else env.memory
        out.append((name, p, os.path.getsize(p) if os.path.exists(p) else None, budget, None))
    return out


def figures(env, sess, rows, since):
    # Only engine sessions the ledger knows: a measurement probe or a hand-run prompt carries an ENGINE ASSIGNMENT
    # too, but no ledger row, and would skew the figures.
    eng = [s for s in sess if s["engine"] and s["calls"] and s["ledger"] is not None]
    first = [s["calls"][0][0] for s in eng]
    calls = [c for s in eng for c, _ in s["calls"]]
    per_item = {}
    finished = {r["item"] for r in rows if r.get("item_finished") and (r.get("at") or 0) >= since}
    for s in eng:
        if s["item"] in finished:
            per_item[s["item"]] = per_item.get(s["item"], 0) + sum(c + o for c, o in s["calls"]) + s["subagent_tokens"]
    reads, twice, big = {}, [], {}
    for s in eng:
        seen = {}
        for path, n in s["reads"]:
            r = reads.setdefault(path, [0, set(), 0])
            r[0] += 1
            r[1].add(s["path"])
            r[2] = max(r[2], n)
            full = path if path.startswith("/") else os.path.join(env.repo, path)
            if os.path.isfile(full):
                r[2] = max(r[2], os.path.getsize(full))
            seen[path] = seen.get(path, 0) + 1
        twice += [(s["item"] or "?", p, k) for p, k in seen.items() if k > 1]
        for name, key, n in s["big"]:
            b = big.setdefault(key, [0, 0])
            b[0] += 1
            b[1] = max(b[1], n)
    med = lambda xs: int(statistics.median(xs)) if xs else None
    return {
        "since": since, "sessions": len(eng), "calls": len(calls),
        "other_sessions": len([s for s in sess if not s["engine"]]),
        "first_call_median": med(first), "first_call_max": max(first) if first else None,
        "first_call_min": min(first) if first else None,
        "context_per_call": int(sum(calls) / len(calls)) if calls else None,
        "items_finished": len(per_item), "tokens_per_item_median": med(list(per_item.values())),
        "ledger_rows": len([r for r in rows if r["started"] >= since]),
        "unmatched": len([s for s in sess if s["engine"] and s["ledger"] is None]),
        "codex_rows": len([r for r in rows if r["started"] >= since and r.get("agent") not in (None, "claude")]),
        "media_reads": sum(s["media"] for s in eng),
        "reads": sorted(((p, v[0], len(v[1]), v[2]) for p, v in reads.items()), key=lambda x: (-x[1], x[0]))[:15],
        "twice": sorted(twice, key=lambda x: (-x[2], x[0], x[1]))[:15],
        "big": sorted(((k, v[0], v[1]) for k, v in big.items()), key=lambda x: (-x[1] * x[2], x[0]))[:20],
    }


def breaches(fig, last, sizes):
    """Budgets always; trends only when this window has enough sessions to be a figure, not an anecdote."""
    out = []
    for rel, _, size, budget, _ in sizes:
        if size is not None and budget is not None and size > budget:
            out.append("%s is %d B, over its budget of %d B" % (rel, size, budget))
    for key, label in TRENDS:
        if fig["sessions"] < MIN_COMPARE:
            break
        a, b = (last or {}).get(key), fig.get(key)
        if a and b and b * 100 >= a * (100 + WORSE_PCT):  # integers: 55,000 against 50,000 is exactly +10%
            out.append("%s rose %d -> %d (+%.0f%%, the threshold is %d%%)" % (label, a, b, (b / a - 1) * 100, WORSE_PCT))
    return out


# ---- the report ----------------------------------------------------------------------------------------------

def fmt(n):
    return "—" if n is None else "{:,}".format(n)


def report(env, fig, last, sizes, found, opened, date, stale_gate):
    day = lambda t: datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M")
    L = ["# Token pass %s" % date, "",
         "Window: %s to %s. Engine sessions measured: %d (%d calls). Not counted: %d engine-prompt transcripts with no "
         "ledger row (probes), %d other sessions, and the %d Codex ledger rows, which leave no Claude Code transcript. "
         "Ledger rows in the window: %d."
         % (day(fig["since"]), day(env.now), fig["sessions"], fig["calls"], fig["unmatched"], fig["other_sessions"],
            fig["codex_rows"], fig["ledger_rows"]),
         "", "## Figures, against the last baseline pass%s" % (" (%s)" % last["date"] if last and last.get("date") else ""), "",
         "| figure | last pass | this pass | change |", "|---|---:|---:|---:|"]
    if fig["sessions"] < MIN_COMPARE:
        L += ["Fewer than %d sessions measured: the figures are recorded but not compared." % MIN_COMPARE, ""]
    for key, label in TRENDS:
        a, b = (last or {}).get(key), fig.get(key)
        ch = "%+.0f%%" % ((b / a - 1) * 100) if a and b else "—"
        L.append("| %s | %s | %s | %s |" % (label, fmt(a), fmt(b), ch))
    L += ["", "First call ranges %s to %s tokens. Finished items counted: %d (their sessions and subagents, in the window)."
          % (fmt(fig["first_call_min"]), fmt(fig["first_call_max"]), fig["items_finished"]),
          "Tokens are context plus output, summed over every call (cache reads included), as the usage window counts them.",
          "", "## Always-loaded files", "", "| file | bytes | budget | target |", "|---|---:|---:|---:|"]
    for rel, _, size, budget, target in sizes:
        flag = " ⚠ over budget" if size and budget and size > budget else (" (over target)" if size and target and size > target else "")
        L.append("| %s | %s%s | %s | %s |" % (rel, fmt(size), flag, fmt(budget), fmt(target)))
    L += ["", "## Files read whole most often", "", "Image and PDF reads are left out (%d in the window): they cost a render, "
          "and a screenshot re-read after a re-render is the job." % fig["media_reads"], "", "| file | whole reads | sessions | size (bytes on disk, else result chars) |", "|---|---:|---:|---:|"]
    L += ["| %s | %d | %d | %s |" % (p, n, k, fmt(c)) for p, n, k, c in fig["reads"]] or ["| none | | | |"]
    L += ["", "## Tool results over %s characters, by command" % fmt(BIG_RESULT), "", "| command | times | largest (chars) |", "|---|---:|---:|"]
    L += ["| `%s` | %d | %s |" % (k.replace("|", "\\|").replace("`", "'"), n, fmt(c)) for k, n, c in fig["big"]] or ["| none | | |"]
    L += ["", "## The same file read whole twice in one session", "", "| item | file | whole reads |", "|---|---|---:|"]
    L += ["| %s | %s | %d |" % t for t in fig["twice"]] or ["| none | | |"]
    L += ["", "## Verdict", ""]
    if stale_gate:
        L += ["⚠ %s was still ticked when this pass ran: the last fix session did not re-arm it (or has not run)." % FIX_GATE, ""]
    if found:
        L += ["- " + b for b in found]
        L += ["", ("The fix item %s is open (%s ticked)." % (FIX_ITEM, FIX_GATE)) if opened else
              "The fix item was NOT opened (run with --no-open, or the plan edit failed; see the upkeep log)."]
    else:
        L.append("No budget passed and no figure 10% or more worse than the last pass: figures recorded, no fix item.")
    L += ["", "## For the fix session (%s)" % FIX_ITEM, "",
          "Fix what you can in one session, then re-measure (`token-audit.py sizes` for the files; the session figures "
          "are measured again by the next pass). Guides are trimmed by hand, with every rule listed before and after and "
          "an adversarial reviewer checking that list: a rule may move but never disappear. Remove prompt steps the "
          "engine overrides; give a noisy script a summary on stdout and its full output in a log; narrow a hook that "
          "dumps a large file. Anything larger than one session is filed as its own item. Record the before and after "
          "figures in a dated `W40.token-fix-YYYYMMDD` entry in SUITE_TODO_DONE.md; the commit subject names `%s` "
          "standing alone, e.g. `%s (2026-11-05)`, because the engine's progress test needs the bare tag. After the "
          "push, re-arm the gate: `ops/autonomous/plan-edit.sh \"%s\" rearm %s '<sha>: <result>'`. Never `complete` %s: "
          "it is standing (plan-edit.py refuses)." % (FIX_ITEM, FIX_ITEM, env.plan, FIX_GATE, FIX_ITEM), ""]
    return "\n".join(L)


# ---- the pass ------------------------------------------------------------------------------------------------

def passes(env):
    """Every recorded pass, oldest first; an unreadable line is skipped, never the whole history."""
    out = []
    try:
        with open(os.path.join(env.out, "passes.jsonl")) as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if isinstance(d, dict) and isinstance(d.get("at"), (int, float)):
                    out.append(d)
    except OSError:
        pass
    return out


def baseline(history):
    """The pass trends compare against: the newest whose figures were accepted, i.e. it found nothing or it opened the
    fix. A pass that found a regression and did not hand it on (--no-open, a failed plan edit) is skipped, so the
    regression is not absorbed into the baseline. A pass with fewer than MIN_COMPARE sessions compares nothing, so it
    is no baseline either: a thin manual run must not become the figure a full week is held to."""
    for d in reversed(history):
        if d.get("baseline", True) and (d.get("sessions") or 0) >= MIN_COMPARE:
            return d
    return None


def gate_ticked(env):
    try:
        with open(env.plan) as f:
            text = f.read()
    except OSError:
        return False
    return re.search(r"(?m)^\s*[-*]\s+\[[xX]\]\s*\**%s\b" % re.escape(FIX_GATE), text) is not None


def open_fix(env, note):
    spec = importlib.util.spec_from_file_location("plan_edit", os.path.join(SCRIPTS, "plan-edit.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.edit(__import__("pathlib").Path(env.plan), "due", [FIX_GATE, note])


def run_pass(env, no_open=False, since=None):
    os.makedirs(env.out, exist_ok=True)
    history = passes(env)
    last = baseline(history)
    if since is None:
        since = history[-1]["at"] if history else env.now - CADENCE_DAYS * 86400
    rows = ledger(env)
    sess = sessions(env, since)
    match(sess, rows)
    fig = figures(env, sess, rows, since)
    sizes = budgets(env)
    found = breaches(fig, last, sizes)
    stale = gate_ticked(env)
    when = datetime.datetime.fromtimestamp(env.now)
    date = when.strftime("%Y-%m-%d")
    path = os.path.join(env.out, "report-%s.md" % when.strftime("%Y-%m-%dT%H%M%S"))
    opened = False
    if found and not no_open:
        try:
            open_fix(env, "token pass %s: %d finding(s); report %s" % (date, len(found), path))
            opened = True
        except Exception as e:  # the report and the record say so; upkeep never fails on this
            print("token-audit: could not open %s: %s" % (FIX_ITEM, e), file=sys.stderr)
    text = report(env, fig, last, sizes, found, opened, date, stale)
    for p in (path, os.path.join(env.out, "latest.md")):
        with open(p + ".tmp", "w") as f:
            f.write(text)
        os.replace(p + ".tmp", p)
    rec = {k: fig[k] for k in ("since", "sessions", "calls", "first_call_median", "first_call_min", "first_call_max",
                               "context_per_call", "items_finished", "tokens_per_item_median")}
    rec.update({"at": env.now, "date": date, "sizes": {r: s for r, _, s, _, _ in sizes}, "breaches": found,
                "opened": opened, "baseline": (not found) or opened, "stale_gate": stale, "report": path})
    with open(os.path.join(env.out, "passes.jsonl"), "a") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")
    print("token pass %s: %d engine sessions; first call median %s, context per call %s, tokens per finished item %s; "
          "%d finding(s)%s%s; report %s" % (date, fig["sessions"], fmt(fig["first_call_median"]), fmt(fig["context_per_call"]),
                                            fmt(fig["tokens_per_item_median"]), len(found),
                                            ", fix item opened" if opened else "",
                                            "; the last fix never re-armed its gate" if stale else "", path))
    return 0


def upkeep(env):
    """The cadence. The last pass is the last RECORDED one (a manual `run` counts), so the window and the cadence
    agree; the dated stamp only makes a day's pass exclusive. A pass killed mid-way leaves its stamp but no record,
    so it is retried the next day."""
    history = passes(env)
    last_t = history[-1]["at"] if history else None
    if last_t is not None and env.now - last_t < CADENCE_DAYS * 86400:
        print("token pass: not due until %s" % datetime.datetime.fromtimestamp(last_t + CADENCE_DAYS * 86400).strftime("%Y-%m-%d %H:%M"))
        return 0
    # Claude sessions only: a Codex session leaves no transcript to measure.
    n = len([r for r in ledger(env) if (last_t is None or r["started"] > last_t) and r.get("agent", "claude") == "claude"])
    if n < MIN_SESSIONS:
        print("token pass: due, but only %d engine sessions since the last one (needs %d)" % (n, MIN_SESSIONS))
        return 0
    os.makedirs(env.out, exist_ok=True)
    stamp = os.path.join(env.out, "pass-" + datetime.datetime.fromtimestamp(env.now).strftime("%Y-%m-%d"))
    try:
        os.close(os.open(stamp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
    except FileExistsError:
        print("token pass: today's stamp is taken (a pass ran or is running today)")
        return 0
    try:
        return run_pass(env)
    except Exception:
        os.remove(stamp)
        raise


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", choices=["upkeep", "run", "sizes"])
    ap.add_argument("--no-open", action="store_true", help="report only; never open the fix item")
    ap.add_argument("--since", help="window start (ISO date or epoch seconds); default the last pass")
    for k in ("repo", "state", "ledger", "plan", "projects", "project"):
        ap.add_argument("--" + k)
    ap.add_argument("--now", type=float, help=argparse.SUPPRESS)  # tests
    a = ap.parse_args(argv)
    env = Env(a)
    if a.cmd == "sizes":
        for rel, _, size, budget, target in budgets(env):
            print("%-36s %8s  budget %8s%s" % (rel, fmt(size), fmt(budget), "  target %s" % fmt(target) if target else ""))
        return 0
    if a.cmd == "upkeep":
        return upkeep(env)
    since = None
    if a.since:
        since = float(a.since) if re.fullmatch(r"[0-9.]+", a.since) else datetime.datetime.fromisoformat(a.since).timestamp()
    return run_pass(env, a.no_open, since)


if __name__ == "__main__":
    sys.exit(main())
