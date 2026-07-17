#!/bin/bash
# Fake Local Agent CLI — a deterministic, $0 stand-in for `claude -p --output-format json`, used by
# the LocalAgent tests (scripts/localagent-mechanism-test.swift and the in-app LocalAgentTestDriver).
# Same spirit as the FileRelay stand-in: no network, no key, no cost, no real model.
#
# It IGNORES all args (the real CLI flags), DRAINS stdin (the prompt — so the caller's stdin write +
# close completes and the child sees EOF, exactly like a real CLI), and emits a canned response chosen
# by $LOCALAGENT_FAKE_MODE:
#   ok         (default) success JSON; .result is a valid OCRPrompt-format transcription        exit 0
#   echostdin  success JSON whose .result reports how many stdin bytes it received               exit 0
#   garbage    non-JSON stdout (tests the client's bad-response handling)                        exit 0
#   fail       generic error on stderr                                                          exit 3
#   notlogged  a "not logged in" error on stderr (client → cli_not_logged_in)                   exit 1
#   entitlement a signed-in-but-not-authorized error (client → cli_entitlement_missing)         exit 1
#   ratelimited a usage-limit error on stderr (client → cli_rate_limited)                        exit 1
#   timeout    sleeps well past any test timeout (tests the client's SIGTERM/SIGKILL path)      exit 0
mode="${LOCALAGENT_FAKE_MODE:-ok}"

# Always drain stdin first so the process exits cleanly on EOF and reports the prompt size.
stdin_bytes=$(wc -c | tr -d ' ')

case "$mode" in
  ok)
    printf '%s\n' '{"result":"[document_start]\n[rotate_0]\nFAKE-CLI-OCR-TOKEN transcribed body line one\nbody line two","total_cost_usd":0,"num_turns":3,"is_error":false}'
    exit 0 ;;
  echostdin)
    printf '{"result":"STDIN_BYTES=%s"}\n' "$stdin_bytes"
    exit 0 ;;
  garbage)
    printf 'this is not json at all\n'
    exit 0 ;;
  fail)
    echo "fake CLI internal error" >&2
    exit 3 ;;
  notlogged)
    echo "Error: Not logged in. Please run the login command and try again." >&2
    exit 1 ;;
  entitlement)
    echo "Error: your account does not have access to this CLI. Ask your workspace admin to enable it." >&2
    exit 1 ;;
  ratelimited)
    echo "Error: usage limit reached. Please try again later." >&2
    exit 1 ;;
  timeout)
    sleep 30
    printf '%s\n' '{"result":"too late"}'
    exit 0 ;;
  *)
    echo "unknown LOCALAGENT_FAKE_MODE: $mode" >&2
    exit 99 ;;
esac
