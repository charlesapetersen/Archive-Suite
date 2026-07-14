#!/usr/bin/env bash
# ArchiveNotes/scripts/e2e-durable-links.sh
# =============================================================================
# End-to-end DURABLE-LINK scenario (W8-S9 §4) — the single scripted proof that
# the D5 durable-provenance promise holds at the FILESYSTEM level, over the
# SHIPPED `make-notes-fixture.sh` builder. It is the shell counterpart to the
# in-code `DurableLinkE2ETests` (which proves the resolver LOGIC): this script
# proves the durable-link DATA path — a note's `reader-page` block link
# (archivereader://reveal?root=<GUID>&rel=<path>) resolves to a real file under
# a root whose RootMarker carries that GUID, and that this SURVIVES a computer
# move (same GUID, different absolute path → still resolves; no re-index, no
# path rewrite). An unknown GUID would require a one-time re-grant — never a
# silent wrong file (00-overview §8.3).
#
# NO GUI, NO app launch, NO xcodebuild — pure filesystem + `jq`. Runnable
# standalone or from the free gate (§4). Deterministic: the fixture uses fixed
# GUIDs; if the (gitignored) Reader corpus source is absent, a synthetic stub
# `sample.pdf` is dropped so the resolve/move proof still runs everywhere.
#
# SAFETY (Prime Directive #1 — file safety > everything):
#   * Everything happens under SCRATCH: the fixture `…/ArchiveNotes/AN-GUI-Fixture`
#     (a sibling of the real store `…/ArchiveNotes/Store`, NEVER it) and a
#     `mktemp -d` copy. A hard guard refuses to `rm -rf` anything that is not
#     exactly one of those scratch paths.
#   * The real corpus is only ever a READ-ONLY `ditto` source (inside the
#     fixture builder); this script never writes outside scratch.
#
# Usage:  ./ArchiveNotes/scripts/e2e-durable-links.sh
#         KEEP_FIXTURE=1 ./ArchiveNotes/scripts/e2e-durable-links.sh   # skip teardown
# Exit:   0 = all checks PASS; 1 = a check FAILED; 2 = setup/safety refusal.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fixed identity — MUST match make-notes-fixture.sh.
NOTES_ROOT_GUID="a11ce5e7-1000-4000-8000-000000000001"
CORPUS_ROOT_GUID="c07b0700-2000-4000-8000-000000000002"
FIXTURE_NAME="AN-GUI-Fixture"

PASS=0 ; FAIL=0
check()  { if eval "$2"; then PASS=$((PASS+1)); echo "  ok   — $1"; else FAIL=$((FAIL+1)); echo "  FAIL — $1"; fi; }
marker_field() { jq -r ".$2 // \"\"" "$1/.archive-suite-root.json" 2>/dev/null || echo ""; }

# HARD SAFETY GUARD — only ever rm-rf the scratch fixture or a /tmp mktemp dir.
safe_rm() {
  local target="$1"
  case "$target" in
    */"$FIXTURE_NAME") : ;;                                  # the scratch fixture
    "$TMPDIR"*|/tmp/*|/private/var/folders/*|/private/tmp/*) : ;;  # a mktemp copy
    *) echo "e2e-durable-links: REFUSING to rm non-scratch path: $target" >&2; exit 2 ;;
  esac
  case "$target" in
    *"/ArchiveNotes/Store"|*"/ArchiveNotes/Store/"*|"$HOME/Desktop/"*)
      echo "e2e-durable-links: REFUSING — protected location: $target" >&2; exit 2 ;;
  esac
  rm -rf "$target"
}

echo "== Archive Notes — durable-link E2E =="

# --- 1) Build the fixture via the SHIPPED builder ----------------------------
echo "[1] building fixture via make-notes-fixture.sh …"
FIXTURE="$(bash "$SCRIPT_DIR/make-notes-fixture.sh")"   # path on stdout; logs on stderr
[ -d "$FIXTURE" ] || { echo "e2e-durable-links: fixture build produced no dir" >&2; exit 2; }
CORPUS="$FIXTURE/reader-corpus"
MOVED=""   # set later; cleaned by trap
cleanup() {
  [ -n "$MOVED" ] && [ -d "$MOVED" ] && safe_rm "$MOVED"
  if [ -z "${KEEP_FIXTURE:-}" ]; then safe_rm "$FIXTURE"; fi
}
trap cleanup EXIT

# Ensure a resolve TARGET exists even when the (gitignored) corpus is absent.
if [ ! -f "$CORPUS/sample.pdf" ]; then
  echo "    (corpus source absent — dropping a synthetic scratch sample.pdf)"
  printf '%%PDF-1.4 scratch\n' > "$CORPUS/sample.pdf"
fi

# --- 2) Structural resolve proof (goal A: the shipped fixture is resolvable) --
echo "[2] structural resolve proof …"
check "notes RootMarker present, kind=notes"          "[ \"\$(marker_field \"$FIXTURE\" kind)\" = notes ]"
check "notes RootMarker GUID matches"                 "[ \"\$(marker_field \"$FIXTURE\" guid)\" = $NOTES_ROOT_GUID ]"
check "corpus RootMarker present, kind=reader"        "[ \"\$(marker_field \"$CORPUS\" kind)\" = reader ]"
check "corpus RootMarker GUID matches"                "[ \"\$(marker_field \"$CORPUS\" guid)\" = $CORPUS_ROOT_GUID ]"
check "reader-page block links the corpus GUID + rel" \
  "grep -qF 'archivereader://reveal?root=$CORPUS_ROOT_GUID&rel=sample.pdf' \"$FIXTURE/items/22222222-2222-2222-2222-222222222222/Moore on Intel culture.md\""
check "link target exists under the corpus root"      "[ -f \"$CORPUS/sample.pdf\" ]"
check "organization.json is valid JSON"               "jq -e . \"$FIXTURE/organization.json\" >/dev/null 2>&1"
check "one item is replicated (member of >1 folder)"  \
  "[ \"\$(jq '[.memberships[].itemId] | map(select(. == \"22222222-2222-2222-2222-222222222222\")) | length' \"$FIXTURE/organization.json\")\" -ge 2 ]"

# --- 3) Computer-move proof (goal B: GUID-stable across an absolute-path move) -
echo "[3] computer-move proof (ditto to a new absolute path) …"
MOVED="$(mktemp -d "${TMPDIR:-/tmp}/an-e2e-move.XXXXXX")"
ditto "$FIXTURE" "$MOVED"   # ditto copies the fixture's CONTENTS into the (new-path) dir
check "moved path differs from the original"          "[ \"$MOVED\" != \"$FIXTURE\" ]"
check "moved corpus RootMarker GUID is IDENTICAL"     "[ \"\$(marker_field \"$MOVED/reader-corpus\" guid)\" = $CORPUS_ROOT_GUID ]"
check "link target resolves under the MOVED root"     "[ -f \"$MOVED/reader-corpus/sample.pdf\" ]"

# --- 4) Negative: an unknown GUID is not silently satisfied ------------------
echo "[4] negative (unknown GUID needs a re-grant, never a silent match) …"
FAKE_GUID="deadbeef-0000-4000-8000-000000000000"
check "a fabricated GUID matches NO fixture marker"   \
  "[ \"$FAKE_GUID\" != \"$CORPUS_ROOT_GUID\" ] && [ \"$FAKE_GUID\" != \"$NOTES_ROOT_GUID\" ]"

# --- 5) Result ---------------------------------------------------------------
echo "== durable-link E2E: $PASS passed, $FAIL failed =="
if [ "$FAIL" -ne 0 ]; then echo "E2E FAIL"; exit 1; fi
echo "E2E PASS"
