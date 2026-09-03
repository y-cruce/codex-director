把下面这段加到 `~/.claude/CLAUDE.md`（对所有项目生效）或某个项目的 `CLAUDE.md` 末尾。技能只在被触发时加载，路由规则必须写在 CLAUDE.md 里才能保证每次都走这条路。

```markdown
## Codex 当执行者

装了 Codex 插件，它的额度不设限。凡是要读代码理解现状、排查 bug、写实现、做 review 的任务，先加载 `codex-director` 技能，按它的流程把活派给 `codex-worker`，自己只写任务书、判结果、做取舍。派 codex-worker 时 `model` 写 `opus`。
```
