#!/bin/bash
# Owned headless-test children only. Source, then processor_test_init [scratch-dir] [unlock].
# Start with FLAG=value processor_test_start PID_VARIABLE command [args…] (no trailing &). Bash exports
# those temporary assignments to the child; keep keys there, never in an `env KEY=value` argument.
# The captured direct child execs the command after unblocking only TERM, whose blocked
# mask otherwise survives the engine -> shell -> app exec chain. Never signal apps by name or group.

processor_test_init() {
    processor_test_pids=()
    processor_test_scratch="${1:-}"
    processor_test_unlock="${2:-}"
    trap processor_test_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

processor_test_start() {
    local variable="$1"
    shift
    # A signal between spawning and registration must not leave an unrecorded child. Bash defers its
    # trap to a command boundary; remember it until both the owned list and the caller's variable exist.
    local interrupted=0 child_pid
    trap 'interrupted=130' INT
    trap 'interrupted=143' TERM
    python3 -c 'import os, signal, sys; signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM}); os.execvp(sys.argv[1], sys.argv[1:])' "$@" &
    child_pid=$!
    processor_test_pids+=("$child_pid")
    printf -v "$variable" '%s' "$child_pid"
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ "$interrupted" = 0 ] || exit "$interrupted"
}

processor_test_child_state() {
    local child_pid="$1" row parent state
    if ! row="$(ps -p "$child_pid" -o ppid= -o stat= 2>/dev/null)"; then
        # Failure to inspect a live process is never permission to signal it.
        if kill -0 "$child_pid" 2>/dev/null; then return 1; fi
        printf '%s\n' exited
        return 0
    fi
    read -r parent state <<< "$row"
    [ "$parent" = "$$" ] || return 1
    case "$state" in *Z*) printf '%s\n' exited ;; ?*) printf '%s\n' running ;; *) return 1 ;; esac
}

processor_test_stop() {
    local child_pid="$1" index="" i state n
    [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    for i in "${!processor_test_pids[@]}"; do
        [ "${processor_test_pids[$i]}" != "$child_pid" ] || index="$i"
    done
    # An already reaped child is a no-op; an unregistered PID never authorizes a signal.
    [ -n "$index" ] || return 0
    state="$(processor_test_child_state "$child_pid")" || {
        echo "Cannot verify ownership of headless test child $child_pid; not signalling it" >&2
        return 1
    }
    if [ "$state" = running ]; then
        kill -TERM "$child_pid" 2>/dev/null || true
        for ((n=0; n<50; n++)); do
            state="$(processor_test_child_state "$child_pid")" || return 1
            [ "$state" = running ] || break
            sleep 0.1
        done
        if [ "$state" = running ]; then
            state="$(processor_test_child_state "$child_pid")" || return 1
        fi
        if [ "$state" = running ]; then
            echo "Headless test child $child_pid did not stop after TERM; stopping owned child with KILL" >&2
            kill -KILL "$child_pid" 2>/dev/null || true
            for ((n=0; n<50; n++)); do
                state="$(processor_test_child_state "$child_pid")" || return 1
                [ "$state" = running ] || break
                sleep 0.1
            done
        fi
    fi
    [ "$state" = exited ] || { echo "Headless test child $child_pid survived shutdown" >&2; return 1; }
    wait "$child_pid" 2>/dev/null || true
    unset 'processor_test_pids[index]'
}

processor_test_finish() {
    local status=$? child_pid stopped=1
    trap - EXIT
    # Finish cleanup even if a second interrupt arrives during the bounded shutdown.
    trap '' INT TERM
    for child_pid in ${processor_test_pids[@]+"${processor_test_pids[@]}"}; do
        processor_test_stop "$child_pid" || stopped=0
    done
    if [ "$stopped" = 1 ]; then
        if [ -n "$processor_test_scratch" ]; then
            if [ "$processor_test_unlock" = unlock ]; then
                chflags -R nouchg "$processor_test_scratch" 2>/dev/null || true
            fi
            rm -rf "$processor_test_scratch"
        fi
        # Optional caller-owned log redaction / persistent test-state cleanup, after every child stops.
        if declare -F processor_test_after_stop >/dev/null; then processor_test_after_stop; fi
    else
        echo "Headless test cleanup failed; scratch kept at ${processor_test_scratch:-the output directory}" >&2
        [ "$status" != 0 ] || status=1
    fi
    exit "$status"
}
