#!/usr/bin/env bash
# make-gui-fixture.sh — make the Processor VM lane's disposable IN/OUT launch root.
#
# No corpus, credentials, or supplied PDF is needed: Process Files starts on its empty drop zone, and the
# UITest bundle generates its own two-page PDF under a unique temporary directory. This fixture exists for
# the sighted launch path, where the app still needs a deterministic scratch output folder.
set -euo pipefail

dst="${AP_GUI_FIXTURE_DST:-$HOME/ArchiveProcessor-GUI-Fixture}"
case "$dst" in
  "$HOME"/ArchiveProcessor-GUI-Fixture) ;;
  *) printf 'Refusing noncanonical Processor GUI fixture path: %s\n' "$dst" >&2; exit 2 ;;
esac

# Build complete IN/OUT state atomically in a fresh guest `mktemp` directory. `mv` is a same-volume rename;
# the only removal is the previous, known scratch root after its replacement is known good.
tmp="$(mktemp -d "$HOME/ArchiveProcessor-GUI-Fixture.XXXXXX")"
mkdir -p "$tmp/IN" "$tmp/OUT"
printf '%s\n' 'Archive Processor GUI scratch fixture — safe to replace.' > "$tmp/README.txt"
if [ -e "$dst" ]; then rm -rf "$dst"; fi
mv "$tmp" "$dst"
printf 'Processor GUI fixture ready: %s (IN=%s OUT=%s)\n' "$dst" "$dst/IN" "$dst/OUT"
