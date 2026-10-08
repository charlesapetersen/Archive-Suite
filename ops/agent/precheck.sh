#!/usr/bin/env bash
# precheck hook: can the project run at all? The refusals ops/autonomous/daemon.sh makes at start, read-only:
# the claude CLI (outside ~/Desktop, for launchd and TCC), the codex CLI and preamble when $AGENT_STATE/agent
# asks for Codex, the resume prompt, the plan, the keychain provider list, and a plan whose RUN STATUS is
# COMPLETE (anchored, as daemon.sh reads it). Exit 1 with the reason to refuse, else 0. Warnings daemon.sh only
# prints (a changed keychain provider item, signing) are not refusals and are not repeated here; the missing
# keychain marker is reported by the status hook.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BIN="$HOME/.local/bin"
CLAUDE="${AGENT_CLAUDE:-$BIN/claude}"
if [ -x "$BIN/codex" ]; then CODEX="$BIN/codex"
else CODEX="/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"; fi
CODEX="${AGENT_CODEX:-$CODEX}"
agent="$( { tr -d '[:space:]' < "$STATE/agent"; } 2>/dev/null)"; agent="${agent:-claude}"
refuse() { echo "$*"; exit 1; }
case "$agent" in
  codex|both)
    [ -x "$CODEX" ] || refuse "codex CLI not executable at $CODEX"
    [ -s "$REPO/ops/autonomous/codex-preamble.txt" ] || refuse "codex preamble missing: $REPO/ops/autonomous/codex-preamble.txt" ;;
esac
case "$agent" in
  claude|both) [ -x "$CLAUDE" ] || refuse "claude CLI not executable at $CLAUDE (it must live outside ~/Desktop for launchd)" ;;
esac
[ -f "$REPO/ops/autonomous/resume-prompt.txt" ] || refuse "resume prompt missing: $REPO/ops/autonomous/resume-prompt.txt"
[ -f "$PLAN" ] || refuse "plan missing: $PLAN (write it, queue and directives, before starting)"
[ -r "$SCRIPTS/keychain-provider-accounts.sh" ] || refuse "keychain provider list missing: $SCRIPTS/keychain-provider-accounts.sh"
if grep -m1 '^RUN STATUS:' "$PLAN" 2>/dev/null | cut -c1-90 | grep -qE '^RUN STATUS:[[:space:]]*COMPLETE'; then
  refuse "RUN STATUS is COMPLETE in $PLAN; set it to IN_PROGRESS with unchecked WORK QUEUE items to run again"
fi
exit 0
