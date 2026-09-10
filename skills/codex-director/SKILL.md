---
name: codex-director
description: A way of working where Codex is the default executor and Claude only directs. Load this skill for any task that involves reading code to understand current behavior, finding the root cause of a bug, implementing a change from requirements, reviewing a diff, or getting a second opinion, and whenever the user says "ask codex", "let codex look", or "use codex". Follow the process to dispatch work to codex-worker; Claude only writes the brief, judges the result, and makes the calls.
---

# Codex director mode

Premise: Codex quota is effectively unlimited. The scarce resource is the Claude main thread's context and output. Therefore:

- **Do not read files to understand code.** To learn "where is X handled" or "why does this happen", write a brief and dispatch it to Codex. Let Codex read and report back. (Trivial lookups are the exception; see "What not to delegate".)
- **Do not write large implementations yourself.** Specify what is needed, let Codex write it, and review.
- **Dispatching several routes is fine.** Run investigation and implementation in parallel for the same problem, or have Codex propose two approaches and pick one.
- **You do four things only**: talk to the user, break the task down and write briefs, judge Codex's results, and make the calls.

## Dispatching

All dispatch logic lives in `~/.claude/skills/codex-director/scripts/codex-worker.sh` (which Codex command to run, the director note, sandbox flags, review fallbacks). With the event monitor (below) you call that script directly from one foreground Bash call; no subagent is involved. Each dispatch is one call:

```bash
bash ~/.claude/skills/codex-director/scripts/codex-worker.sh dispatch <<'INPUT'
MODE: investigate
EFFORT: high
CWD: /abs/path/to/repo

<brief>
INPUT
```

It returns within seconds with `STATUS: started`, `JOB: <id>`, `THREAD: <id>` (possibly empty), and sometimes a `NOTE:` line; the monitor reports everything after that. Put parallel dispatches in one message as separate Bash calls. Do not poll.

The `codex-worker` agent (Agent tool, `subagent_type: "codex-worker"`, `model` set explicitly to `opus`) is the fallback for plugins without `events` or sessions without the Monitor tool: it runs the same script and waits in bounded rounds on the main thread's behalf. Do not use it when the monitor is available; that only adds a subagent round trip and a duplicate completion notice per job.

A Codex task may run for any length of time. Do not re-dispatch because it is taking long. `/codex:status` lists jobs and `/codex:status <job-id>` shows pending messages, questions, notifications, and interruption state.

### Waiting: one event monitor per session

Preferred, on plugins whose companion has the `events` subcommand (check once per session: `grep -q 'case "events":' "$(bash ~/.claude/skills/codex-director/scripts/codex-worker.sh companion)"`):

1. Before the first dispatch into a repository, arm one Monitor with `persistent: true` and the command `bash ~/.claude/skills/codex-director/scripts/codex-worker.sh events --cwd <repo>` (description: "Codex job events in <repo>"). One monitor per repository. Note its task id: the monitor is yours to stop.
2. Dispatch with the `dispatch` subcommand shown above. Review modes start detached and return an empty `JOB:`; their job id arrives in the monitor's `DONE` or `FAILED` line.
3. Each line the monitor emits is one event and arrives on its own schedule; it is not user input. Lines: `DONE job=<id> thread=<id>`, `FAILED job=<id> thread=<id> <reason>`, `QUESTION job=<id> request=<id> <first question>`, `NOTIFIED job=<id> thread=<id> <note>`, `STALLED job=<id> thread=<id> <n>m without progress`. On `DONE` run `node "$(bash ~/.claude/skills/codex-director/scripts/codex-worker.sh companion)" result <job-id> --cwd <repo>` in a foreground Bash call and judge the output as usual. On `QUESTION` run `status <job-id> --cwd <repo> --json` on the same companion to read the questions, then answer (below). On `NOTIFIED` react (below). On `STALLED`, or when an active job has produced no event for about 15 minutes, run `status <job-id>` at once and look at the owner process and the time of the last progress entry; a job whose owner has exited is dead even if the store still says running, so report it and re-dispatch instead of waiting. Never let a silent job sit unchecked for an hour. Nothing else needs re-dispatching; the monitor keeps reporting.
4. **Stop the monitor when the work is done.** Once every job you dispatched has reported `DONE` or `FAILED` and you are writing the final report to the user, call TaskStop on the monitor's task id. A monitor left running after the task is finished sits in the user's session for hours doing nothing useful. Arm a new one at the next dispatch; arming is one call.

Sandbox: every Codex task runs without a sandbox (full read/write access and network), which is the user's standing policy; codex-worker passes `--sandbox danger-full-access` unless the header says otherwise. Read-only intent for `investigate` is stated in the brief, not enforced by the sandbox, so keep writing "read-only, do not modify files" into investigation briefs. `SANDBOX: network` (workspace-write plus network) or `SANDBOX: default` (the plugin's own read-only / workspace-write choice) narrow it for a single task; use them only when the user asks. On plugins without the `--sandbox` option the task runs in the plugin's default sandbox and cannot open sockets; a Codex report that tests could not run there is not a test failure.

Fallback, when the plugin has no `events` or the Monitor tool is unavailable: dispatch the `codex-worker` agent with the same header-and-body text as its prompt (without `WAIT: no`). It waits in bounded rounds and returns `STATUS: done`, `waiting-for-answer`, or `notified` with Codex's output verbatim; after handling a question or note, dispatch it again with `MODE: wait` and `JOB: <id>` to keep waiting. Never run both a monitor and a waiting worker on the same job: whichever collects a notification acknowledges it and the other never sees it.

Prompt format: a few header lines, a blank line, then the brief body. Add `CWD: <absolute path>` when Codex must run in a repository other than the current directory (the script inherits your working directory otherwise). Add `SIBLINGS: <one line>` when other Codex tasks you started are still running: name each with its job ID and a few words on what it does. codex-worker copies the line into the note it prepends for Codex (see "What Codex knows about you" below).

```
MODE: investigate
EFFORT: high

<brief>
```

### MODE and effort

Codex runs on `gpt-6-astra` by default (set in `~/.codex/config.toml`, together with a default effort of `high`). On this model, **medium or high is enough for nearly every task**; do not set `MODEL` unless the user asks for a specific model.

| Goal | MODE | EFFORT | Notes |
|---|---|---|---|
| Scan the codebase to answer a question, locate entry points, small well-scoped edits | investigate / implement | medium | Fast; the default for anything narrow |
| Trace call chains, understand a module, implement a change from requirements | investigate / implement | high | The default for anything that spans several files |
| Find the root cause of a bug or odd behavior | investigate | high | Start here; escalate to xhigh only if the high round comes back inconclusive |
| Any follow-up on a problem that already has a thread | continue | unset | Put `THREAD: <id>` in the header; writes files only with `WRITE: yes` |
| Keep waiting on a running job after a question or notification (fallback without the event monitor) | wait | unset | Put `JOB: <id>` in the header; the body may be empty. Starts nothing |
| Standard code review | review | unset | Prefer providing `BASE: <ref>`, see below |
| Challenge the approach and assumptions | adversarial-review | unset | Body is the focus text; prefer providing `BASE: <ref>` |

Picking the effort:

- **medium**: the answer lives in one or two files, or the edit is a few lines at a known location and you only delegate because the code is unfamiliar.
- **high**: everything else. Multi-file investigation, implementation from requirements, first root-cause pass.
- **xhigh**: reserved. Use it only when a `high` round already ran and came back without a clear answer, or the problem is known to be non-deterministic (concurrency, ordering, intermittent failures) and needs long reasoning over many interacting paths. Do not start a task at xhigh; when escalating, prefer `continue` in the same thread with `EFFORT: xhigh` in the header so Codex keeps what it already read.

### Review modes and untracked files

Without `BASE`, the plugin uses working-tree mode and inlines the content of every untracked file into the prompt. Repos with many untracked files exceed Codex's input limit and the review fails. Two options:

- **Preferred**: commit the change to a branch first and put `BASE: <base branch>` in the header so only the committed diff is compared.
- If committing is not possible, do nothing special. codex-worker counts untracked files and, above 3, automatically falls back to a read-only task that performs the review, adding a NOTE line to its return. In that case **list the changed files in the brief body** so Codex knows what to look at.

### Thread continuity: keep one Codex thread per problem

Codex has a very large context window, and a thread keeps everything Codex has read and concluded so far. Follow-ups on the same problem are faster and more accurate when they land in the same thread, so **once a problem has a thread, every later dispatch about that problem uses `continue`**: further investigation, follow-up questions, implementing what the investigation found, and fixing review findings. Start a fresh `investigate` or `implement` only for a different problem, or when the thread has clearly gone wrong.

How it works:

- Every task-class result comes back with a `THREAD: <id>` line. Remember it together with the problem it belongs to.
- Put `THREAD: <id>` in the header of every `continue` for that problem. With a plugin that supports `task --thread` (see openai/codex-plugin-cc PR #719), codex-worker resumes exactly that thread, so several problems can be interleaved freely in one repo. With an older plugin, codex-worker verifies the thread against the one the plugin is about to resume and refuses with `THREAD_MISMATCH` otherwise; in that case, while a problem is in progress, do not dispatch other task-class jobs (`investigate`, `implement`, or a review that falls back to a task) in the same repo between two `continue` calls, because only the most recent thread can be resumed. Reviews in branch or working-tree mode are review-class and do not affect this.
- `continue` starts a later turn after the previous job finishes. While the job is still running, use the live controls below instead of dispatching another task.
- A `continue` brief can be short: state what changed since last time and what to do next. Codex already has the background.

On an older plugin, parallel routes are therefore for independent problems or one-shot work, not for a problem you intend to keep iterating on.

### Live corrections and questions

The slash commands below are user-facing shorthand. For automatic coordination, call the corresponding `message`, `answer`, `status`, or `result` subcommand through Bash on the same selected `codex-companion.mjs`, with `--cwd` set to the job's repository. Do not invoke these commands as skills.

Keep the job ID with its repository and thread. With a running task, send new context immediately using `/codex:message <job-id> <text>` (or the same `message` subcommand on the selected `codex-companion.mjs`). Use `--prompt-file` for multiline text. A successful response means accepted for the next model request, not that the instruction has already been followed.

Use `/codex:message <job-id> --interrupt <text>` when the current approach must stop. It cancels the turn and continues the same job and thread with the new instruction, retaining its original write permission. Report the returned partial changes; interruption does not undo files. Do not use this to escalate a read-only task's permissions.

On `STATUS: waiting-for-answer`, the Codex job remains running. Read the returned questions. Answer from already established facts, or ask the user when a choice or authorization is missing. Never infer permission from a factual answer. Write an answers-map JSON file, for example `{"source":{"answers":["Use the latest plan center result."]}}`, and call `/codex:answer <job-id> --request-id <id> --answers-file <path>`. Do not send an ordinary message to answer a structured request.

After answering, with the event monitor armed there is nothing more to do; it reports the next event. Without it, dispatch codex-worker with `MODE: wait` and `JOB: <job-id>` (plus `CWD:` if the job runs elsewhere); it waits on the same job and returns done, another question, or a notification, collecting the result on done. This is coordination, not another implementation dispatch. Questions time out after 10 minutes by default and interrupt the turn; report that outcome without inventing an answer. Ordinary prose questions that already ended a turn still use `continue` in the same thread. Old plugins without `message` require an update; do not pretend that live delivery succeeded.

### Notifications from Codex

On plugins that expose the `notify_director` tool, Codex can send you a one-line note while it keeps working. It reaches you as a `NOTIFIED` event from the monitor, or as `STATUS: notified` from a waiting worker together with the `JOB:` and `THREAD:` lines and the notes; the job is still running either way. Read the note and decide: start parallel work that it makes possible (for example, a test-writing task once the root cause is known), send the job a `message` if the note changes what it should do, or do nothing. Without the monitor, dispatch `MODE: wait` with the same `JOB:` afterwards. Delivered notes are acknowledged and do not come back again; `/codex:status <job-id>` shows notes that have not been delivered yet. Codex is told to use the tool only for conclusions that change the plan, blockers, or a finished phase, so treat a note as worth reading, not as routine progress.

### What Codex knows about you

For `investigate` and `implement`, codex-worker prepends a fixed note to your brief: Codex was started by a director agent, not a human; `request_user_input` questions are addressed to you; `notify_director` exists (when the plugin supports it); other Codex tasks may be running and Codex must not coordinate with them itself but tell you instead. The `SIBLINGS:` header fills in the list of running tasks. Consequences for you:

- Codex tasks never talk to each other. You are the only relay. When a new task overlaps the area of a running one, send the running job a one-line `message` saying what has started, and put the running job in the new task's `SIBLINGS:` line. Most dispatches need neither.
- A `request_user_input` from Codex is a question to you. Answer from established facts; ask the user only for choices or authorization you do not have.
- Do not repeat the note's content in the brief; write the brief as before.

### Isolate tasks that write files

Only one `implement` per checkout at a time. To run parallel edits (for example, two approaches by Codex), give each route its own worktree (`git worktree add <path> <branch>`) and put that path in `CWD:`; compare afterwards and merge the one you pick. On the agent fallback, `isolation: "worktree"` on the Agent tool does the same. Read-only tasks need no isolation.

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
2. Dispatch `implement`. If the affected area is unclear, dispatch `investigate` first and then `continue` in that thread with the implementation (rather than a separate parallel route, so the thread keeps what it learned).
3. When the implementation returns, **decide whether a review is worth it**. Review is not a fixed step; it is your call, made on the returned result. Weigh how much could go wrong if the change is subtly wrong against what a review costs (a brief, a wait, and one more round of context), and dispatch `adversarial-review` only when the risk justifies it (intent of the change and your main concerns as the body; prefer `BASE:`, since a fallback review is task-class and would become the most recent thread). When you skip it, go straight to wrap-up and tell the user in one line that you skipped the review and why.
4. If you reviewed: for high or medium findings, dispatch `continue` with `THREAD:` and `WRITE: yes` so Codex fixes them in the same thread, then judge again whether another review round is needed. At most three rounds; step in yourself if it is still not clean.
5. Wrap up: run the tests or verification command, spot-check one or two `file:line` claims from Codex, then report to the user.

Read-only tasks (questions, investigations): one `investigate` route is enough. Follow-up questions from the user about the same topic go to `continue` with the same `THREAD:`.

## What not to delegate to Codex

**Simple tasks: do them yourself.** Delegating costs a brief, a dispatch, and a wait of at least a minute. If you can finish the task in about three tool calls without needing to understand unfamiliar code, delegating is slower than doing it. Examples: looking up one value in a file you already know, a single grep, a one-line or few-line fix at a known location, renaming, editing a config entry, running a command and reporting its output, answering from what is already in the conversation. Dispatch Codex only when the task needs reading or writing code beyond that.

- Requirements that are still undecided and need a trade-off confirmed with the user.
- Operations on live environments (production servers, ssh to remote hosts, changing configuration of running services): Codex can read scripts and propose a plan, but you perform the execution.
- Talking to the user.
- **Writing documents and artifacts (HTML pages, reports, session summaries, READMEs and other human-facing output) is done by you, not Codex.** Dispatch `investigate` first if you need facts or material; write the document yourself. This rule constrains your division of labor only; do not write it into briefs. Codex updating comments, a README, or adding an explanation while coding is its own business; do not add restrictions such as "do not write documentation".

## When the session gets long

When the context is long and early information starts getting lost, run `/codex:transfer` to turn the whole session into a Codex thread, give the user the resulting `codex resume <id>`, and let the user decide whether to continue in Codex or start a new session.

## After receiving a result

With the monitor, you read Codex's text yourself with the companion's `result <job-id>`; the fallback worker returns it verbatim with a single STATUS line prepended.

- Spot-check one or two `file:line` references before trusting them; Codex is also wrong sometimes.
- On `STATUS: failed` or `CODEX_FAILED`: report the most useful log lines to the user. Do not take over and redo the whole task yourself.
- Do not auto-apply every review finding; decide first which ones are real.
