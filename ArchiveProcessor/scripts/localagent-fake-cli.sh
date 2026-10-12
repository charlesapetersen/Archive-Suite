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
#              (with $LOCALAGENT_FAKE_PID_DIR set, it writes its pid there and execs the sleep, so a test
#              can check the child itself is gone after a cancel)
#   stream     `--output-format stream-json --verbose` for a segmentation window: a rate_limit_event, then a
#              result event whose .result answers every page-NNNN.jpg in the working directory (W36)  exit 0
#              The five-hour and weekly meters are whole percents kept in $LOCALAGENT_FAKE_METER_DIR
#              (files `five`, `week`): each call prints them, then adds $LOCALAGENT_FAKE_FIVE_STEP (default 1)
#              and $LOCALAGENT_FAKE_WEEK_STEP (default 0). Each call costs $LOCALAGENT_FAKE_COST notional
#              dollars (default 0.25). Not safe for concurrent calls (the tests run these one at a time).
#   streamnometer  the same with no rate_limit_event (an older CLI, or an API-key login)          exit 0
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
    if [ -n "${LOCALAGENT_FAKE_PID_DIR:-}" ]; then
        echo $$ > "$LOCALAGENT_FAKE_PID_DIR/$$"
        exec sleep 30
    fi
    sleep 30
    printf '%s\n' '{"result":"too late"}'
    exit 0 ;;
  stream|streamnometer)
    nums=$(ls page-*.jpg 2>/dev/null | sed -E 's/^page-0*([0-9]+)\.jpg$/\1/' | sort -n)
    pages=""; gaps=""; prev=""
    for n in $nums; do
        pages="$pages${pages:+,}{\\\"page\\\":$n,\\\"kind\\\":\\\"document\\\"}"
        if [ -n "$prev" ]; then
            gaps="$gaps${gaps:+,}{\\\"between\\\":[$prev,$n],\\\"decision\\\":\\\"continue\\\",\\\"cue\\\":\\\"fake\\\",\\\"confidence\\\":0.9}"
        fi
        prev=$n
    done
    printf '%s\n' '{"type":"system","subtype":"init"}'
    if [ "$mode" = stream ]; then
        dir="${LOCALAGENT_FAKE_METER_DIR:?}"
        five=$(cat "$dir/five" 2>/dev/null || echo 0); week=$(cat "$dir/week" 2>/dev/null || echo 0)
        printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":1791783000},"seven_day":{"utilization":%s,"resetsAt":1791943200}}}}\n' \
            "$(awk -v v="$five" 'BEGIN{printf "%.2f", v/100}')" "$(awk -v v="$week" 'BEGIN{printf "%.2f", v/100}')"
        echo $((five + ${LOCALAGENT_FAKE_FIVE_STEP:-1})) > "$dir/five"
        echo $((week + ${LOCALAGENT_FAKE_WEEK_STEP:-0})) > "$dir/week"
    fi
    printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":%s,"result":"{\\"pages\\":[%s],\\"boundaries\\":[%s]}"}\n' \
        "${LOCALAGENT_FAKE_COST:-0.25}" "$pages" "$gaps"
    exit 0 ;;
  *)
    echo "unknown LOCALAGENT_FAKE_MODE: $mode" >&2
    exit 99 ;;
esac
