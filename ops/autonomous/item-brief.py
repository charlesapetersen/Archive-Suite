#!/usr/bin/env python3
"""item-brief.py TAG — print what a session needs about one item, and nothing else (W40.token-fix, 2026-11-12).

WHY: STEP 1 of resume-prompt.txt used to say "grep SUITE_TODO.md / the plan for your tag". A tag is cited in many
other items' long one-line entries (blocked-on lists, history), so that grep returned 20-30K characters per
session (token pass 2026-11-12). This prints the item's own entries in full and only counts the other mentions.

OUTPUT, in order:
  * SUITE_TODO.md: the checkbox entry whose tag is TAG (with its indented continuation lines)
  * the plan: its WORK QUEUE / HOLD QUEUE / RECURRING checkbox lines for TAG and for TAG's own gates (TAG-…)
  * the plan's Daemon Report: up to 8 lines mentioning TAG, each cut to 240 characters
  * execution-plans/items/TAG.md, if it exists (path and size only; Read it yourself)
  * git log --oneline --grep=TAG -10
  * a count of the other lines that mention TAG, per file, so you know whether a targeted grep is worth it.
A tag is the first [A-Za-z0-9._-] token after the checkbox, leading ** and one backtick stripped
(the rule next-queue-item.sh and check-tracker-sync.sh use).
Read-only. Exit 0; exit 2 on bad usage.
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PRIMARY = Path("/Users/cp1/Claude/Archive Suite")  # the plan is gitignored and lives in the primary checkout
BOX = re.compile(r"^\s*- \[[ xX]\] \*{0,2}`?([A-Za-z0-9._-]+)")
CUT = 240


def tag_of(line):
    m = BOX.match(line)
    return m.group(1).rstrip("`*") if m else None


def entries(lines, want):
    """Checkbox lines whose tag satisfies want(tag), each with its indented continuation lines."""
    out, i = [], 0
    while i < len(lines):
        t = tag_of(lines[i])
        if t and want(t):
            block = [lines[i]]
            j = i + 1
            while j < len(lines) and lines[j].startswith("  ") and not BOX.match(lines[j]):
                block.append(lines[j])
                j += 1
            out.append((i, block))
            i = j
        else:
            i += 1
    return out


def main():
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        sys.exit("usage: item-brief.py TAG")
    tag = sys.argv[1].strip()
    mention = re.compile(r"(?<![A-Za-z0-9._-])" + re.escape(tag) + r"(?![A-Za-z0-9_-]|\.[A-Za-z0-9])")
    todo = REPO / "SUITE_TODO.md"
    plan = PRIMARY / ".maintenance" / "AUTONOMOUS_PLAN.md"
    shown = {}

    for path, want in ((todo, lambda t: t == tag), (plan, lambda t: t == tag or t.startswith(tag + "-"))):
        print(f"== {path.name}")
        if not path.exists():
            print("   (missing)")
            continue
        lines = path.read_text().splitlines()
        found = entries(lines, want)
        for i, block in found:
            for k, line in enumerate(block):
                shown.setdefault(path, set()).add(i + k)
                print(line)
        if not found:
            print("   (no checkbox entry for this tag)")
        if path == plan:
            start = next((n for n, l in enumerate(lines) if re.match(r"^## (Daemon Report|Morning Review)", l)), None)
            if start is not None:
                end = next((n for n in range(start + 1, len(lines)) if lines[n].startswith("## ")), len(lines))
                hits = [n for n in range(start, end) if mention.search(lines[n])]
                print(f"== Daemon Report: {len(hits)} line(s) mention {tag}" + (", first 8:" if len(hits) > 8 else ""))
                for n in hits[:8]:
                    shown.setdefault(path, set()).add(n)
                    l = lines[n]
                    print(l if len(l) <= CUT else l[:CUT] + f" … [{len(l)} chars]")

    notes = REPO / "execution-plans" / "items" / f"{tag}.md"
    print(f"== {notes.relative_to(REPO)}: " + (f"{notes.stat().st_size} bytes" if notes.exists() else "none"))

    print("== git log --grep")
    log = subprocess.run(["git", "-C", str(REPO), "log", "--oneline", f"--grep={tag}", "-10"],
                         capture_output=True, text=True).stdout.strip()
    print(log or "   (no commits)")

    print("== other lines that mention the tag")
    for path in (todo, plan, REPO / "SUITE_TODO_DONE.md"):
        if path.exists():
            seen = shown.get(path, set())
            n = sum(1 for k, l in enumerate(path.read_text().splitlines()) if k not in seen and mention.search(l))
            print(f"   {path.name}: {n}")


if __name__ == "__main__":
    main()
