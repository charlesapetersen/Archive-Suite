#!/usr/bin/env bash
# prove-daemon-dispatch.sh — lock daemon.sh's launch-MODE dispatch, esp. the 2026-07-17 default flip to KeepAlive.
# Uses the `--dry-run` flag, which prints the resolved mode and exits BEFORE any install / launchctl / pgrep —
# so this asserts the dispatch deterministically without bootstrapping launchd or touching the real job.
# (The KeepAlive MECHANISM itself is proven separately by prove-keepalive.sh on real launchd.)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$HERE/../daemon.sh"
[ -f "$DAEMON" ] || { echo "FATAL: daemon.sh not found at $DAEMON"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
# mode <args...> -> stdout of `daemon.sh --dry-run <args...>`
mode(){ bash "$DAEMON" --dry-run "$@" 2>&1; }

echo "== daemon.sh dispatch =="

out="$(mode)"          ; case "$out" in *"mode 'keepalive'"*) ok "no-arg default -> keepalive" ;; *) no "no-arg default -> keepalive (got: $out)" ;; esac
out="$(mode start)"    ; case "$out" in *"mode 'keepalive'"*) ok "'start' -> keepalive (the canonical verb)" ;; *) no "'start' (got: $out)" ;; esac
out="$(mode keepalive)"; case "$out" in *"mode 'keepalive'"*) ok "'keepalive' -> keepalive" ;; *) no "'keepalive' (got: $out)" ;; esac
out="$(mode nohup)"    ; case "$out" in *"mode 'nohup'"*)     ok "'nohup' -> nohup (opt-in)" ;; *) no "'nohup' (got: $out)" ;; esac

# a bogus command must fail (nonzero) and name the valid commands incl. nohup — never silently launch
out="$(bash "$DAEMON" bogus 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "bogus command exits nonzero ($rc)" || no "bogus command should exit nonzero"
case "$out" in *"nohup"*) ok "usage lists 'nohup'" ;; *) no "usage should list nohup (got: $out)" ;; esac
case "$out" in *"start"*) ok "usage lists 'start'" ;; *) no "usage should list start (got: $out)" ;; esac

# `arm` was RETIRED on 2026-08-06 (renamed arm.sh -> daemon.sh, verb arm -> start). It must now be REJECTED,
# not silently accepted as an alias: a stale habit that quietly still works is how two spellings survive.
out="$(bash "$DAEMON" arm 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "retired verb 'arm' exits nonzero ($rc)" || no "'arm' should be rejected after the rename"
case "$out" in *"unknown command 'arm'"*) ok "'arm' reported as unknown" ;; *) no "'arm' should be named as unknown (got: $out)" ;; esac

# --dry-run must exit BEFORE the launch step: it self-labels as a dry run and shows NO REAL launch/install
# marker ("installed: daemon", "launched (", "bootstrap"). (Its own text contains the word "launched" in
# "NOTHING installed or launched", so match the real markers specifically, not the bare word.)
out="$(mode)"
case "$out" in
  *"installed: daemon"*|*"launched ("*|*"bootstrap"*)  no "dry-run produced a REAL launch/install side-effect: $out" ;;
  *"--dry-run"*"NOTHING installed or launched"*)       ok "dry-run self-labels + shows no launch side-effect" ;;
  *)                                                   no "dry-run output unexpected: $out" ;;
esac

echo ""
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
