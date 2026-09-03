#!/usr/bin/env bash
# 把 agent 和 skill 复制到 ~/.claude/，然后打印需要手动加进 CLAUDE.md 的片段。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${CLAUDE_HOME:-$HOME/.claude}"

mkdir -p "$DEST/agents" "$DEST/skills/codex-director"
cp "$HERE/agents/codex-worker.md" "$DEST/agents/codex-worker.md"
cp "$HERE/skills/codex-director/SKILL.md" "$DEST/skills/codex-director/SKILL.md"

echo "已安装："
echo "  $DEST/agents/codex-worker.md"
echo "  $DEST/skills/codex-director/SKILL.md"
echo
echo "还差一步：把 docs/claude-md-snippet.md 里的片段加到 $DEST/CLAUDE.md 末尾。"
echo "然后在 Claude Code 里执行 /reload-plugins，或重开会话。"
