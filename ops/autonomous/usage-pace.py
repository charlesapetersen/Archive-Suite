#!/usr/bin/env python3
"""W35.pace: how many workers a subscription lane may run, from its usage readings.

A lane runs its extra workers only while it is UNDER PACE: the share of the window
already used trails the share of the window's time already gone. The rule is orc's
(https://github.com/hathbanger/orc/issues/127), with the margins from
execution-plans/parallel-workers/00-plan.md §5:

  grow    used < elapsed - 0.10 and used < 0.80   -> up to the lane's limit
  tight   used > elapsed + 0.15 or used > 0.85    -> back to one worker
  steady  anything between                        -> keep the previous count
  unknown no current five-hour reading            -> one worker

The five-hour window sets the band. The weekly window, when a reading has it, can
only hold the lane back: "tight" against the week's elapsed share (so the week is
not spent in two days) forces one worker. It never blocks "grow" by itself, which a
literal reading of the rule would do for the first 10% (~17 h) of every week. The
Claude CLI has not been seen to report a weekly utilization (only a weekly
rejection), so in practice the weekly gate is Codex's. "Steady" keeps the previous
count so the lane does not flap between one and two at a boundary.

Pacing never goes BELOW one worker. One worker is the serial daemon's behaviour,
and its existing stop at AUTONOMOUS_WINDOW_WAIT_AT (95%) or a cutoff stays the only
thing that idles a lane; pacing only decides when a second session is worth it.

Vision OCR priority (plan §6): the Claude readings are the ACCOUNT's, so a Vision
OCR session's spend is already in them, and Vision OCR's own session log is read
as one more source. Archive Suite therefore adds a Claude worker only when the
account as a whole is under pace.

Readings come only from the CLIs' own output, never from a web endpoint:
  claude  `rate_limit_event` lines in a stream-json session log
  codex   `rate_limits` (limit_id "codex") in a ~/.codex/sessions rollout
Every source holding a reading for the CURRENT window counts, and the highest
used share wins: usage only rises within a window, and a file's mtime says nothing
about its last reading (a session log is rewritten by tool output between the ~1%
steps at which the CLI reports). The same rule as the supervisor's pause: an older
sibling reading never lowers a current one.
"""
import math
import json
from pathlib import Path

FIVE_HOUR = 5 * 3600
WEEK = 7 * 24 * 3600
TAIL = 1 << 20  # bytes read from the end of each source; a session log can be many MB
ORDER = {"grow": 0, "steady": 1, "tight": 2, "unknown": 3}


def tail_lines(path, limit=TAIL):
    try:
        with open(path, "rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - limit))
            data = handle.read()
    except OSError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    return lines[1:] if size > limit else lines  # the first line may be cut


def claude_windows(lines):
    """Latest reading of each window: {kind: (used 0-1, resetsAt, length)}."""
    found = {}
    for line in lines:
        if '"rate_limit_event"' not in line:
            continue
        try:
            info = json.loads(line).get("rate_limit_info") or {}
        except (ValueError, AttributeError):
            continue
        if not isinstance(info, dict):
            continue
        if info.get("status") == "rejected":
            kind = "weekly" if str(info.get("rateLimitType", "")).startswith("seven_day") else "five_hour"
            reset = info.get("resetsAt")
            if isinstance(reset, (int, float)) and math.isfinite(reset):
                found[kind] = (1.0, int(reset), WEEK if kind == "weekly" else FIVE_HOUR)
            continue
        event = {}
        for key, value in (info.get("unifiedWindows") or {}).items():
            kind = "five_hour" if key == "five_hour" else "weekly" if key.startswith("seven_day") else None
            try:
                reading = (float(value["utilization"]), int(value["resetsAt"]))
            except (KeyError, TypeError, ValueError, OverflowError):
                continue
            if not math.isfinite(reading[0]):
                continue
            # Per-model weekly windows (seven_day_opus, …) in the same event: the fullest one gates.
            if kind and (kind not in event or reading[0] > event[kind][0]):
                event[kind] = reading + (WEEK if kind == "weekly" else FIVE_HOUR,)
        found.update(event)
    return found


def _limits(node):
    if isinstance(node, dict):
        value = node.get("rate_limits")
        if isinstance(value, dict) and value.get("limit_id") == "codex":
            yield value
        for child in node.values():
            yield from _limits(child)
    elif isinstance(node, list):
        for child in node:
            yield from _limits(child)


def codex_windows(lines):
    found = {}
    for line in lines:
        if '"rate_limits"' not in line:
            continue
        try:
            limits = list(_limits(json.loads(line)))
        except ValueError:
            continue
        for value in limits:
            for key, kind in (("primary", "five_hour"), ("secondary", "weekly")):
                window = value.get(key)
                try:
                    reading = (float(window["used_percent"]) / 100, int(window["resets_at"]),
                               int(window["window_minutes"]) * 60)
                except (KeyError, TypeError, ValueError, OverflowError):
                    continue
                if reading[2] > 0 and math.isfinite(reading[0]):
                    found[kind] = reading
    return found


def current_reading(sources, parse, now):
    """Per window, the highest current reading across all sources: {kind: (used, reset, length, path)}."""
    result = {}
    for path in sources:
        for kind, reading in parse(tail_lines(path)).items():
            if reading[1] > now and (kind not in result or reading[0] > result[kind][0]):
                result[kind] = reading + (str(path),)
    return result


def codex_sources(codex_home, now, keep=30):
    """Rollouts touched in the last six hours, as usage-window.sh --codex-latest reads them."""
    found = []
    for path in Path(codex_home, "sessions").rglob("rollout-*.jsonl"):
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if now - mtime < 6 * 3600:
            found.append((mtime, path))
    return [path for _, path in sorted(found, reverse=True)[:keep]]


def band(used, reset, length, now):
    elapsed = min(1.0, max(0.0, 1 - (reset - now) / length))
    if used > elapsed + 0.15 or used > 0.85:
        return "tight", elapsed
    if used < elapsed - 0.10 and used < 0.80:
        return "grow", elapsed
    return "steady", elapsed


def assess(windows, now):
    """(band, description) for a lane: the most restrictive current window wins."""
    if "five_hour" not in windows:
        return "unknown", "no current five-hour reading"
    worst, notes = "grow", []
    for kind in ("five_hour", "weekly"):
        if kind in windows:
            used, reset, length = windows[kind][:3]
            name, elapsed = band(used, reset, length, now)
            if kind == "five_hour" or name == "tight":  # weekly only holds back (docstring)
                worst = max(worst, name, key=ORDER.get)
            notes.append("%s %d%% used / %d%% elapsed" % ("5h" if kind == "five_hour" else "week",
                                                          round(used * 100), round(elapsed * 100)))
    return worst, ", ".join(notes)


def next_cap(previous, name, limit):
    if name == "grow":
        return limit
    if name == "steady":
        return min(limit, max(1, previous))
    return 1
