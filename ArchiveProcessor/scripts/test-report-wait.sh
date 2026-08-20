#!/bin/bash
# Shared bounded wait for headless Processor test drivers that emit a final report only at completion.
# Source this after starting the app. The driver's `NSLog("PREFIX PASS|FAIL: …")` lines are its durable
# progress signal: they let a timeout say whether it was a crash, a slow machine, or a late test failure.

wait_for_test_report() {
    local report_path="$1"
    local log_path="$2"
    local pid="$3"
    local test_name="$4"
    local progress_prefix="$5"
    local timeout_seconds="${6:-180}"
    local started="$SECONDS"

    if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
        echo "${test_name} test has an invalid timeout: ${timeout_seconds}" >&2
        return 2
    fi

    while true; do
        [ -f "$report_path" ] && return 0

        local elapsed=$((SECONDS - started))
        local progress
        progress="$(awk -v prefix="$progress_prefix" '
            index($0, prefix " PASS: ") || index($0, prefix " FAIL: ") {
                checks += 1
                last = $0
            }
            END {
                if (checks) {
                    printf "%d\t%s\n", checks, last
                } else {
                    print "0\t(no completed check logged)"
                }
            }
        ' "$log_path")"
        local checks_completed="${progress%%$'\t'*}"
        local last_check="${progress#*$'\t'}"

        if ! kill -0 "$pid" 2>/dev/null; then
            echo "${test_name} test exited before writing its report after ${elapsed}s; ${checks_completed} checks completed; last check seen: ${last_check}" >&2
            tail -40 "$log_path" >&2
            return 1
        fi

        if (( elapsed >= timeout_seconds )); then
            echo "${test_name} test timed out after ${elapsed}s; ${checks_completed} checks completed; last check seen: ${last_check}" >&2
            tail -40 "$log_path" >&2
            return 1
        fi

        sleep 1
    done
}
