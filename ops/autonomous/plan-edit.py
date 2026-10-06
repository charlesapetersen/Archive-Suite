#!/usr/bin/env python3
"""Atomic region-bounded plan edits under the lock also held by idle compaction."""
import fcntl
import os
from pathlib import Path
import re
import sys
import tempfile


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
