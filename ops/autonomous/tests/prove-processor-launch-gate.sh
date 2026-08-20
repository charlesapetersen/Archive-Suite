#!/usr/bin/env bash
# prove-processor-launch-gate.sh — W28.cert-fu3 proof that the free Processor gate runs its new artifact.
# A build can succeed while the signed app aborts before main. This invokes the real recovery harness with a
# scratch executable that does exactly that, then checks the harness fails as a launch failure — no app,
# OCR, network, GUI, or real corpus involved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GATE="$ROOT/ops/autonomous/health-gate.sh"
RECOVERY="$ROOT/ArchiveProcessor/scripts/test-recovery.sh"
[ -f "$GATE" ] && [ -x "$RECOVERY" ] || { echo "FATAL: gate or recovery harness missing" >&2; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

echo "== Processor launch gate =="

launch_lines="$(grep -c '^step processor-launch ' "$GATE" || true)"
if [ "$launch_lines" = 1 ]; then
    ok "health gate has exactly one processor-launch step"
else
    no "expected one processor-launch step, found $launch_lines"
fi

launch_line="$(grep '^step processor-launch ' "$GATE" || true)"
case "$launch_line" in
    *'ARCHIVEPROC_TEST_BINARY="$PWD/macOS/build/gate-DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"'*)
        ok "launch step uses the just-built gate-DD artifact" ;;
    *) no "launch step does not inject the gate-DD app binary: $launch_line" ;;
esac
case "$launch_line" in
    *'test-recovery.sh'*) ok "launch step invokes the scratch-only recovery harness" ;;
    *) no "launch step does not invoke test-recovery.sh" ;;
esac

build_number="$(grep -n '^step processor-build ' "$GATE" | cut -d: -f1)"
launch_number="$(grep -n '^step processor-launch ' "$GATE" | cut -d: -f1)"
if [ -n "$build_number" ] && [ -n "$launch_number" ] && [ "$build_number" -lt "$launch_number" ]; then
    ok "build step precedes the launch of its artifact"
else
    no "processor-launch is not after processor-build"
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
aborter="$T/abort-before-main"
printf '%s\n' '#!/usr/bin/env bash' 'echo PREMAIN-ABORT-SENTINEL >&2' 'exit 17' > "$aborter"
chmod +x "$aborter"

set +e
ARCHIVEPROC_TEST_BINARY="$aborter" "$RECOVERY" > "$T/output" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    ok "a pre-main abort makes the real recovery harness fail"
else
    no "a pre-main abort was accepted by the recovery harness"
fi
if grep -Eq 'Recovery data-safety test exited before writing its report after [0-9]+s; 0 checks completed; last check seen: \(no completed check logged\)' "$T/output"; then
    ok "the failure is diagnosed as an early exit before main"
else
    no "early-exit diagnostic missing: $(head -1 "$T/output")"
fi
if grep -q 'PREMAIN-ABORT-SENTINEL' "$T/output"; then
    ok "the injected binary, not a stale build/DD binary, was executed"
else
    no "the injected pre-main-abort binary was not observed"
fi
if grep -q '^ALL PASS$' "$T/output"; then
    no "the aborting binary produced an ALL PASS verdict"
else
    ok "no false PASS verdict is emitted after a pre-main abort"
fi

echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" -eq 0 ]
