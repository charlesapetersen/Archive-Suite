#!/usr/bin/env bash
# prove-heavy-unlocked.sh — lock the unlocked-heavy-run hook (.claude/hooks/heavy-unlocked.sh).
#
# Feeds the hook real PreToolUse payloads and asserts exit 2 (DENY) / exit 0 (ALLOW): the run that preceded the
# 2026-10-31 panic is refused, the same run under heavy-run.py or run-guarded.sh passes, reading about the tools
# is untouched, and an interactive session is never checked.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../../../.claude/hooks/heavy-unlocked.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

# t <label> <allow|deny> <command> [unattended=1]
t() {
  local label="$1" want="$2" cmd="$3" un="${4:-1}" payload got rc
  payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd")
  printf '%s' "$payload" | ARCHIVE_UNATTENDED="$un" bash "$HOOK" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && got=deny || got=allow
  [ "$got" = "$want" ] && ok "$label -> $got" || no "$label -> $got (want $want)"
}

K=~/Library/Caches/ArchiveSuiteRehearsal/kraken-venv/bin/kraken
L=~/Library/Caches/ArchiveSuiteRehearsal/layout-order/bin/layout-order

echo "== 1. unlocked runs (unattended) =="
t "kraken blla, background &"   deny "cd /tmp && nohup $K -I 'L1/*.jpg' -o .xml segment -bl > zero-blla.log 2>&1 &"
t "kraken by bare name"         deny "kraken -i a.jpg a.xml segment -bl"
t "layout-order through xargs"  deny "tr '\n' '\0' < args.txt | xargs -0 $L lines > vision.log 2>&1"
t "layout-order after cd &&"    deny "cd \$W && time $L lines p1.jpg"
t "ketos train"                 deny "env OMP_NUM_THREADS=4 ketos train -f page *.xml"
t "python -m mlx_vlm"           deny "HF_HUB_OFFLINE=1 python3 -m mlx_vlm.generate --model x --image p.jpg"
t "python -m kraken"            deny "/x/kraken-venv/bin/python -m kraken -i a b segment"
t "nice -n 10"                  deny "nice -n 10 kraken -i a b"
t "timeout 3600"                deny "timeout 3600 kraken -i a b"
t "for loop body"               deny "for f in *.png; do kraken -i \$f o; done"
t "if body"                     deny "if true; then $L lines a.jpg; fi"
t "brace group"                 deny "{ kraken -i a b; }"
t "bash -c"                     deny "bash -c 'kraken -i a b'"
t "a mention does not exempt"   deny "echo heavy-run.py; kraken -i a b"
t "second line of a script"     deny "cd /tmp
kraken -i a b segment"

echo "== 2. the same runs under the lock, and reading about them (unattended) =="
t "kraken under heavy-run.py"   allow "python3 ops/autonomous/heavy-run.py run -- $K -i a.jpg a.xml segment -bl"
t "pipeline under heavy-run.py" allow "python3 ops/autonomous/heavy-run.py run -- bash -c 'xargs -0 $L lines < a'"
t "cd && kraken under heavy-run" allow "python3 ops/autonomous/heavy-run.py run -- bash -c 'cd \$W && $K -i a.jpg a.xml segment -bl'"
t "mlx_vlm under heavy-run.py"  allow "python3 ops/autonomous/heavy-run.py run -- python3 -m mlx_vlm.generate --model x"
t "run-guarded.sh"            allow "/Users/cp1/Claude/vision-ocr/ops/ocrlab/run-guarded.sh --label x --need-gb 8 -- python3 -m mlx_vlm.generate"
t "grep for kraken"             allow "grep -n kraken ArchiveProcessor/scripts/segbench/corpus/loop_kraken.py"
t "tail the blla log"           allow "tail -2 \$W/zero-blla.log; ls \$W/vision | wc -l"
t "pip show kraken"             allow "$HOME/venv/bin/pip show kraken"
t "segbench script"             allow "python3 ocr_ppocrv6_hands.py hand-fetch"
t "xcodebuild"                  allow "xcodebuild test -only-testing:ArchiveReaderTests -scheme ArchiveReader"
t "commit message ; kraken"     allow "git commit -m \"note; kraken bar\""
t "commit message & kraken"     allow "git commit -m \"fix a & kraken blla\""
t "heredoc body"                allow "cat <<EOF > notes.md
x
kraken -i a b
EOF"
t "xargs grep kraken"           allow "ls | xargs grep kraken"
t "xargs -I {} grep"            allow "ls | xargs -I {} grep -l layout-order {}"
t "pip show mlx_vlm"            allow "python3 -m pip show mlx_vlm"
t "file named mlx_vlm"          allow "python3 x.py mlx_vlm_notes.txt"
t "which kraken"                allow "which kraken"
t "garbage payload"             allow "'unbalanced"

echo "== 3. interactive session =="
t "kraken, interactive"         allow "kraken -i a.jpg a.xml segment -bl" 0

echo; echo "PASS $PASS  FAIL $FAIL"
[ "$FAIL" -eq 0 ]
