#!/usr/bin/env bash
# fingerprint hook: what counts as progress state. The same inputs, in the same order, as work_fingerprint() in
# ops/autonomous/archive-suite-autonomous.sh (HEAD, origin/main, the plan's RUN STATUS line and its WORK QUEUE
# section), printed rather than hashed: the engine hashes them. Session Log, Daemon Report and E2E findings
# stay out on purpose, as there (a no-op session appends to them). Read-only.
# Test: ops/agent/tests/test_hooks.py checks this output hashes to the daemon function's own answer.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
git -C "$REPO" rev-parse HEAD 2>/dev/null || echo no-head
git -C "$REPO" rev-parse origin/main 2>/dev/null || echo no-origin
grep -m1 '^RUN STATUS:' "$PLAN" 2>/dev/null || echo no-status
awk '/^## WORK QUEUE/{f=1;print;next} f && /^## /{exit} f' "$PLAN" 2>/dev/null
exit 0
