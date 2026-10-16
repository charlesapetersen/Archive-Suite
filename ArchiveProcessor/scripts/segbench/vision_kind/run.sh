#!/bin/bash
# W41.bench-vision-kind: build vision-page-kind against vision-ocr's Sources/ (read, never edited) and run it.
#   run.sh build                 # -> $BIN (default /tmp/vision-page-kind), prints the vision-ocr commit it was built at
#   run.sh <list.tsv> > out.tsv  # build if needed, then one row a page
# VISION_OCR (default ~/Claude/vision-ocr) is the checkout; a dirty one is refused, so a row always names a commit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vo="${VISION_OCR:-$HOME/Claude/vision-ocr}"
bin="${BIN:-/tmp/vision-page-kind}"
[ -z "$(git -C "$vo" status --porcelain -- Sources)" ] || { echo "vision-ocr Sources/ has uncommitted changes" >&2; exit 2; }
commit="$(git -C "$vo" rev-parse --short HEAD)"
if [ ! -x "$bin" ] || [ "$(cat "$bin.commit" 2>/dev/null)" != "$commit" ] || [ "$here/vision-page-kind.swift" -nt "$bin" ]; then
  work="$(mktemp -d)"
  cp "$here/vision-page-kind.swift" "$work/main.swift"
  # shellcheck disable=SC2046  # the README's recipe: every source but App.swift (its @main)
  swiftc -O -o "$bin" -target "$(uname -m)-apple-macos13.0" $(ls "$vo"/Sources/*.swift | grep -v App.swift) "$work/main.swift"
  echo "$commit" > "$bin.commit"
  rm -rf "$work"
fi
echo "vision-ocr $commit" >&2
[ "${1:-}" = build ] && exit 0
exec "$bin" "$@"
