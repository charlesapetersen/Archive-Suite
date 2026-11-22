#!/bin/bash
# Fake Local Agent CLI — a deterministic, $0 stand-in for `claude -p --output-format json`, used by
# the LocalAgent tests (scripts/localagent-mechanism-test.swift and the in-app LocalAgentTestDriver).
# Same spirit as the FileRelay stand-in: no network, no key, no cost, no real model.
#
# It drains stdin (the prompt — so the caller's stdin write +
# close completes and the child sees EOF, exactly like a real CLI), and emits a canned response chosen
# by $LOCALAGENT_FAKE_MODE:
#   ok         (default) success JSON; .result is a valid OCRPrompt-format transcription        exit 0
#   echostdin  success JSON whose .result reports how many stdin bytes it received               exit 0
#   envkeys    success JSON whose .result names the API-credential variables it inherited, or NONE    exit 0
#   garbage    non-JSON stdout (tests the client's bad-response handling)                        exit 0
#   fail       generic error on stderr                                                          exit 3
#   notlogged  a "not logged in" error on stderr (client → cli_not_logged_in)                   exit 1
#   entitlement a signed-in-but-not-authorized error (client → cli_entitlement_missing)         exit 1
#   ratelimited a usage-limit error on stderr (client → cli_rate_limited)                        exit 1
#   limitjson  the plan's usage limit as `claude -p --output-format json` reports it: an is_error envelope on stdout,
#              "You've hit your limit · resets in 2s", nothing on stderr (W41.app-claude-plan-reading)  exit 1
#   limitthenok  the epoch form "Claude AI usage limit reached|<now+1>" for the first $LOCALAGENT_FAKE_LIMITS calls
#              (default 2, counted in $LOCALAGENT_FAKE_COUNT_DIR/calls), then `ok`                exit 1, then 0
#   iserror0   an is_error envelope with exit 0 and a reason that is no limit ("…while generating…")   exit 0
#   timeout    sleeps well past any test timeout (tests the client's SIGTERM/SIGKILL path)      exit 0
#              (with $LOCALAGENT_FAKE_PID_DIR set, it writes its pid there and execs the sleep, so a test
#              can check the child itself is gone after a cancel)
#   readmeter  a streamed page result with 89%, then 90%, then 0%, using the reset set by the test.
#              Requires the real stream flags. Each invocation creates a PID marker in the count dir.
#   stream     `--output-format stream-json --verbose` for a segmentation window: a rate_limit_event, then a
#              result event whose .result answers every page-NNNN.jpg in the working directory (W36)  exit 0
#              The five-hour and weekly meters are whole percents kept in $LOCALAGENT_FAKE_METER_DIR
#              (files `five`, `week`): each call prints them, then adds $LOCALAGENT_FAKE_FIVE_STEP (default 1)
#              and $LOCALAGENT_FAKE_WEEK_STEP (default 0). Each call costs $LOCALAGENT_FAKE_COST notional
#              dollars (default 0.25). Not safe for concurrent calls (the tests run these one at a time).
#   streamnometer  the same with no rate_limit_event (an older CLI, or an API-key login)          exit 0
mode="${LOCALAGENT_FAKE_MODE:-ok}"

if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
    case "${LOCALAGENT_FAKE_BILLING:-plan}" in
        key) printf '%s\n' '{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"/login managed key"}' ;;
        unknown) printf '%s\n' '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'; exit 1 ;;
        *) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}' ;;
    esac
    exit 0
fi

# Always drain stdin first so the process exits cleanly on EOF and reports the prompt size.
stdin_bytes=$(wc -c | tr -d ' ')

case "$mode" in
  ok)
    printf '%s\n' '{"result":"[document_start]\n[rotate_0]\nFAKE-CLI-OCR-TOKEN transcribed body line one\nbody line two","total_cost_usd":0,"num_turns":3,"is_error":false}'
    exit 0 ;;
  paid)
    printf '%s\n' '{"type":"system","subtype":"init","apiKeySource":"/login managed key"}' \
        '{"type":"result","subtype":"success","result":"[document_start]\n[rotate_0]\nPAID FIXTURE","total_cost_usd":0.0425}'
    exit 0 ;;
  echostdin)
    printf '{"result":"STDIN_BYTES=%s"}\n' "$stdin_bytes"
    exit 0 ;;
  envkeys)
    keys=""
    for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
        if [ -n "${!v+set}" ]; then keys="$keys${keys:+,}$v"; fi
    done
    printf '{"result":"ENV_KEYS=%s"}\n' "${keys:-NONE}"
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
  limitjson)
    printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your limit · resets in 2s","total_cost_usd":0}'
    exit 1 ;;
  limitthenok)
    count_file="${LOCALAGENT_FAKE_COUNT_DIR:?}/calls"
    n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$count_file"
    if [ "$n" -le "${LOCALAGENT_FAKE_LIMITS:-2}" ]; then
        printf '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|%s"}\n' "$(( $(date +%s) + 1 ))"
        exit 1
    fi
    printf '%s\n' '{"result":"[document_start]\n[rotate_0]\nFAKE-CLI-OCR-TOKEN read after the window reset","total_cost_usd":0,"is_error":false}'
    exit 0 ;;
  iserror0)
    printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"An internal error occurred while generating the answer"}'
    exit 0 ;;
  timeout)
    if [ -n "${LOCALAGENT_FAKE_PID_DIR:-}" ]; then
        echo $$ > "$LOCALAGENT_FAKE_PID_DIR/$$"
        exec sleep 30
    fi
    sleep 30
    printf '%s\n' '{"result":"too late"}'
    exit 0 ;;
  readmeter)
    case " $* " in
      *" --output-format stream-json --verbose "*) ;;
      *) echo "expected stream-json and verbose" >&2; exit 3 ;;
    esac
    dir="${LOCALAGENT_FAKE_COUNT_DIR:?}"
    touch "$dir/$$"
    n=$(find "$dir" -type f | wc -l)
    case "$((n))" in
      1) five=0.89 ;;
      2) five=0.90 ;;
      *) five=0 ;;
    esac
    printf '%s\n' '{"type":"system","subtype":"init"}'
    printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s}}}}\n' \
        "$five" "${LOCALAGENT_FAKE_RESET:?}"
    printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.5}}}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"not the final result"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"[document_start]\n[rotate_0]\nFAKE-CLI-OCR-TOKEN"}'
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
