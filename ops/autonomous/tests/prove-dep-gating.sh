#!/usr/bin/env bash
# prove-dep-gating.sh — regression harness for next-queue-item.sh (WS9 `blocked-on` dependency gating).
# Builds synthetic AUTONOMOUS_PLAN.md + SUITE_TODO.md fixtures and asserts the resolver's per-item verdicts,
# ordering, and exit codes across: no-deps, a blocked chain, a satisfied prerequisite, a missing prerequisite,
# a circular dependency, multiple prerequisites, a prerequisite satisfied via SUITE_TODO, and the empty queue.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../next-queue-item.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: next-queue-item.sh not found at $SCRIPT"; exit 1; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
chk(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

# plan(queue_lines...) — write a plan whose WORK QUEUE holds the given item lines verbatim.
plan(){ { printf '# P\n\nRUN STATUS: IN_PROGRESS\n\n## PRIME DIRECTIVES\n- x\n\n## WORK QUEUE\n\n'
          for l in "$@"; do printf '%s\n' "$l"; done
          printf '\n## Session Log\n- done\n'; } > "$SANDBOX/plan.md"; }
todo(){ { printf '# SUITE_TODO\n\n'; for l in "$@"; do printf '%s\n' "$l"; done; } > "$SANDBOX/todo.md"; }
# Completed items are archived out of SUITE_TODO into SUITE_TODO_DONE.md, but must still SATISFY dependencies.
donefile(){ { printf '# SUITE_TODO_DONE\n\n'; for l in "$@"; do printf '%s\n' "$l"; done; } > "$SANDBOX/done.md"; }
run(){ AUTONOMOUS_PLAN="$SANDBOX/plan.md" AUTONOMOUS_SUITE_TODO="$SANDBOX/todo.md" \
       AUTONOMOUS_SUITE_TODO_DONE="$SANDBOX/done.md" \
       bash "$SCRIPT" "$SANDBOX" >"$SANDBOX/out.txt" 2>&1; echo $? >"$SANDBOX/rc.txt"; }
rc(){ cat "$SANDBOX/rc.txt"; }
verdict(){ awk -F'\t' -v s="$1" -v t="$2" '$1==s&&$2==t' "$SANDBOX/out.txt" | grep -q .; }  # status/tag present?
listed(){  awk -F'\t' -v t="$1" '$2==t' "$SANDBOX/out.txt" | grep -q .; }                    # tag appears at all?

echo "== next-queue-item.sh regression =="
todo   # default empty SUITE_TODO unless a case overrides

# ---------- A: no blocked-on — every item ok, in order, exit 0 ----------
plan "- [ ] **W1 — first thing** — do it." "- [ ] **W2 — second** — later."
run
chk "A exit 0 (something actionable)"        "[ \"\$(rc)\" = 0 ]"
chk "A W1 is ok"                              "awk -F'\t' '\$1==\"ok\"&&\$2==\"W1\"' '$SANDBOX/out.txt' | grep -q ."
chk "A W2 is ok"                             "awk -F'\t' '\$1==\"ok\"&&\$2==\"W2\"' '$SANDBOX/out.txt' | grep -q ."
chk "A order preserved (W1 before W2)"        "[ \"\$(awk -F'\t' '\$1==\"ok\"{print \$2; exit}' '$SANDBOX/out.txt')\" = W1 ]"

# ---------- B: blocked chain — B(blocked-on:A) while A is [ ] -> A ok, B blocked ----------
plan "- [ ] **W.a — prereq** — must finish first." "- [ ] **W.b — dependent** (blocked-on: W.a) — needs a."
run
chk "B exit 0 (A is actionable)"             "[ \"\$(rc)\" = 0 ]"
chk "B prereq W.a ok"                         "awk -F'\t' '\$1==\"ok\"&&\$2==\"W.a\"' '$SANDBOX/out.txt' | grep -q ."
chk "B dependent W.b blocked on W.a"          "awk -F'\t' '\$1==\"blocked:W.a\"&&\$2==\"W.b\"' '$SANDBOX/out.txt' | grep -q ."

# ---------- C: satisfied prerequisite — A is [x] -> B ok ----------
plan "- [x] **W.a — prereq done** \`abc123\` — shipped." "- [ ] **W.b — dependent** (blocked-on: W.a) — go."
run
chk "C exit 0"                               "[ \"\$(rc)\" = 0 ]"
chk "C dependent W.b now ok"                  "awk -F'\t' '\$1==\"ok\"&&\$2==\"W.b\"' '$SANDBOX/out.txt' | grep -q ."
chk "C done prereq not listed as [ ] item"    "! awk -F'\t' '\$2==\"W.a\"' '$SANDBOX/out.txt' | grep -q ."

# ---------- D: missing prerequisite — blocked-on a tag that doesn't exist -> blocked (surfaced) ----------
plan "- [ ] **W.b — dependent** (blocked-on: W.ghost) — prereq absent."
run
chk "D exit 4 (only item is blocked)"        "[ \"\$(rc)\" = 4 ]"
chk "D blocked on the missing tag"            "awk -F'\t' '\$1==\"blocked:W.ghost\"&&\$2==\"W.b\"' '$SANDBOX/out.txt' | grep -q ."

# ---------- E: circular dependency — A(blocked-on:B) + B(blocked-on:A), both [ ] -> both blocked, exit 4 ----------
plan "- [ ] **W.a — x** (blocked-on: W.b) — cycle." "- [ ] **W.b — y** (blocked-on: W.a) — cycle."
run
chk "E exit 4 (deadlock -> nothing actionable)" "[ \"\$(rc)\" = 4 ]"
chk "E W.a blocked"                          "awk -F'\t' '\$1==\"blocked:W.b\"&&\$2==\"W.a\"' '$SANDBOX/out.txt' | grep -q ."
chk "E W.b blocked"                          "awk -F'\t' '\$1==\"blocked:W.a\"&&\$2==\"W.b\"' '$SANDBOX/out.txt' | grep -q ."

# ---------- F: multiple prerequisites — one done, one pending -> blocked on the pending one only ----------
plan "- [x] **W.a — done** \`d\` — ok." "- [ ] **W.c — pending** — not yet." \
     "- [ ] **W.z — dependent** (blocked-on: W.a, W.c) — needs both."
run
chk "F exit 0 (W.c is actionable)"           "[ \"\$(rc)\" = 0 ]"
chk "F W.z blocked ONLY on the pending W.c"   "awk -F'\t' '\$1==\"blocked:W.c\"&&\$2==\"W.z\"' '$SANDBOX/out.txt' | grep -q ."

# ---------- G: prerequisite satisfied via SUITE_TODO (not the plan) -> dependent ok ----------
todo "- [x] **W.ext — shipped elsewhere** \`e\` — done in SUITE_TODO."
plan "- [ ] **W.d — dependent** (blocked-on: W.ext) — prereq lives in SUITE_TODO."
run
chk "G exit 0 (prereq done in SUITE_TODO)"   "[ \"\$(rc)\" = 0 ]"
chk "G dependent W.d ok"                      "awk -F'\t' '\$1==\"ok\"&&\$2==\"W.d\"' '$SANDBOX/out.txt' | grep -q ."
todo   # reset SUITE_TODO

# ---------- H: SUITE_TODO shows prereq STILL pending -> dependent blocked even if plan lacks it ----------
todo "- [ ] **W.ext — not done yet** — pending in SUITE_TODO."
plan "- [ ] **W.d — dependent** (blocked-on: W.ext) — prereq pending elsewhere."
run
chk "H exit 4 (prereq pending in SUITE_TODO)" "[ \"\$(rc)\" = 4 ]"
chk "H dependent blocked"                     "awk -F'\t' '\$1==\"blocked:W.ext\"&&\$2==\"W.d\"' '$SANDBOX/out.txt' | grep -q ."
todo

# ---------- I: no [ ] items at all -> exit 3 ----------
plan "- [x] **W.a — done** \`a\` — nothing left."
run
chk "I exit 3 (empty actionable queue)"      "[ \"\$(rc)\" = 3 ]"

# ---------- J: tag extraction survives bold + bracket qualifier ----------
plan "- [ ] **W3.f1 [HIGH] relay chain** — a tagged review-fix item."
run
chk "J tag parsed as W3.f1 (not [HIGH])"      "verdict ok W3.f1"

# ---------- K: a `[X]` in an UNCHECKED prereq's TEXT must NOT read as done (HIGH regression) ----------
plan "- [ ] **W5.a — fix the [X] button label** — genuinely NOT done." \
     "- [ ] **W5.b — wire pane** (blocked-on: W5.a) — needs W5.a."
run
chk "K prereq with [X] in text still PENDING -> dep blocked" "verdict blocked:W5.a W5.b"
chk "K the prereq item itself is actionable"                 "verdict ok W5.a"

# ---------- L: a `[x]` example inside a fenced code block must NOT pollute the done-set (MEDIUM regression) ----------
plan '```' "- [x] **W7.a — example of a done item** — inside a fence, NOT real." '```' \
     "- [ ] **W7.b — wire** (blocked-on: W7.a) — W7.a is only a code example."
run
chk "L fenced [x] not counted done -> dep blocked"  "verdict blocked:W7.a W7.b"
chk "L fenced item not surfaced as a queue item"    "! listed W7.a"

# ---------- M1: MULTIPLE (blocked-on:) clauses on one line are ALL parsed (MEDIUM regression) ----------
plan "- [x] **W8.done — a** \`s\` — shipped." "- [ ] **W8.pending — b** — not yet." \
     "- [ ] **W8.dep — c** (blocked-on: W8.done) (blocked-on: W8.pending) — two clauses."
run
chk "M1 second clause not dropped -> blocked on pending" "verdict blocked:W8.pending W8.dep"

# ---------- M2: a (blocked-on:) WRAPPED onto a continuation line is still caught (MEDIUM regression) ----------
plan "- [ ] **W9.a — prereq pending** — not done." \
     "- [ ] **W9.b — dependent**" "  (blocked-on: W9.a) — the dep clause is on the wrapped line."
run
chk "M2 wrapped clause caught -> dep blocked"  "verdict blocked:W9.a W9.b"
chk "M2 prereq itself actionable"              "verdict ok W9.a"

# ---------- N: region boundary — `### Wave` does NOT end the region; the next `## ` DOES ----------
{ printf '# P\n\nRUN STATUS: IN_PROGRESS\n\n## PRIME DIRECTIVES\n- x\n\n## WORK QUEUE\n\n'
  printf '### Wave 1 — a subheader\n'
  printf -- '- [ ] **W.inwave — under a ### subheader** — must be picked.\n'
  printf '\n## Session Log\n'
  printf -- '- [ ] **W.after — past the ## boundary** — must be EXCLUDED.\n'
} > "$SANDBOX/plan.md"
run
chk "N item under ### Wave is in the region"   "listed W.inwave"
chk "N item after the next ## is excluded"     "! listed W.after"

# ---------- O: a checkbox inside a blockquote is skipped (not a real item / not a done tag) ----------
plan "> - [x] **W.bq — quoted example** — inside a blockquote, NOT real." \
     "- [ ] **W.real — dep** (blocked-on: W.bq) — W.bq is only a quote."
run
chk "O blockquoted [x] not counted done -> dep blocked" "verdict blocked:W.bq W.real"
chk "O blockquoted item not surfaced"                   "! listed W.bq"

# ---------- P: a (blocked-on:) clause SPLIT across a line break is still caught (LOW regression) ----------
plan "- [ ] **W.a — prereq pending** — not done." \
     "- [ ] **W.b — dependent** (blocked-on:" "  W.a) — the clause is split across the line break."
run
chk "P split-across-lines clause caught -> dep blocked" "verdict blocked:W.a W.b"

# ---------- Q: a `[x]` example inside a TILDE (~~~) fence must NOT pollute the done-set (LOW regression) ----------
plan '~~~' "- [x] **W.tf — example done item** — inside a tilde fence, NOT real." '~~~' \
     "- [ ] **W.dep — real** (blocked-on: W.tf) — W.tf is only an example."
run
chk "Q tilde-fenced [x] not counted done -> blocked"  "verdict blocked:W.tf W.dep"
chk "Q tilde-fenced item not surfaced"                "! listed W.tf"

# ---------- R: a `[x]` item's continuation deps must NOT leak onto the next `[ ]` item (non-leak) ----------
plan "- [x] **W.x — done item** \`s\`" "  (blocked-on: W.ghost) — this dep is on a DONE item; ignore it." \
     "- [ ] **W.y — next** — has no dependency of its own."
run
chk "R done-item continuation dep does not leak -> W.y ok" "verdict ok W.y"

# ---------- S: pend-wins — a tag `[x]` in a stray note but `[ ]` in the queue counts as PENDING ----------
todo "- [x] **W.p — looks done in a stray note** \`s\` — but the queue still has it open."
plan "- [ ] **W.p — the REAL pending item** — not done." \
     "- [ ] **W.q — dependent** (blocked-on: W.p) — must stay blocked."
run
chk "S pend-wins: [x] elsewhere + [ ] in queue -> still blocked" "verdict blocked:W.p W.q"
todo

# --- the completed-item ARCHIVE satisfies dependencies (consolidation phase 2) --------------------------
# A tag the resolver cannot find reads as NOT done, so archiving a [x] item that something depends on would
# permanently block the dependent — the dead end W3.cap-r4 once created for W17.stg1. Zero items were exposed
# on the day of the split, but that was luck: the next `(blocked-on: <archived tag>)` anyone writes would hit it.
donefile "- [x] **W.arch — shipped, then archived**"
plan "- [ ] **W.dep — needs the archived one** (blocked-on: W.arch) — must be actionable."
run
chk "T archive: a dep satisfied ONLY by SUITE_TODO_DONE resolves as done" "verdict ok W.dep"

# ...but the [ ]-anywhere-wins rule must still beat a stale archived twin, or re-opened work runs early.
todo "- [ ] **W.arch — re-opened after shipping**"
run
chk "T archive: a re-opened item beats its stale archived [x]" "verdict blocked:W.arch W.dep"
todo

# ...and a missing archive stays a no-op, so the resolver works before the split too.
rm -f "$SANDBOX/done.md"
plan "- [ ] **W.solo — no deps**"
run
chk "T archive: absent SUITE_TODO_DONE is a no-op" "verdict ok W.solo"
donefile

echo ""
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
