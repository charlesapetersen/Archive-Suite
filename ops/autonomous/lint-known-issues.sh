#!/usr/bin/env bash
# lint-known-issues.sh — every new KNOWN_ISSUES bullet carries a disposition (W49.ki-lint).
#
# Owner, 2026-11-19: the Luna label cost sat in ArchiveProcessor/KNOWN_ISSUES.md with no item and was found only
# because the owner asked. CLAUDE.md "Definition of done" now says every bullet ends with one of
#   (queued: TAG)      TAG is an open item in SUITE_TODO.md (several may be listed, comma-separated, then prose)
#   (accepted: …)      the design reason or the owner's call, in words
#   (asked: GATE)      GATE is an open owner gate (`- [ ] **GATE` in the plan's HOLD QUEUE)
# A trailing full stop after the parenthesis is allowed. This lint reads the three apps' KNOWN_ISSUES.md.
#
# Which bullets: a top-level bullet (`- ` or `* ` at column 0, through its indented continuation and sub-bullets,
# up to a blank line, heading or the next top-level bullet) whose text, whitespace-normalised, is not among that
# file's bullets at BASE. So a bullet added or reworded since BASE must have a disposition; a bullet untouched
# since BASE is left to W49.ki-audit-* and never blocks.
# BASE is pinned below, not the merge base with origin/main: the gate runs on main, where the merge base is HEAD
# itself and the lint would check nothing. Override with KI_LINT_BASE (a worktree can pass its merge base).
# Every bullet, old or new, that says `queued:` a tag which has shipped (it is in SUITE_TODO_DONE.md and no longer
# open) is reported as well: the item that fixes a limit removes or rewrites its bullet when it ships.
#
# Exit 0 clean, 1 findings, 2 cannot run. `--self-test` builds a scratch repo, seeds one bullet of each kind, a
# bad tag, a closed gate and a shipped tag, and demands the right verdict on each. Both are health-gate steps.
set -uo pipefail

ROOT="${KI_LINT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# The last commit before this lint: every bullet already on main then is W49.ki-audit-*'s, not this lint's.
PINNED_BASE="cfb25a60"
BASE="${KI_LINT_BASE:-$PINNED_BASE}"

if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  r="$tmp/repo"; mkdir -p "$r/ArchiveProcessor" "$r/ArchiveReader" "$r/ArchiveNotes" "$r/.maintenance"
  g() { git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
  printf -- '- [ ] **`W1.open` — an open item [S]**\n' > "$r/SUITE_TODO.md"
  printf -- '- [x] **W1.done — a shipped item** · §x SHIPPED\n  <!-- /W1.done -->\n' > "$r/SUITE_TODO_DONE.md"
  printf -- '## HOLD QUEUE\n- [ ] **W1.open-owner-ok — OWNER GATE for W1.open: x?**\n- [x] **W1.old-owner-ok — OWNER GATE: y?**\n' \
    > "$r/.maintenance/AUTONOMOUS_PLAN.md"
  printf '# Known issues\n\n- An old bullet with no disposition,\n  wrapped over two lines.\n' > "$r/ArchiveProcessor/KNOWN_ISSUES.md"
  printf '# Known issues\n' > "$r/ArchiveReader/KNOWN_ISSUES.md"; printf '# Known issues\n' > "$r/ArchiveNotes/KNOWN_ISSUES.md"
  g init -q && g add -A && g commit -qm base || { echo "✗ self-test: cannot build the scratch repo"; exit 2; }
  base="$(git -C "$r" rev-parse HEAD)"
  run() { KI_LINT_ROOT="$r" KI_LINT_BASE="$base" KI_LINT_PLAN="$r/.maintenance/AUTONOMOUS_PLAN.md" bash "$0"; }
  ki="$r/ArchiveReader/KNOWN_ISSUES.md"
  fails=0
  # expect PASS|FAIL "label" "bullet text"
  expect() {
    printf '# Known issues\n\n%b\n' "$3" > "$ki"
    if run >"$tmp/out" 2>&1; then got=PASS; else got=FAIL; fi
    if [ "$got" = "$1" ]; then echo "  ✓ $2 → $got"; else echo "  ✗ $2 → $got, wanted $1"; sed 's/^/      /' "$tmp/out"; fails=$((fails + 1)); fi
  }
  run >"$tmp/out" 2>&1 || { echo "✗ self-test: the untouched base does not pass"; cat "$tmp/out"; exit 1; }
  expect PASS "queued on an open tag"       '- A limit, wrapped\n  over a line (queued: W1.open).'
  expect PASS "accepted with a reason"      '- A limit (accepted: owner, 2026-11-19 (call 9), not worth it)'
  expect PASS "asked on an open gate"       '- A limit (asked: W1.open-owner-ok)'
  expect PASS "a sub-bullet, then the end"  '- A limit:\n  - one case\n  - another (queued: W1.open)'
  expect FAIL "no disposition"              '- A new limit with nothing at the end.'
  expect FAIL "disposition mid-bullet"      '- A limit (queued: W1.open) and then more words.'
  expect PASS "queued, then prose"          '- A limit (queued: W1.open, which fixes it, mostly)'
  expect FAIL "queued on prose alone"       '- A limit (queued: later, maybe)'
  expect FAIL "queued on an unknown tag"    '- A limit (queued: W9.nope)'
  expect FAIL "queued on a shipped tag"     '- A limit (queued: W1.done)'
  expect FAIL "one of two tags shipped"     '- A limit (queued: W1.open, W1.done)'
  expect FAIL "asked on a closed gate"      '- A limit (asked: W1.old-owner-ok)'
  expect FAIL "accepted with no reason"     '- A limit (accepted: )'
  expect FAIL "a second no-disposition bullet" '- Fine (accepted: by design)\n* Not fine.'
  # An old bullet reworded loses its exemption; an old bullet queued on a tag that later ships is reported.
  printf '# Known issues\n\n- An old bullet with no disposition, reworded.\n' > "$r/ArchiveProcessor/KNOWN_ISSUES.md"
  expect FAIL "an old bullet reworded"      ''
  printf '# Known issues\n\n- An old bullet with no disposition,\n  wrapped over two lines.\n' > "$r/ArchiveProcessor/KNOWN_ISSUES.md"
  expect PASS "the old bullet restored, rewrapped nowhere" ''
  printf '# Known issues\n\n- Queued long ago (queued: W1.done)\n' > "$r/ArchiveNotes/KNOWN_ISSUES.md"
  g add -A && g commit -qm more; base="$(git -C "$r" rev-parse HEAD)"
  expect FAIL "an old bullet queued on a shipped tag" ''
  [ "$fails" -eq 0 ] || { echo "✗ KNOWN_ISSUES lint self-test: $fails case(s) wrong"; exit 1; }
  echo "✓ KNOWN_ISSUES lint self-test: each disposition kind passes; none, mid-bullet, bad tag, shipped tag, closed gate and a reworded old bullet fail"
  exit 0
fi

command -v python3 >/dev/null || { echo "✗ python3 not found"; exit 2; }
git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null || { echo "✗ base commit $BASE is not in $ROOT"; exit 2; }
PLAN="${KI_LINT_PLAN:-$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)/.." && pwd)/.maintenance/AUTONOMOUS_PLAN.md}"

KI_ROOT="$ROOT" KI_BASE="$BASE" KI_PLAN="$PLAN" python3 - <<'PY'
import os, re, subprocess, sys

root, base, plan = os.environ["KI_ROOT"], os.environ["KI_BASE"], os.environ["KI_PLAN"]
FILES = ["ArchiveProcessor/KNOWN_ISSUES.md", "ArchiveReader/KNOWN_ISSUES.md", "ArchiveNotes/KNOWN_ISSUES.md"]
TAG = r"[A-Za-z0-9][A-Za-z0-9._-]*"

def read(path):
    try:
        with open(os.path.join(root, path), encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None

def bullets(text):
    """Top-level bullets: (first line number, whitespace-normalised text)."""
    out, cur, start, fence = [], None, 0, False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
        top = not fence and re.match(r"[-*] ", line)
        if top or (not fence and (not line.strip() or line.startswith("#"))):
            if cur is not None:
                out.append((start, " ".join(" ".join(cur).split())))
            cur = None
        if top:
            cur, start = [line[2:]], n
        elif cur is not None:
            cur.append(line)
    if cur is not None:
        out.append((start, " ".join(" ".join(cur).split())))
    return out

todo = read("SUITE_TODO.md") or ""
done = read("SUITE_TODO_DONE.md") or ""
open_tags = set(re.findall(r"^\s*- \[ \] \*\*`?(" + TAG + r")`?", todo, re.M))
shipped = set(re.findall(r"<!-- /(" + TAG + r") -->", done)) | set(re.findall(r"^\s*- \[x\] \*\*`?(" + TAG + r")`?", done, re.M))
if os.path.exists(plan):
    with open(plan, encoding="utf-8") as f:
        open_gates = set(re.findall(r"^- \[ \] \*\*`?(" + TAG + r")`? — OWNER GATE", f.read(), re.M))
else:  # a clone without the gitignored plan: a gate an open item is still blocked on counts as open
    open_gates = {t for line in todo.splitlines() if re.match(r"\s*- \[ \]", line)
                  for b in re.findall(r"\(blocked-on: ([^)]*)\)", line) for t in re.split(r"[,\s]+", b) if t.endswith("owner-ok")}
if not open_tags:
    print("✗ found no open items in SUITE_TODO.md: the item pattern no longer matches"); sys.exit(2)

END = re.compile(r"\((queued|accepted|asked): *(.*)\)\.?$")
problems, checked = [], 0
for path in FILES:
    text = read(path)
    if text is None:
        print(f"✗ {path} is missing"); sys.exit(2)
    shown = subprocess.run(["git", "-C", root, "show", f"{base}:{path}"], capture_output=True, text=True)
    old = {b for _, b in bullets(shown.stdout)} if shown.returncode == 0 else set()
    for line, b in bullets(text):
        new = b not in old
        checked += new
        # The disposition is the LAST parenthetical: for accepted, its reason may hold parentheses of its own.
        m = None
        for kind in ("queued", "accepted", "asked"):
            i = b.rfind(f"({kind}:")
            if i >= 0 and (m is None or i > m[0]):
                m = (i, kind)
        disp = END.match(b[m[0]:]) if m else None
        if disp is None:
            if new:
                problems.append(f"{path}:{line}: does not end with (queued: TAG), (accepted: reason) or (asked: GATE)")
            continue
        kind, body = disp.group(1), disp.group(2).strip()
        if kind == "queued":
            # Comma-separated tags, then optional prose ("(queued: W1.a, which dates …)"): read tags up to the first
            # part that is not a single tag-shaped word. The first part must be a tag.
            tags = []
            for part in body.split(","):
                if not re.fullmatch(r"[A-Z][A-Za-z0-9]*[.-][A-Za-z0-9._-]+", part.strip()):
                    break
                tags.append(part.strip())
            if not tags:
                problems.append(f"{path}:{line}: queued: does not start with a tag")
            for t in tags:
                if t in open_tags:
                    continue
                if t in shipped:  # reported for old bullets too: the shipped item should have closed it
                    problems.append(f"{path}:{line}: queued on {t}, which has shipped — close or re-dispose the bullet")
                elif new:
                    problems.append(f"{path}:{line}: queued on {t}, which is not an open item in SUITE_TODO.md")
        elif not new:
            continue
        elif kind == "accepted" and len(body) < 3:
            problems.append(f"{path}:{line}: accepted with no reason")
        elif kind == "asked" and body not in open_gates:
            problems.append(f"{path}:{line}: asked on {body or '(nothing)'}, which is not an open owner gate")

for p in problems:
    print("✗ " + p)
if problems:
    print(f"✗ {len(problems)} KNOWN_ISSUES problem(s); the rule is CLAUDE.md \"Definition of done\" (W49.ki-lint)"); sys.exit(1)
print(f"✓ KNOWN_ISSUES dispositions: {checked} bullet(s) new since {base[:8]} all disposed; no queued tag has shipped")
PY
