#!/usr/bin/env python3
"""W35.live: measure a multi-worker run against the one-worker run before it. Read-only.

Prints, before and after the split (default: the first pace.log line, which only a
`--workers 2` supervisor writes):
  * each five-hour window an Archive Suite session saw: its peak reading, and whether it was cut;
  * items finished per day (whole `- [x] **TAG` entries added to SUITE_TODO_DONE.md on origin/main);
  * collisions: an item finished twice, merge conflicts in the retained session logs, heavy-lock waits;
  * how long the pacer allowed each slot count.
Readings are account-wide, so a window's peak includes Vision OCR's spend on the same Claude account.
Ledger rows do not name their subscription; under `--agent both` Codex and Claude windows are listed
together, told apart by their different reset times.
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


def windows(state, since):
    found = {}
    for path in ledgers(state):
        for line in path.read_text(errors="replace").splitlines()[1:]:
            f = line.split("\t")
            if len(f) < 10:
                continue
            try:
                row(found, f, since)
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
    a = ap.parse_args()
    now = when(a.now) if a.now else dt.datetime.now().replace(microsecond=0)
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
    if not waits:
        print("  heavy-lock waits: none recorded")

    print("\n== Pace (minutes at each slot count, from pace.log) ==")
    spent = pace_time([r for r in pace if r[0] >= since], now)
    for (lane, slots), mins in sorted(spent.items()):
        print("  %-6s %s slot(s): %d min" % (lane, slots, mins))
    if not spent:
        print("  (no pace.log — the supervisor has not run with --workers 2)")


if __name__ == "__main__":
    main()
