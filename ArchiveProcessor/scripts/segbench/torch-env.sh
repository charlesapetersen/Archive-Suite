#!/usr/bin/env bash
# torch-env.sh — the one shared PyTorch environment for bench items on the Mac (W40.cache-budget).
#
# Before this, nearly every segbench item built its own venv in the bench cache with its own PyTorch (seven
# copies, 2.12 to 2.15, about 1 GB each, on 29 Oct). New items use this one instead:
#
#   torch-env.sh                 create it if missing; print its python (use as  PY=$(torch-env.sh))
#   torch-env.sh add PKG...      install an item's extra packages into it, holding the base stack where it is
#   torch-env.sh freeze          what is installed
#
# The base stack (BASE below) is what six or seven of the old venvs all held. `add` installs under a lock file
# of the base as it was first built (base.lock), so an item's package can never move torch, torchvision or numpy
# for the items after it. Only the base is pinned: an item's extras can be moved by a later item's, so an item
# that needs an exact version of an extra pins it in its own `add` call. When a package cannot be installed
# against those pins, uv says so and nothing changes: that item then builds its own venv in its own cache folder,
# says why in its item notes, and removes it when the item completes (CLAUDE.md, "The bench cache").
#
# Lives at $ARCHIVE_BENCH_CACHE/torch-env (default ~/Library/Caches/ArchiveSuiteRehearsal/torch-env). Rebuildable:
# delete it and the next call rebuilds the base; extras are re-added by the items that need them. Editing BASE or
# PYVER rebuilds it too (.ready records them). Every call takes a lock, so two sessions cannot build or change it
# at once; a call that waits more than 15 minutes for the lock gives up and says so.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
CACHE="${ARCHIVE_BENCH_CACHE:-$HOME/Library/Caches/ArchiveSuiteRehearsal}"
ENV="$CACHE/torch-env"
PY="$ENV/bin/python"
PYVER=3.12
BASE=(torch==2.15.0 torchvision numpy pillow safetensors huggingface-hub)

mkdir -p "$CACHE"
if [ -z "${TORCH_ENV_LOCKED:-}" ]; then
  rc=0; env TORCH_ENV_LOCKED=1 /usr/bin/lockf -s -t "${TORCH_ENV_LOCK_WAIT:-900}" -k "$CACHE/.torch-env.lock" "$0" "$@" || rc=$?
  [ "$rc" != 75 ] || echo "torch-env: another session held $CACHE/.torch-env.lock past ${TORCH_ENV_LOCK_WAIT:-900} s; try again later" >&2
  exit "$rc"
fi
STAMP="python $PYVER; ${BASE[*]}"

build() {
  [ -f "$ENV/.ready" ] && [ "$(cat "$ENV/.ready")" = "$STAMP" ] && return 0
  # A folder without a matching .ready died part-way or has an older BASE; it is this script's own: rebuilt.
  [ -d "$ENV" ] && rm -rf "$ENV"
  echo "torch-env: building $ENV (python $PYVER, ${BASE[*]})" >&2
  uv venv -q --python "$PYVER" "$ENV" >&2
  uv pip install -q --python "$PY" "${BASE[@]}" >&2
  uv pip freeze --python "$PY" > "$ENV/base.lock"
  printf '%s\n' "$STAMP" > "$ENV/.ready"
}

case "${1:-}" in
  ''|path) build; echo "$PY" ;;
  add)
    shift; [ $# -gt 0 ] || { echo "usage: torch-env.sh add PKG..." >&2; exit 2; }
    build
    uv pip install -q --python "$PY" -c "$ENV/base.lock" "$@" >&2
    echo "$PY" ;;
  freeze) build; uv pip freeze --python "$PY" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
