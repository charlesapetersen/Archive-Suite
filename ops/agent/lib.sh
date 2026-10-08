# ops/agent/lib.sh — sourced by every Agent Manager hook in this directory (CONTRACT.md in the Agent Manager repo).
#
# The hooks are thin adapters over the project's own scripts in ops/autonomous/. The scripts are found beside
# the hook (this checkout); the data the hooks read comes from $AGENT_REPO, the checkout the manager names in
# its registry. The two differ while a hook is tested from a worktree: the plan
# (.maintenance/AUTONOMOUS_PLAN.md) is gitignored and lives only in the primary checkout, so AGENT_REPO must
# point there for a hook to see it.
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$AGENT_DIR/../autonomous" && pwd)"
REPO="${AGENT_REPO:-$(cd "$AGENT_DIR/../.." && pwd)}"
STATE="${AGENT_STATE:-$HOME/.local/state/archive-autonomous}"
PLAN="${AUTONOMOUS_PLAN:-$REPO/.maintenance/AUTONOMOUS_PLAN.md}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
