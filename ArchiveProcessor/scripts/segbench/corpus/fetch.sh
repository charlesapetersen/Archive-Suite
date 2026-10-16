#!/bin/bash
# fetch.sh — the one network route for W43.corpus-build.
#
#   fetch.sh URL DEST       download URL to DEST (a path relative to the cache folder)
#   fetch.sh --head URL     print the response headers only
#   fetch.sh --stdout URL   print the body (for API JSON; capped at 20 MB)
#
# The owner allowed the corpus fetch to these hosts only (2026-10-16 walkthrough, gate
# W43.corpus-build-net-owner-ok, option (a)). The script refuses any other host, on the first
# URL and on every redirect (curl's redirects are followed one at a time here, so a redirect to
# an unlisted host stops the fetch). It writes only under the cache folder below, never the
# real corpus and never the repo. A typed curl is denied to every project; run this instead.
set -euo pipefail

CACHE="${BENCH_CORPUS_CACHE:-$HOME/Library/Caches/ArchiveSuiteRehearsal/bench-corpus}"
ALLOWED="zenodo.org huggingface.co github.com raw.githubusercontent.com loc.gov crowd.loc.gov tile.loc.gov transcription.si.edu orda.shef.ac.uk"
MAX_REDIRECTS=10

die() { echo "fetch.sh: $*" >&2; exit 2; }

host_of() {
  local u="$1"
  case "$u" in https://*) ;; *) return 1 ;; esac
  u="${u#https://}"; u="${u%%/*}"; u="${u%%\?*}"; u="${u%%#*}"
  case "$u" in *@*|*:*) return 1 ;; esac   # no userinfo, no explicit port
  printf '%s' "$u" | tr 'A-Z' 'a-z'
}

check_host() {
  local h
  h="$(host_of "$1")" || die "refused (https only, no port or userinfo): $1"
  for a in $ALLOWED; do [ "$h" = "$a" ] && return 0; done
  die "refused host '$h' (allowed: $ALLOWED)"
}

# Resolve redirects one hop at a time, checking every hop's host; print the final URL.
resolve() {
  local url="$1" i loc
  for ((i = 0; i <= MAX_REDIRECTS; i++)); do
    check_host "$url"
    loc="$(curl -sS -o /dev/null -I -w '%{redirect_url}' --max-time 60 "$url")" || die "HEAD failed: $url"
    if [ -z "$loc" ]; then
      # Some servers refuse HEAD; a ranged GET answers the same question.
      loc="$(curl -sS -o /dev/null -r 0-0 -w '%{redirect_url}' --max-time 60 "$url")" || die "GET failed: $url"
    fi
    [ -z "$loc" ] && { printf '%s' "$url"; return 0; }
    url="$loc"
  done
  die "too many redirects"
}

case "${1:-}" in
  --head)
    [ $# -eq 2 ] || die "usage: fetch.sh --head URL"
    final="$(resolve "$2")"
    curl -sS -I --max-time 60 --max-redirs 0 "$final"
    ;;
  --stdout)
    [ $# -eq 2 ] || die "usage: fetch.sh --stdout URL"
    final="$(resolve "$2")"
    curl -sS --fail --max-time 300 --max-redirs 0 --max-filesize 20000000 "$final"
    ;;
  ""|-h|--help)
    sed -n '2,13p' "$0"; exit 0 ;;
  *)
    [ $# -eq 2 ] || die "usage: fetch.sh URL DEST"
    url="$1"; dest="$2"
    case "$dest" in /*|*..*) die "DEST must be relative to the cache, with no '..': $dest" ;; esac
    out="$CACHE/$dest"
    mkdir -p "$(dirname "$out")"
    final="$(resolve "$url")"
    curl -sS --fail --retry 3 --max-time 3600 --max-redirs 0 -o "$out.part" "$final"
    mv "$out.part" "$out"
    echo "$out"
    ;;
esac
