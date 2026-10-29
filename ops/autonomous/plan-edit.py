#!/usr/bin/env python3
"""Atomic region-bounded plan edits under the lock also held by idle compaction."""
import fcntl
import os
from pathlib import Path
import re
import sys
import tempfile
import time


# hooks.py's HOLD_MARK, and the markers a note must not smuggle into a queue line.
HOLD = re.compile(r"\[hold\]|needs:\s*owner", re.I)
MARKERS = re.compile(r"\((?:blocked-on|uses|cluster|lane|needs|effort)\s*:", re.I)


def section(text, heading):
    """Use the resolver's fence/blockquote/heading rules, preserving byte spans."""
    offset = 0
    infence = False
    matches = []
    active = None
    for line in text.splitlines(keepends=True):
        start = offset
        offset += len(line)
        if re.match(r"^\s*(```|~~~)", line):
            infence = not infence
            continue
        if infence or re.match(r"^\s*>", line):
            continue
        if line.startswith("## "):
            if active is not None:
                matches.append((active, start))
                active = None
            if line.startswith(heading):
                active = offset
    if active is not None:
        matches.append((active, len(text)))
    if len(matches) != 1:
        raise ValueError("expected exactly one section: " + heading)
    return matches[0]


def pending_entries(body):
    offset = 0
    infence = False
    entries = []
    for line in body.splitlines(keepends=True):
        start = offset
        offset += len(line)
        if re.match(r"^\s*(```|~~~)", line):
            infence = not infence
            continue
        if infence or re.match(r"^\s*>", line):
            continue
        m = re.match(r"^\s*[-*]\s+\[ \]\s*", line)
        if m:
            rest = re.sub(r"^\*+\s*", "", line[m.end():])
            rest = re.sub(r"^`", "", rest)
            tag = re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", rest)
            entries.append((tag[0] if tag else "?", start, offset))
    return entries


def entries(body):
    """(tag, start, end-of-item-span) for every checkbox entry, any state, by the resolver's span rule:
    an item runs to the next checkbox, blank line or heading."""
    offset = 0
    infence = False
    out = []
    current = None
    for line in body.splitlines(keepends=True):
        start = offset
        offset += len(line)
        if re.match(r"^\s*(```|~~~)", line):
            infence = not infence
            continue
        if infence or re.match(r"^\s*>", line):
            continue
        m = re.match(r"^\s*[-*]\s+\[[ xX]\]\s*", line)
        if m or not line.strip() or line.startswith("#"):
            current = None
        if m:
            rest = re.sub(r"^`", "", re.sub(r"^\*+\s*", "", line[m.end():]))
            tag = re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", rest)
            current = [tag[0] if tag else "?", start, offset]
            out.append(current)
        elif current is not None:
            current[2] = offset
    return out


def edit(plan, action, values):
    plan = plan.resolve()
    with plan.with_name(plan.name + ".lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        text = plan.read_text()
        if action in ("complete", "block"):
            tag, sha, result = values
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
                raise ValueError("invalid tag")
            if action == "complete" and not re.fullmatch(r"[a-f0-9]{7,40}", sha):
                raise ValueError("invalid commit")
            if action == "block" and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", sha):
                raise ValueError("invalid prerequisite")
            if "\n" in result:
                raise ValueError("result/question must be one line")
            start, end = section(text, "## WORK QUEUE")
            body = text[start:end]
            matches = [(lo, hi) for t, lo, hi in pending_entries(body) if t == tag]
            if len(matches) != 1:
                raise ValueError("expected exactly one unchecked queue item")
            lo, hi = matches[0]
            line = body[lo:hi].rstrip("\n")
            try:
                recurring = section(text, "## RECURRING") if action == "complete" else None
            except ValueError:  # no (unfenced) RECURRING section: nothing can be standing
                recurring = None
            if recurring:
                # A standing item waits on a RECURRING gate and is never ticked: ticking it would end its loop silently.
                r_start, r_end = recurring
                gates = {t for t, _, _ in entries(text[r_start:r_end])}
                waits = {t.replace("`", "").strip() for c in re.findall(r"\(blocked-on:([^)]*)\)", line) for t in c.split(",")}
                if gates & waits:
                    raise ValueError("standing item: it waits on a RECURRING gate; rearm the gate instead of completing it")
            if action == "complete":
                line = re.sub(r"^(\s*[-*]\s+)\[ \]", r"\1[x]", line) + " — " + sha + ": " + result
            else:
                line += " (blocked-on: " + sha + ")"
            body = body[:lo] + line + "\n" + body[hi:]
            text = text[:start] + body + text[end:]
            if action == "block":
                hold_start, _ = section(text, "## HOLD QUEUE")
                entry = "\n- [ ] **" + sha + " — OWNER GATE for " + tag + ": " + result + "**\n"
                text = text[:hold_start] + entry + text[hold_start:]
            elif not pending_entries(body):
                text, n = re.subn(r"(?m)^RUN STATUS:.*$", "RUN STATUS: COMPLETE", text)
                if n != 1:
                    raise ValueError("expected one RUN STATUS marker")
        elif action == "approve":
            # Record the owner's yes on a HOLD QUEUE gate. Ticking it is what unblocks the items that wait on it:
            # next-queue-item.sh counts a prerequisite met once its tag is ticked and open nowhere. Editing only
            # SUITE_TODO.md leaves the gate open and the item waiting (W41.seg-cheap-more, 2026-10-13).
            tag, note = values
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
                raise ValueError("invalid tag")
            if "\n" in note or not note.strip():
                raise ValueError("note must be one non-empty line")
            start, end = section(text, "## HOLD QUEUE")
            body = text[start:end]
            matches = [(lo, hi) for t, lo, hi in pending_entries(body) if t == tag]
            if len(matches) != 1:
                raise ValueError("expected exactly one unchecked HOLD QUEUE gate")
            lo, hi = matches[0]
            line = re.sub(r"^(\s*[-*]\s+)\[ \]", r"\1[x]", body[lo:hi].rstrip("\n"))
            line += " — OWNER ANSWERED " + time.strftime("%Y-%m-%d") + ": " + note.strip()
            body = body[:lo] + line + "\n" + body[hi:]
            text = text[:start] + body + text[end:]
        elif action == "hold":
            # Hand an item to the owner: append `(needs: owner)` (hooks.py HOLD_MARK) and a dated note, so the queue stops
            # offering it. A Sherlock item's preparing session ends this way (execution-plans/sherlock-access.md).
            tag, note = values
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
                raise ValueError("invalid tag")
            if "\n" in note or not note.strip():
                raise ValueError("note must be one non-empty line")
            start, end = section(text, "## WORK QUEUE")
            body = text[start:end]
            matches = [(lo, hi) for t, lo, hi in pending_entries(body) if t == tag]
            if len(matches) != 1:
                raise ValueError("expected exactly one unchecked queue item")
            lo, hi = matches[0]
            line = body[lo:hi].rstrip("\n")
            if HOLD.search(line):
                raise ValueError("item is already held for the owner")
            if MARKERS.search(note):
                raise ValueError("note must not carry a queue marker such as (blocked-on: ...)")
            line += " (needs: owner) — HELD " + time.strftime("%Y-%m-%d") + ": " + note.strip()
            body = body[:lo] + line + "\n" + body[hi:]
            text = text[:start] + body + text[end:]
        elif action == "release":
            # Undo a hold once the owner's session has done its part (a Sherlock item's results collected): drop the
            # `(needs: owner)` marker and say why, keeping the HELD note as history.
            tag, note = values
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
                raise ValueError("invalid tag")
            if "\n" in note or not note.strip() or MARKERS.search(note):
                raise ValueError("note must be one non-empty line without queue markers")
            start, end = section(text, "## WORK QUEUE")
            body = text[start:end]
            matches = [(lo, hi) for t, lo, hi in pending_entries(body) if t == tag]
            if len(matches) != 1:
                raise ValueError("expected exactly one unchecked queue item")
            lo, hi = matches[0]
            line = body[lo:hi].rstrip("\n")
            if not re.search(r" \(needs:\s*owner\)", line, re.I):
                raise ValueError("item is not held with (needs: owner)")
            line = re.sub(r" \(needs:\s*owner\)", "", line, count=1, flags=re.I)
            line += " — RELEASED " + time.strftime("%Y-%m-%d") + ": " + note.strip()
            body = body[:lo] + line + "\n" + body[hi:]
            text = text[:start] + body + text[end:]
        elif action in ("due", "rearm"):
            # A machine-ticked gate in `## RECURRING` (W40.token-pass): `due` ticks it, so the standing WORK QUEUE
            # item blocked on it runs; `rearm` unticks it once that item's session has done its pass (or files it unticked). Not a HOLD QUEUE
            # gate: the owner is never asked about it (hooks.py holds reads the HOLD QUEUE only). The section is
            # created after the HOLD QUEUE the first time.
            tag, note = values
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
                raise ValueError("invalid tag")
            if "\n" in note or not note.strip() or MARKERS.search(note):
                raise ValueError("note must be one non-empty line without queue markers")
            try:
                start, end = section(text, "## RECURRING")
            except ValueError:
                if re.search(r"(?m)^## RECURRING", text):
                    raise
                _, hold_end = section(text, "## HOLD QUEUE")
                head = "## RECURRING (machine-ticked gates of standing items: plan-edit.sh due|rearm, never the owner's)\n\n"
                text = text[:hold_end] + head + "\n" + text[hold_end:]
                start = end = hold_end + len(head)
            body = text[start:end]
            mine = [(lo, hi) for t, lo, hi in entries(body) if t == tag]
            if len(mine) > 1:
                raise ValueError("expected at most one line for the gate")
            line = "- [%s] **%s** — %s %s: %s" % ("x" if action == "due" else " ", tag,
                                                 "DUE" if action == "due" else "rearmed", time.strftime("%Y-%m-%d"),
                                                 note.strip())
            if mine:
                lo, hi = mine[0]
                body = body[:lo] + line + "\n" + body[hi:]
            else:
                body = line + "\n" + body
            text = text[:start] + body + text[end:]
            if action == "due":
                text = re.sub(r"(?m)^RUN STATUS: COMPLETE[ \t]*$", "RUN STATUS: IN_PROGRESS", text)
        elif action == "add":
            # File new work into the WORK QUEUE after AFTER-TAG, so an item filed in SUITE_TODO reaches the resolver.
            tag, after, item = values
            for value in (tag, after):
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value):
                    raise ValueError("invalid tag")
            if "\n" in item or "\r" in item:
                raise ValueError("item text must be one line")
            item = re.sub(r"^\s*[-*]\s+\[[ xX]\]\s*", "", item.strip())
            first = re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", re.sub(r"^`", "", re.sub(r"^\*+\s*", "", item)))
            if not first or first[0] != tag:
                raise ValueError("item text must begin with its tag")
            if any(t == tag for t, _, _ in entries(text)):
                raise ValueError("tag already has a checkbox line in the plan")
            start, end = section(text, "## WORK QUEUE")
            body = text[start:end]
            anchors = [hi for t, _, hi in entries(body) if t == after]
            if len(anchors) != 1:
                raise ValueError("expected exactly one queue item to add after")
            hi = anchors[0]
            prefix = "" if body[:hi].endswith("\n") else "\n"
            body = body[:hi] + prefix + "- [ ] " + item + "\n" + body[hi:]
            text = text[:start] + body + text[end:]
            # New open work reopens a finished queue.
            text = re.sub(r"(?m)^RUN STATUS: COMPLETE[ \t]*$", "RUN STATUS: IN_PROGRESS", text)
        else:
            if action == "log":
                heading, content = "## Session Log", values[0]
            elif action == "report":
                heading, content = "## Daemon Report", values[0]
            elif action == "append":
                heading, content = values
            else:
                raise ValueError("unknown action")
            if not heading.startswith("## ") or "\n" in heading:
                raise ValueError("invalid heading")
            pos, _ = section(text, heading)
            # Newest-first, so a report lands above the settled walkthrough anchor.
            text = text[:pos] + "\n" + content.rstrip() + "\n" + text[pos:]
        fd, tmp = tempfile.mkstemp(prefix=plan.name + ".", dir=plan.parent)
        try:
            with os.fdopen(fd, "w") as out:
                out.write(text)
                out.flush()
                os.fsync(out.fileno())
            os.chmod(tmp, plan.stat().st_mode)
            os.replace(tmp, plan)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


if __name__ == "__main__":
    try:
        edit(Path(sys.argv[1]), sys.argv[2], sys.argv[3:])
    except (OSError, ValueError, IndexError) as exc:
        print("plan-edit: " + str(exc), file=sys.stderr)
        sys.exit(2)
