Append the block below to `~/.claude/CLAUDE.md` (applies to all projects) or to a project's `CLAUDE.md`. Skills load only when triggered, so the routing rule must live in `CLAUDE.md` to guarantee every matching task takes this path.

```markdown
## Codex as the executor

The Codex plugin is installed and its quota is effectively unlimited. For any task that involves reading code to understand current behavior, debugging, implementing a change, or reviewing a diff, load the `codex-director` skill first and follow its process to dispatch the work to `codex-worker`. Do only the brief writing, result judging, and decision making yourself. When dispatching codex-worker, set `model` to `opus`.
```
