#!/usr/bin/env python3
"""W35.live: measure a multi-worker run against the one-worker run before it. Read-only.

Prints, before and after the split (default: the first pace.log line, which only a
`--workers 2`/`3` supervisor writes):
  * each five-hour window an Archive Suite session saw: its peak reading, and whether it was cut;
  * items finished per day (whole `- [x] **TAG` entries added to SUITE_TODO_DONE.md on origin/main);
  * collisions: an item finished twice, merge conflicts in the retained session logs, heavy-lock waits;
  * how long the pacer allowed each slot count.
Readings are account-wide, so a window's peak includes Vision OCR's spend on the same Claude account.
Ledger rows do not name their subscription; under `--agent both` Codex and Claude windows are listed
together, told apart by their different reset times.

W35.unspent: `--unspent` prints only one line per subscription — the share of each five-hour window left
unspent over the last 24 h and 7 days, and the weekly limit where a reading carries it. status-digest.sh shows
it, as the before/after for a plan upgrade. Claude: these ledgers plus Vision OCR's (same account), less any
window whose reset is a Codex window's. Codex: the rollouts' `rate_limits`, which are account-wide. Peaks are
what the sessions read; use after the last reading is not seen, so an unspent share is an upper bound.
"""
import argparse
import datetime as dt
import os
from pathlib import Path
import re
import subprocess
import sys

FMT = "%Y-%m-%d %H:%M"
PEAK = re.compile(r"(\d+)% \(resets (\d\d):(\d\d)\)")
# A tag has a digit (W35.live, R13d); old entries headed by a plain word (**Reader**) are not items.
DONE = re.compile(r"^\+- \[x\] \*\*([A-Za-z][\w.-]*\d[\w.-]*)[\s*`]")
# git's own report, inside a tool result (a session quoting the word in its own text is not a conflict)
CONFLICT = re.compile(r"CONFLICT \([a-z/ -]+\): Merge conflict in")


def when(text):
    for fmt in ("%Y-%m-%d %H:%M:%S", FMT, "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(text.strip(), fmt)
        except ValueError:
            pass
    raise ValueError("not a time: %r" % text)


def reset_at(start, hh, mm):
    """The ledger keeps only HH:MM; the reset is the first such time after the session started."""
    r = start.replace(hour=int(hh), minute=int(mm), second=0)  # ValueError on 25:99; the caller skips the row
    # >=: the ledger's times are whole minutes, so a reset in the session's starting minute is that same day.
    return r if r >= start else r + dt.timedelta(days=1)


def ledgers(state):
    seen, out = set(), []
    for path in [state / "usage-window.tsv", *sorted(state.glob("worker-*/usage-window.tsv"))]:
        if path.is_file() and os.path.realpath(path) not in seen:
            seen.add(os.path.realpath(path))
            out.append(path)
    return out


# The columns row() reads, in this daemon's ledger order. Vision OCR's ledger carries the same names with an
# `item` column after `minutes`, so each ledger is read by its own header, not by position.
COLUMNS = ("kind", "start", "end", "minutes", "effort", "rc", "first_pct", "first_reset", "window_peaks", "cut")


def windows(state, since, paths=None):
    found = {}
    for path in paths if paths is not None else ledgers(state):
        lines = path.read_text(errors="replace").splitlines()
        head = lines[0].split("\t") if lines else []
        if not set(COLUMNS) <= set(head):
            continue  # not a ledger this parser knows
        at = [head.index(c) for c in COLUMNS]
        for line in lines[1:]:
            f = line.split("\t")
            if len(f) <= max(at):
                continue
            try:
                row(found, [f[i] for i in at], since)
            except ValueError:
                continue  # a malformed row is skipped, never a crash
    return found


def row(found, f, since):
    """Fold one ledger row into the windows. Parses the whole row before touching `found`."""
    start = when(f[1])
    if start < since:
        return
    blank = lambda: {"peak": 0, "cut": False, "sessions": 0}
    if f[0] == "session":
        peaks = [(reset_at(start, hh, mm), int(pct)) for pct, hh, mm in PEAK.findall(f[8])]
        first = reset_at(start, *f[7].split(":")) if re.fullmatch(r"\d\d:\d\d", f[7]) else None
        for r, pct in peaks:
            rec = found.setdefault(r, blank())
            rec["peak"] = max(rec["peak"], pct)
        if first is not None:
            rec = found.setdefault(first, blank())
            rec["sessions"] += 1
            rec["cut"] = rec["cut"] or f[9] == "cut"
    elif f[0] == "wait" and f[9] == "cut" and re.fullmatch(r"\d\d:\d\d", f[7]):
        # A wait row starts after the cut, possibly past the reset it is waiting for.
        # (Only the one-worker loop writes wait rows; parallel workers show a cut through their session rows.)
        r, pct = reset_at(start - dt.timedelta(hours=5), *f[7].split(":")), int(f[6] or 0)
        rec = found.setdefault(r, blank())
        rec["cut"] = True
        rec["peak"] = max(rec["peak"], pct)


# ----- W35.unspent: how much of each subscription's usage went unspent ----------------------------------------
# A five-hour window is the interval up to its reset. Its unspent share is 100 - the peak reading, or 0 when a
# session was cut by it; time no reading covers is reported as such, never counted as spent or unspent.
FIVE_H = dt.timedelta(hours=5)
# Both CLIs derive a reset from "now + seconds left", so one window's readings carry resets a few seconds apart.
SAME_RESET = dt.timedelta(minutes=2)
CODEX_RL = re.compile(rb'"rate_limits":\{"limit_id":"codex"[^}]*?"primary":\{"used_percent":([0-9.]+),'
                      rb'"window_minutes":\d+,"resets_at":(\d+)\}(?:,"secondary":\{"used_percent":([0-9.]+),'
                      rb'"window_minutes":\d+,"resets_at":(\d+))?')
CLAUDE_WEEK = re.compile(rb'"seven_day":\{"utilization":([0-9.]+),"resetsAt":(\d+)')


def merge_close(found):
    """One window per reset: readings whose resets lie within SAME_RESET of each other are the same window."""
    out, last = {}, None
    for r in sorted(found):
        if last is not None and r - last <= SAME_RESET:
            rec = out[last]
            rec["peak"] = max(rec["peak"], found[r]["peak"])
            rec["cut"] = rec["cut"] or found[r]["cut"]
            rec["sessions"] += found[r]["sessions"]
        else:
            out[r], last = dict(found[r]), r
    return out


def scan(path, pattern):
    """Each match's groups in a file, without reading it into memory (rollouts run to hundreds of MB)."""
    import mmap
    try:
        with path.open("rb") as fh, mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as m:
            return [x.groups() for x in pattern.finditer(m)]  # copied out: a match dies with its mmap
    except (OSError, ValueError):  # unreadable, or empty (mmap refuses a zero-length file)
        return []


def newest(week):
    """(percent, reset) of the newest weekly window, merging resets a few seconds apart; None with no reading."""
    if not week:
        return None
    last = max(week)
    return max(v for w, v in week.items() if last - w <= SAME_RESET), last


def codex_windows(codex_home, since):
    """Codex readings from the session rollouts: {reset: window} for the five-hour limit, and the weekly one.
    Account-wide, so the owner's own Codex sessions count too."""
    found, week = {}, {}
    root = codex_home / "sessions"
    # A reading's reset is at most five hours after it was written, so a file last written before since - 5 h
    # holds nothing that reaches the period. (A week of rollouts is ~0.5 GB; the digest runs every cycle.)
    cutoff = (since - FIVE_H).timestamp()
    for path in sorted(root.rglob("rollout-*.jsonl")) if root.is_dir() else []:
        try:
            if path.stat().st_mtime < cutoff:
                continue
        except OSError:
            continue
        for pct, reset, week_pct, week_reset in scan(path, CODEX_RL):
            try:
                r = dt.datetime.fromtimestamp(int(reset))
                w = dt.datetime.fromtimestamp(int(week_reset)) if week_reset else None
            except (OverflowError, OSError, ValueError):
                continue  # an absurd timestamp is skipped, never a crash
            rec = found.setdefault(r, {"peak": 0, "cut": False, "sessions": 0})
            rec["peak"] = max(rec["peak"], min(100, round(float(pct))))
            if w is not None:
                week[w] = max(week.get(w, 0), min(100, round(float(week_pct))))
    return merge_close(found), newest(week)


def claude_week(states):
    """Claude's weekly reading, if its rate_limit_events carry one. None did by 2026-10-07: the shape assumed is
    `unifiedWindows.five_hour`'s, under a `seven_day` key; if a real one differs this reads "no reading"."""
    week = {}
    for state in states:
        for path in [*state.glob("last-session.log*"), *state.glob("worker-*/last-session.log*")]:
            for util, reset in scan(path, CLAUDE_WEEK):
                try:
                    w = dt.datetime.fromtimestamp(int(reset))
                except (OverflowError, OSError, ValueError):
                    continue
                week[w] = max(week.get(w, 0), min(100, round(float(util) * 100)))
    return newest(week)


def unspent(wins, lo, hi):
    """(unspent %, None with no reading; hours no reading covered) over [lo, hi). A window not yet reset at hi is
    not over, so the period stops where that window began: its time is neither unspent nor 'no reading'."""
    for r in wins:
        if r - FIVE_H < hi < r:
            hi = r - FIVE_H
    covered, weighted, prev = 0.0, 0.0, lo
    for r in sorted(wins):
        a, b = max(r - FIVE_H, prev, lo), min(r, hi)
        if b <= a:
            continue
        h = (b - a).total_seconds() / 3600
        covered += h
        weighted += h * (0 if wins[r]["cut"] else 100 - min(100, wins[r]["peak"]))
        prev = b
    total = max(0.0, (hi - lo).total_seconds() / 3600)
    return (round(weighted / covered) if covered else None), max(0, round(total - covered))


def unspent_line(name, wins, week, now):
    parts = []
    for label, span in (("24 h", dt.timedelta(days=1)), ("7 days", dt.timedelta(days=7))):
        pct, gap = unspent(wins, now - span, now)
        if pct is None:
            parts.append("%s no reading" % label)
        else:
            parts.append("%s %d%%%s" % (label, pct, " (%d h no reading)" % gap if gap else ""))
    if week and week[1] > now:
        parts.append("weekly %d%% used (resets %s)" % (week[0], week[1].strftime("%a %-d %b")))
    else:
        parts.append("weekly no reading")
    return "%-6s %s" % (name, " · ".join(parts))


def report_unspent(a, now):
    since = now - dt.timedelta(days=7) - FIVE_H
    codex, codex_week = codex_windows(a.codex_home, since)
    paths, seen = [], set()
    for state in [a.state, *a.also_state]:
        for path in ledgers(state):
            if os.path.realpath(path) not in seen:
                seen.add(os.path.realpath(path))
                paths.append(path)
    # Ledger rows do not name their CLI, and Archive Suite sessions ran under Codex at times: a ledger window
    # whose reset is a Codex window's IS that Codex window, already counted from the rollouts — but its cut mark
    # exists only in the ledger, so it is carried over. (A Claude window resetting within SAME_RESET of a Codex
    # one would be lost to "no reading"; none did in the week to 2026-10-07.)
    claude = {}
    for r, w in merge_close(windows(a.state, since - FIVE_H, paths)).items():
        twin = next((c for c in codex if abs(r - c) <= SAME_RESET), None)
        if twin is None:
            claude[r] = w
        elif w["cut"]:
            codex[twin]["cut"] = True
    print(unspent_line("Claude", claude, claude_week([a.state, *a.also_state]), now))
    print(unspent_line("Codex", codex, codex_week, now))


def finished(repo, since):
    log = subprocess.run(["git", "-C", str(repo), "log", "origin/main", "--since=" + since.strftime(FMT),
                          "--format=@@ %ad", "--date=format:%Y-%m-%d %H:%M:%S", "-p", "--unified=0",
                          "--", "SUITE_TODO_DONE.md"], capture_output=True, text=True)
    if log.returncode != 0:
        sys.exit("measure-workers: git log failed: " + log.stderr.strip())
    out, stamp = [], None
    for line in log.stdout.splitlines():
        if line.startswith("@@ ") and not line.startswith("@@ -"):
            stamp = when(line[3:])
        elif stamp:
            m = DONE.match(line)
            if m:
                out.append((stamp, m.group(1)))
    return out


def conflicts(state, since):
    """Merge conflicts a session met. Only the last two logs per worker are retained, so this undercounts."""
    hits = []
    # Path.glob, not glob.glob: a state path may contain "[", which glob.glob reads as a character class.
    for path in sorted({os.path.realpath(p) for p in [*state.glob("last-session.log*"),
                                                     *state.glob("worker-*/last-session.log*")]}):
        p = Path(path)
        if not p.is_file() or dt.datetime.fromtimestamp(p.stat().st_mtime) < since:
            continue
        with p.open(errors="replace") as fh:
            n = sum(len(CONFLICT.findall(line)) for line in fh if '"tool_result"' in line)
        if n:
            hits.append((p, n))
    return hits


def tsv(path, since):
    rows = []
    if path.is_file():
        for line in path.read_text(errors="replace").splitlines():
            f = line.split("\t")
            try:
                t = when(f[0])
            except ValueError:
                continue
            if t >= since:
                rows.append((t, f[1:]))
    return rows


def sessions(state):
    """(start, end) of every session row in this daemon's ledgers, to the minute the ledger records."""
    out = []
    for path in ledgers(state):
        lines = path.read_text(errors="replace").splitlines()
        head = lines[0].split("\t") if lines else []
        if not {"kind", "start", "end"} <= set(head):
            continue
        k, s, e = head.index("kind"), head.index("start"), head.index("end")
        for line in lines[1:]:
            f = line.split("\t")
            if len(f) > max(k, s, e) and f[k] == "session":
                try:
                    out.append((when(f[s]), when(f[e]) + dt.timedelta(seconds=59)))
                except ValueError:
                    continue
    return out


def pace_time(rows, now):
    """Minutes spent at each (lane, slots) between pace.log changes, up to now."""
    spent, last = {}, {}
    for t, f in rows:
        if len(f) < 3:
            continue
        lane = f[0]
        if lane in last:
            pt, key = last[lane]
            spent[key] = spent.get(key, 0) + (t - pt).total_seconds() / 60
        last[lane] = (t, (lane, f[2]))
    for lane, (pt, key) in last.items():
        spent[key] = spent.get(key, 0) + max(0, (now - pt).total_seconds() / 60)
    return spent


def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state", type=Path, default=Path(os.environ.get(
        "AUTONOMOUS_STATE", str(Path.home() / ".local/state/archive-autonomous"))))
    ap.add_argument("--repo", type=Path, default=here.parent.parent)
    ap.add_argument("--since", help="start of the comparison (default: 7 days before now)")
    ap.add_argument("--split", help="when the multi-worker run began (default: first pace.log line)")
    ap.add_argument("--now", help=argparse.SUPPRESS)
    ap.add_argument("--unspent", action="store_true",
                    help="print only the usage left unspent, one line per subscription (status-digest.sh)")
    ap.add_argument("--also-state", type=Path, action="append",
                    help="another daemon's state dir for --unspent (default: Vision OCR's; same Claude account)")
    ap.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    a = ap.parse_args()
    now = when(a.now) if a.now else dt.datetime.now().replace(microsecond=0)
    if a.unspent:
        if a.also_state is None:
            a.also_state = [Path.home() / ".local/state/visionocr-autonomous"]
        return report_unspent(a, now)
    since = when(a.since) if a.since else now - dt.timedelta(days=7)
    pace = tsv(a.state / "pace.log", dt.datetime.min)
    split = when(a.split) if a.split else (pace[0][0] if pace else None)
    side = (lambda t: "after" if split and t >= split else "before")

    def window_side(reset):
        # A window that straddles the split ran partly each way, so it is listed but kept out of both means.
        start = reset - dt.timedelta(hours=5)
        return "before" if not split or reset <= split else "after" if start >= split else "spans"

    print("W35.live measurement — %s to %s" % (since.strftime(FMT), now.strftime(FMT)))
    print("split: %s" % (split.strftime(FMT) + (" (first pace.log line)" if not a.split else "")
                         if split else "none — no pace.log, so no multi-worker run yet; everything is 'before'"))

    print("\n== Five-hour windows (peak reading, account-wide incl. Vision OCR) ==")
    wins = windows(a.state, since)
    by = {"before": [], "after": [], "spans": []}
    for r in sorted(wins):
        rec = wins[r]
        by[window_side(r)].append(rec)
        print("  reset %s  %-6s peak %3d%%  %-4s  %d session(s)" % (
            r.strftime(FMT), window_side(r), rec["peak"], "cut" if rec["cut"] else "", rec["sessions"]))
    for k in ("before", "after"):
        v = by[k]
        if v:
            print("  %-6s %d window(s), mean peak %d%%, %d reached the cut" % (
                k, len(v), round(sum(x["peak"] for x in v) / len(v)), sum(x["cut"] for x in v)))
    if not wins:
        print("  (no ledger rows)")

    print("\n== Items finished (SUITE_TODO_DONE.md entries on origin/main) ==")
    items = finished(a.repo, since)
    days = {}
    for t, tag in items:
        days.setdefault(t.date(), []).append(tag)
    for d in sorted(days):
        print("  %s  %2d  %s" % (d, len(days[d]), " ".join(days[d])))
    for k in ("before", "after"):
        sel = [t for t, _ in items if side(t) == k]
        lo = since if k == "before" else split
        hi = (split or now) if k == "before" else now
        if lo and hi > lo:
            span = (hi - lo).total_seconds() / 86400
            print("  %-6s %d item(s) over %.1f day(s) = %.1f/day" % (k, len(sel), span, len(sel) / span))

    print("\n== Collisions ==")
    tags = {}
    for t, tag in items:
        tags.setdefault(tag, []).append(t)
    dup = {k: v for k, v in tags.items() if len(v) > 1}
    print("  items finished more than once: %s" % (", ".join(
        "%s (%s)" % (k, ", ".join(t.strftime(FMT) for t in v)) for k, v in sorted(dup.items())) or "none"))
    hits = conflicts(a.state, since)
    print("  merge conflicts in retained session logs: %s" % (
        "; ".join("%s ×%d" % (os.path.relpath(p, os.path.realpath(a.state)), n) for p, n in hits) or "none")
          + "  (only each worker's last two logs are kept)")
    waits = tsv(a.state / "heavy" / "waits.log", since)
    for k in ("before", "after"):
        sel = [float(f[0]) for t, f in waits if side(t) == k and f and re.fullmatch(r"\d+(\.\d+)?", f[0])]
        if sel:
            print("  heavy-lock waits %-6s %d, total %.1f min, longest %.1f min" % (
                k, len(sel), sum(sel) / 60, max(sel) / 60))
    # W35.three-workers: the same waits by how many sessions were running when each began, from the ledgers'
    # session rows (a session still running has no row yet, so the latest waits can undercount).
    spans, by_count = sessions(a.state), {}
    for t, f in waits:
        if f and re.fullmatch(r"\d+(\.\d+)?", f[0]):
            by_count.setdefault(sum(lo <= t <= hi for lo, hi in spans), []).append(float(f[0]))
    for n in sorted(by_count):
        sel = by_count[n]
        print("  heavy-lock waits with %d session(s) running%s: %d, total %.1f min, longest %.1f min" % (
            n, " (gate/upkeep)" if n == 0 else "", len(sel), sum(sel) / 60, max(sel) / 60))
    if not waits:
        print("  heavy-lock waits: none recorded")

    print("\n== Pace (minutes at each slot count, from pace.log) ==")
    spent = pace_time([r for r in pace if r[0] >= since], now)
    for (lane, slots), mins in sorted(spent.items()):
        print("  %-6s %s slot(s): %d min" % (lane, slots, mins))
    if not spent:
        print("  (no pace.log — the supervisor has not run with --workers 2 or 3)")


if __name__ == "__main__":
    main()
