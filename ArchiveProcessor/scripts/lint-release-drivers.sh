#!/usr/bin/env bash
# lint-release-drivers.sh — every Processor test driver and headless contract compiles into Debug only (W40.a5).
#
# The env-gated `*TestDriver` / `*ProofDriver` / `*Contract` files are dispatched from ContentView inside
# `#if DEBUG`, and every script that runs them builds Debug. A new driver file without the guard would still
# compile into the Release app, unreferenced but shipped, and one of them (SegmentationProofDriver) spends money.
# So each such file must open with `#if DEBUG` and close with `#endif`. W40.a5 proved the result with `nm` on a
# Release binary; this keeps it true without a Release build on every gate run.
#
# `--self-test` plants an unguarded driver in a scratch copy and demands the lint fail on it. Health-gate step.
set -uo pipefail

APP_ROOT="${PROCESSOR_LINT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$APP_ROOT/macOS/Sources/ArchiveProcessor"

if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/macOS/Sources" && cp -R "$SRC" "$tmp/macOS/Sources/" || exit 2
  PROCESSOR_LINT_ROOT="$tmp" bash "$0" >/dev/null || { echo "✗ self-test: clean copy does not pass"; exit 1; }
  printf 'enum PlantedTestDriver {}\n' > "$tmp/macOS/Sources/ArchiveProcessor/PlantedTestDriver.swift"
  if PROCESSOR_LINT_ROOT="$tmp" bash "$0" >/dev/null; then echo "✗ self-test: unguarded driver passed"; exit 1; fi
  printf '#if DEBUG\nenum PlantedTestDriver {}\n' > "$tmp/macOS/Sources/ArchiveProcessor/PlantedTestDriver.swift"
  if PROCESSOR_LINT_ROOT="$tmp" bash "$0" >/dev/null; then echo "✗ self-test: unclosed guard passed"; exit 1; fi
  echo "✓ release-driver lint self-test: catches an unguarded and an unclosed driver"; exit 0
fi

[ -d "$SRC" ] || { echo "✗ no Processor sources at $SRC"; exit 2; }
n=0; bad=0
while IFS= read -r -d '' f; do
  n=$((n + 1))
  first="$(head -n1 "$f")"
  last="$(grep -v '^[[:space:]]*$' "$f" | tail -n1)"
  case "$first" in '#if DEBUG'*) ;; *) echo "✗ ${f#"$APP_ROOT"/}: first line is not #if DEBUG"; bad=$((bad + 1)); continue ;; esac
  [ "$last" = "#endif" ] || { echo "✗ ${f#"$APP_ROOT"/}: last line is not #endif"; bad=$((bad + 1)); }
done < <(find "$SRC" -name '*.swift' \( -name '*TestDriver.swift' -o -name '*ProofDriver.swift' -o -name '*Contract.swift' \) -print0)

[ "$n" -gt 0 ] || { echo "✗ found no driver files: the pattern no longer matches anything"; exit 1; }
[ "$bad" -eq 0 ] || { echo "✗ $bad of $n driver/contract files would compile into Release"; exit 1; }
echo "✓ all $n Processor driver/contract files are Debug-only"
