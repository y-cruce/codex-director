---
name: codex-director
description: A way of working where Codex is the default executor and Claude only directs. Load this skill for any task that involves reading code to understand current behavior, finding the root cause of a bug, implementing a change from requirements, reviewing a diff, or getting a second opinion, and whenever the user says "ask codex", "let codex look", or "use codex". Follow the process to dispatch work to codex-worker; Claude only writes the brief, judges the result, and makes the calls.
---

# Codex director mode

Premise: Codex quota is effectively unlimited. The scarce resource is the Claude main thread's context and output. Therefore:

- **Do not read files to understand code.** To learn "where is X handled" or "why does this happen", write a brief and dispatch it to Codex. Let Codex read and report back.
- **Do not write large implementations yourself.** Specify what is needed, let Codex write it, and review.
- **Dispatching several routes is fine.** Run investigation and implementation in parallel for the same problem, or have Codex propose two approaches and pick one.
- **You do four things only**: talk to the user, break the task down and write briefs, judge Codex's results, and make the calls.

## Dispatching

Use the Agent tool with `subagent_type: "codex-worker"` and set `model` explicitly to `opus` (the forwarder only assembles commands and reads files; it does not need the main thread's model). Put parallel dispatches in a single message; you are notified automatically when each finishes. Do not poll.

A Codex task may run for any length of time. codex-worker runs it in the Bash background with no duration limit; do not re-dispatch or shrink the task because it is taking long. **codex-worker notifies you twice**: the first notification contains only the line `WAITING`, meaning Codex has started and is still running; ignore it and do nothing. The second starts with `STATUS:` and is the result. While waiting, the user can run `/codex:status` to list running and recently finished Codex jobs in this repo with their current phase, or `/codex:status <job-id>` for one job's details.

Prompt format: a few header lines, a blank line, then the brief body.

```
MODE: investigate
EFFORT: xhigh

<brief>
```

### MODE and effort

| Goal | MODE | EFFORT | Notes |
|---|---|---|---|
| Scan the codebase to answer a question, locate entry points | investigate | medium | Fast, sufficient |
| Trace call chains, understand a module | investigate | high | Default |
| Find the root cause of a bug or odd behavior | investigate | xhigh | Slow, but worth it |
| Implement a change or patch from requirements | implement | high | Codex edits the working tree directly |
| Fix review findings, continue previous work | continue | unset | Only writes files with `WRITE: yes` in the header |
| Standard code review | review | unset | Prefer providing `BASE: <ref>`, see below |
| Challenge the approach and assumptions | adversarial-review | unset | Body is the focus text; prefer providing `BASE: <ref>` |

xhigh is slow. Use it only when depth is needed.

### Review modes and untracked files

Without `BASE`, the plugin uses working-tree mode and inlines the content of every untracked file into the prompt. Repos with many untracked files exceed Codex's input limit and the review fails. Two options:

- **Preferred**: commit the change to a branch first and put `BASE: <base branch>` in the header so only the committed diff is compared.
- If committing is not possible, do nothing special. codex-worker counts untracked files and, above 3, automatically falls back to a read-only task that performs the review, adding a NOTE line to its return. In that case **list the changed files in the brief body** so Codex knows what to look at.

### Isolate tasks that write files

Only one `implement` per checkout at a time. To run parallel edits (for example, two approaches by Codex), dispatch the agent with `isolation: "worktree"` so each route edits its own worktree; compare afterwards and merge the one you pick. Read-only tasks need no isolation.

## Brief template

The brief is for Codex, which has none of your conversation context. Write it completely and concretely.

```
## Goal
One sentence describing the finished state.

## Context
Key facts from the user's words; known entry files and related modules; what was tried before and why it failed.

## Constraints
- Things not to touch (config, public interfaces, unrelated files)
- Style: match surrounding code, minimal change, no incidental refactoring
- External systems: state one of "read-only, do not call" or "calling is allowed"

## Acceptance
- What counts as done: which tests must pass, which command must run, which questions must be answered
- Output requirements: conclusion + evidence (file:line) + uncertainties listed separately

## Known files (optional)
path/to/a.py  -- entry point
path/to/b.py  -- suspect
```

## Standard pipeline (code changes)

1. Write the brief. If the requirement is ambiguous, ask the user first; do not let Codex guess.
2. Dispatch two routes in parallel: `implement` to write the change and `investigate` (read-only) to map the affected area. Compare the results and check the implementation against the call sites the investigation found.
3. When the implementation returns, dispatch `adversarial-review` with the intent of the change and your main concerns as the body.
4. For high or medium findings, dispatch `continue` with `WRITE: yes` so Codex fixes them, then review again. At most three rounds; step in yourself if it is still not clean.
5. Wrap up: run the tests or verification command, spot-check one or two `file:line` claims from Codex, then report to the user.

Read-only tasks (questions, investigations): one `investigate` route is enough. If Codex left open questions or unfinished parts, dispatch one `continue` to follow up.

## What not to delegate to Codex

- Requirements that are still undecided and need a trade-off confirmed with the user.
- Operations on live environments (production servers, ssh to remote hosts, changing configuration of running services): Codex can read scripts and propose a plan, but you perform the execution.
- Changes under about ten lines, where writing a brief costs more than making the edit.
- Talking to the user.
- **Writing documents and artifacts (HTML pages, reports, session summaries, READMEs and other human-facing output) is done by you, not Codex.** Dispatch `investigate` first if you need facts or material; write the document yourself. This rule constrains your division of labor only; do not write it into briefs. Codex updating comments, a README, or adding an explanation while coding is its own business; do not add restrictions such as "do not write documentation".

## When the session gets long

When the context is long and early information starts getting lost, run `/codex:transfer` to turn the whole session into a Codex thread, give the user the resulting `codex resume <id>`, and let the user decide whether to continue in Codex or start a new session.

## After receiving a result

The forwarder returns Codex's text verbatim with a single STATUS line prepended.

- Spot-check one or two `file:line` references before trusting them; Codex is also wrong sometimes.
- On `STATUS: failed` or `CODEX_FAILED`: report the most useful log lines to the user. Do not take over and redo the whole task yourself.
- Do not auto-apply every review finding; decide first which ones are real.
