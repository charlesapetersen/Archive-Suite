#!/bin/bash
# require-unsandboxed.sh — sourced first by every script that launches the Processor app. Refuses to run inside
# the Codex sandbox (owner, 2026-10-05: "I keep getting 'ArchiveProcessor quit unexpectedly'").
#
# WHY: Codex runs commands in a seatbelt sandbox that does not let an app register with the window server. A
# headless Processor launch there aborts in `NSApplication init` (`_RegisterApplication`, SIGABRT), and macOS
# then shows the owner a "quit unexpectedly" dialog for EVERY run — 25 of them in 30 s on 2026-10-05, when a
# session looped `test-recovery.sh` to catch a flake. Inside the sandbox Codex sets CODEX_SANDBOX=seatbelt; a
# command it runs outside the sandbox (an approved escalation) does not have it (measured 2026-10-05).
#
# Exit 3 = "run me outside the sandbox", distinct from a test failure (1) and a usage error (2).
if [ -n "${CODEX_SANDBOX:-}" ]; then
  echo "$(basename "${0:-script}"): this launches the Archive Processor app, which cannot start inside the Codex sandbox" >&2
  echo "  (it aborts, and macOS shows the owner a crash dialog for each run). Run this command OUTSIDE the sandbox:" >&2
  echo "  request an escalation for it. Nothing was launched." >&2
  exit 3
fi
