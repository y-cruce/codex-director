#!/usr/bin/env bash
# Copies the agent and the skill into ~/.claude/, then prints the snippet that must be added to CLAUDE.md by hand.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${CLAUDE_HOME:-$HOME/.claude}"

mkdir -p "$DEST/agents" "$DEST/skills/codex-director/scripts"
cp "$HERE/agents/codex-worker.md" "$DEST/agents/codex-worker.md"
cp "$HERE/skills/codex-director/SKILL.md" "$DEST/skills/codex-director/SKILL.md"
cp "$HERE/skills/codex-director/scripts/codex-worker.sh" "$DEST/skills/codex-director/scripts/codex-worker.sh"
chmod +x "$DEST/skills/codex-director/scripts/codex-worker.sh"

echo "Installed:"
echo "  $DEST/agents/codex-worker.md"
echo "  $DEST/skills/codex-director/SKILL.md"
echo "  $DEST/skills/codex-director/scripts/codex-worker.sh"
echo
echo "One step left: append the snippet in docs/claude-md-snippet.md to $DEST/CLAUDE.md."
echo "Then run /reload-plugins in Claude Code, or start a new session."
