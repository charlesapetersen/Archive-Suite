#!/usr/bin/env bash
# dead-code-scan.sh — Periphery dead-code scan of the three macOS apps and ArchiveCore (W40.e5).
#
# USAGE:  ops/verify/dead-code-scan.sh [reader|notes|processor|core ...]   (default: all four)
# ENV:    DEAD_OUT (default /tmp/dead-code-scan), SKIP_BUILD=1 (reuse the index stores of an earlier run)
# NEEDS:  `brew install periphery` (3.8 when this was written).
# EXIT:   0 = every scan ran (hits or not: a hit is triaged by hand, not a failure) · 2 = a build or scan failed
#
# HOW: each app is built once with `build-for-testing` into its own macOS/build/DD, so the index store holds the
# app target AND its unit-test target (Reader, Notes) or its in-app headless drivers (Processor). Periphery then
# reads that store (`--index-store-path`, no second build), so a hit means nothing in the app or its tests
# names it. Two retain flags cut known noise: SwiftUI previews, and Codable properties (a decoded field that is
# never read is part of a format, not dead).
#   core  is scanned from the package root against ALL THREE apps' stores at once, so a hit is an ArchiveCore
#         declaration no app and no app test uses. ArchiveCore's own `swift test` target is not in those stores:
#         grep packages/ArchiveCore/Tests before calling a core hit dead. The same scan also reports app files;
#         only the rows under Sources/ArchiveCore and packages/UITestSupport are kept in core.csv.
# Output: $DEAD_OUT/<app>.csv (Periphery's csv: Kind,Name,…,Location,Hints) and <app>.log.
# Hints worth knowing: `unused`; `assignOnlyProperty` (written, never read); `redundantPublicAccessibility`
# (not dead code — out of scope for W40.e5). An unused `sender`/delegate parameter whose signature AppKit fixes
# is reported too; those are kept.
set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
log() { printf '\033[36m[dead]\033[0m %s\n' "$*"; }
command -v periphery >/dev/null || { echo "periphery not installed: brew install periphery" >&2; exit 2; }

OUT="${DEAD_OUT:-/tmp/dead-code-scan}"
mkdir -p "$OUT"
worst=0
store() { echo "$ROOT/$1/macOS/build/DD/Index.noindex/DataStore"; }

scan_app() {  # $1 = reader | notes | processor
  local key="$1" app
  case "$key" in
    reader) app=ArchiveReader ;; notes) app=ArchiveNotes ;; processor) app=ArchiveProcessor ;;
  esac
  local dir="$ROOT/$app/macOS"
  if [ "${SKIP_BUILD:-0}" != 1 ]; then
    (cd "$dir" && xcodegen generate >/dev/null 2>&1) || { log "$key: xcodegen failed"; worst=2; return; }
    log "$key: xcodebuild build-for-testing…"
    (cd "$dir" && xcodebuild build-for-testing -scheme "$app" -destination 'platform=macOS' \
      -derivedDataPath ./build/DD COMPILER_INDEX_STORE_ENABLE=YES) >"$OUT/$key-build.log" 2>&1 \
      || { log "$key: build failed — $OUT/$key-build.log"; worst=2; return; }
  fi
  (cd "$dir" && periphery scan --project "$app.xcodeproj" --schemes "$app" --skip-build \
    --index-store-path "$(store "$app")" --retain-swift-ui-previews --retain-codable-properties \
    --relative-results --format csv) >"$OUT/$key.csv" 2>"$OUT/$key.log" \
    || { log "$key: periphery failed — $OUT/$key.log"; worst=2; return; }
  log "$key: $(($(wc -l <"$OUT/$key.csv") - 1)) hit(s) — $OUT/$key.csv"
}

scan_core() {
  local a args=()
  for a in ArchiveReader ArchiveNotes ArchiveProcessor; do
    [ -d "$(store "$a")" ] || { log "core: no index store for $a — scan the apps first"; worst=2; return; }
    args+=(--index-store-path "$(store "$a")")
  done
  (cd "$ROOT/packages/ArchiveCore" && periphery scan --skip-build "${args[@]}" --relative-results --format csv) \
    >"$OUT/core-all.csv" 2>"$OUT/core.log" || { log "core: periphery failed — $OUT/core.log"; worst=2; return; }
  { head -1 "$OUT/core-all.csv"; grep -E ',(Sources/ArchiveCore|\.\./UITestSupport)/' "$OUT/core-all.csv"; } >"$OUT/core.csv"
  log "core: $(($(wc -l <"$OUT/core.csv") - 1)) hit(s) — $OUT/core.csv"
}

targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=(reader notes processor core)
for t in "${targets[@]}"; do
  case "$t" in
    reader|notes|processor) scan_app "$t" ;;
    core) scan_core ;;
    *) echo "unknown target: $t" >&2; exit 2 ;;
  esac
done
exit "$worst"
