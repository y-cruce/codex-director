#!/usr/bin/env bash
# Shell side of the codex-worker agent. The agent only pastes its input into a file and calls:
#   codex-worker.sh launch <input-file>   parse the header lines, start Codex, print WORK=... JOB=... STARTED
#   codex-worker.sh wait <WORK>           one bounded wait (about 9.5 minutes); prints STILL_RUNNING | WAITING_FOR_ANSWER | NOTIFIED | DONE
#   codex-worker.sh collect <WORK>        print the STATUS / JOB / THREAD lines and the payload
# Used by the director directly:
#   codex-worker.sh companion             print the selected codex-companion.mjs path
#   codex-worker.sh events --cwd <repo>   stream job events (one line each) for a Monitor; needs a plugin with `events`
#
# Input file format: `KEY: value` header lines, a blank line, then the brief body.
# Headers: MODE (investigate|implement|review|adversarial-review|continue|wait), EFFORT, MODEL, BASE, WRITE, THREAD,
# JOB, SIBLINGS, CWD, WAIT (no = return right after launch), SANDBOX (full = no sandbox, the default for every task;
# network = workspace-write plus network access; default = the plugin's own read-only / workspace-write choice).
set -uo pipefail

select_companion() {
  if [ -n "${CODEX_COMPANION:-}" ]; then printf '%s\n' "$CODEX_COMPANION"; return; fi
  local cc f
  cc=$(ls ~/.claude/plugins/cache/*/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
  for f in $(ls ~/.claude/plugins/cache/*/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V); do grep -q '"thread"' "$f" && cc="$f"; done
  for f in $(ls ~/.claude/plugins/cache/*/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V); do grep -q 'case "message":' "$f" && cc="$f"; done
  for f in $(ls ~/.claude/plugins/cache/*/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V); do grep -q 'case "events":' "$f" && cc="$f"; done
  printf '%s\n' "$cc"
}

# Reads $1 (the input file). Sets the header variables and writes the body to $WORK/brief.md.
parse_input() {
  local line key val in_header=1
  MODE=""; EFFORT=""; MODEL=""; BASE=""; WRITE=""; THREAD=""; JOB=""; SIBLINGS=""; CWD=""; WAIT=""; SANDBOX=""
  : > "$WORK/brief.md"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_header" = 1 ]; then
      if [ -z "$line" ]; then in_header=0; continue; fi
      case "$line" in
        MODE:*|EFFORT:*|MODEL:*|BASE:*|WRITE:*|THREAD:*|JOB:*|SIBLINGS:*|CWD:*|WAIT:*|SANDBOX:*)
          key=${line%%:*}; val=${line#*:}; val=${val#"${val%%[![:space:]]*}"}
          printf -v "$key" '%s' "$val" ;;
        *) in_header=0; printf '%s\n' "$line" >> "$WORK/brief.md" ;;
      esac
    else
      printf '%s\n' "$line" >> "$WORK/brief.md"
    fi
  done < "$1"
  CWD="${CWD:-$PWD}"
  [ "$MODEL" = spark ] && MODEL=gpt-5.3-codex-spark
}

# The note prepended to investigate/implement briefs so Codex knows who started it.
director_note() {
  cat <<'EOF'
## Who you are working with
You were started by an automated director agent (Claude Code), not by a human. The director wrote the brief below and reads your final message; no human is watching this thread.
- When you need a decision, missing information, or authorization, call request_user_input. The director answers it.
EOF
  if grep -rq 'notify_director' "$(dirname "$CC")"; then
    cat <<'EOF'
- notify_director(message) sends a one-line note to the director without stopping your work. Use it only when you reach a conclusion that changes the plan (root cause found, scope larger than briefed, a blocker you are working around) or finish a phase the director could act on while you continue. Do not report routine progress. The director does not reply through this tool.
EOF
  fi
  cat <<EOF
- Other Codex tasks started by the same director may be running in this workspace. Do not coordinate with them yourself; tell the director what they need to know, in your final message or through notify_director.
- Other tasks currently running: ${SIBLINGS:-none known}

---- Brief ----
EOF
}

task_effort() {  # $1 default
  printf '%s\n' "${EFFORT:-$1}"
}

do_launch() {
  local input="$1"
  WORK=$(cd "$(dirname "$input")" && pwd)
  CC=$(select_companion)
  if [ -z "$CC" ]; then echo "CODEX_FAILED: no codex-companion.mjs found under ~/.claude/plugins/cache"; exit 1; fi
  parse_input "$input"
  printf '%s\n' "$CC" > "$WORK/companion"
  printf '%s\n' "$CWD" > "$WORK/cwd"
  printf '%s\n' "${WAIT:-yes}" > "$WORK/wait"

  local CMD=() FOCUS CAND
  case "$MODE" in
    investigate)
      { director_note; cat "$WORK/brief.md"; } > "$WORK/prompt.md"
      CMD=(node "$CC" task --cwd "$CWD" --prompt-file "$WORK/prompt.md" --effort "$(task_effort high)") ;;
    implement)
      { director_note; cat "$WORK/brief.md"; } > "$WORK/prompt.md"
      CMD=(node "$CC" task --cwd "$CWD" --prompt-file "$WORK/prompt.md" --effort "$(task_effort high)" --write) ;;
    wait)
      if [ -z "$JOB" ]; then echo "CODEX_FAILED: MODE: wait needs a JOB header"; exit 1; fi
      printf '%s\n' "$JOB" > "$WORK/job"
      echo "WORK=$WORK"; echo "JOB=$JOB"; echo "STARTED"; return ;;
    continue)
      cp "$WORK/brief.md" "$WORK/prompt.md"
      if [ -n "$THREAD" ] && grep -q '"thread"' "$CC"; then
        CMD=(node "$CC" task --cwd "$CWD" --thread "$THREAD" --prompt-file "$WORK/prompt.md")
      else
        CAND=$(node "$CC" task-resume-candidate --cwd "$CWD" --json 2>/dev/null | python3 -c 'import json,sys; print(((json.load(sys.stdin).get("candidate") or {}).get("threadId")) or "")')
        if [ -n "$THREAD" ] && [ "$CAND" != "$THREAD" ]; then
          echo "THREAD_MISMATCH: requested $THREAD but this plugin version can only resume its most recent task thread in this repo, which is ${CAND:-none}. Dispatch a fresh task instead, or continue without THREAD." > "$WORK/note"
          CMD=(false)
        else
          CMD=(node "$CC" task --cwd "$CWD" --resume-last --prompt-file "$WORK/prompt.md")
        fi
      fi
      [ -n "$EFFORT" ] && CMD+=(--effort "$EFFORT")
      [ "$WRITE" = yes ] && CMD+=(--write) ;;
    review|adversarial-review)
      FOCUS=""
      [ "$MODE" = adversarial-review ] && FOCUS="$(tr '\n' ' ' < "$WORK/brief.md")"
      if [ -n "$BASE" ]; then
        CMD=(node "$CC" "$MODE" --cwd "$CWD" --wait --scope branch --base "$BASE" ${FOCUS:+"$FOCUS"})
      elif [ "$(git -C "$CWD" ls-files --others --exclude-standard | wc -l)" -le 3 ]; then
        CMD=(node "$CC" "$MODE" --cwd "$CWD" --wait ${FOCUS:+"$FOCUS"})
      else
        {
          echo 'You are performing a code review. The working tree contains many untracked files; do not treat them as part of this change.'
          echo 'First determine the scope of the change yourself with git status --short and git diff (including --cached). If the brief below lists files, the brief takes precedence.'
          echo 'Report in review form: each finding with file:line, what can go wrong, the impact, and the concrete fix; ordered by severity. If there are no material findings, say so explicitly.'
          echo 'Read-only. Do not modify any file.'
          [ "$MODE" = adversarial-review ] && echo 'Take an adversarial stance: assume the change fails in subtle, high-cost ways. Focus on trust boundaries, data loss or duplication, retries and idempotency, concurrency and ordering, empty/timeout/degraded paths, and compatibility.'
          echo; echo '---- Brief ----'; cat "$WORK/brief.md"
        } > "$WORK/prompt.md"
        echo 'NOTE: too many untracked files; fell back to a read-only task for this review' > "$WORK/note"
        CMD=(node "$CC" task --cwd "$CWD" --prompt-file "$WORK/prompt.md" --effort high)
      fi ;;
    *)
      echo "CODEX_FAILED: unknown MODE '${MODE}'"; exit 1 ;;
  esac
  [ -n "$MODEL" ] && CMD+=(--model "$MODEL")
  if [ "${CMD[2]:-}" = task ]; then
    # Policy: Codex tasks run without a sandbox (full read/write and network) unless the header says otherwise.
    # Read-only intent is expressed in the brief, not enforced by the sandbox.
    local explicit="$SANDBOX"; SANDBOX="${SANDBOX:-full}"
    if grep -rq 'danger-full-access' "$(dirname "$CC")"; then
      case "$SANDBOX" in
        full)    CMD+=(--sandbox danger-full-access) ;;
        network) CMD+=(--sandbox workspace-write --network) ;;
        default) ;;   # keep the plugin's own default (read-only, or workspace-write with --write)
        *)       echo "CODEX_FAILED: SANDBOX must be 'full', 'network' or 'default', got '$SANDBOX'"; exit 1 ;;
      esac
    elif [ -n "$explicit" ]; then
      echo "NOTE: the installed plugin has no --sandbox/--network options; SANDBOX: $explicit was ignored and Codex ran in the plugin's default sandbox" > "$WORK/note"
    fi
  fi

  echo "WORK=$WORK"
  if [ "${CMD[2]:-}" = task ] && grep -q 'case "message":' "$CC"; then
    if "${CMD[@]}" --background --json > "$WORK/launch.json" 2> "$WORK/log"; then
      python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["jobId"])' "$WORK/launch.json" > "$WORK/job"
      echo "JOB=$(cat "$WORK/job")"
    else
      cat "$WORK/log"; exit 1
    fi
  else
    ( nohup "${CMD[@]}" > "$WORK/out.txt" 2> "$WORK/log" < /dev/null; echo $? > "$WORK/exit" ) > /dev/null 2>&1 < /dev/null & disown
  fi
  echo "STARTED"
}

do_wait() {
  WORK="$1"
  if [ -f "$WORK/job" ]; then
    node "$(cat "$WORK/companion")" status "$(cat "$WORK/job")" --cwd "$(cat "$WORK/cwd")" --wait --timeout-ms 540000 --json > "$WORK/status.json" || { echo "STATUS_FAILED"; cat "$WORK/status.json"; exit 1; }
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("WAITING_FOR_ANSWER" if s.get("waitingForAnswer") else "NOTIFIED" if s.get("hasNotifications") else "STILL_RUNNING" if s["job"]["status"] in ("queued","running") else "DONE")' "$WORK/status.json"
  else
    local n=0
    until [ -f "$WORK/exit" ] || [ $n -ge 114 ]; do sleep 5; n=$((n+1)); done
    [ -f "$WORK/exit" ] && echo DONE || echo STILL_RUNNING
  fi
}

do_collect() {
  WORK="$1"
  if [ -f "$WORK/job" ]; then
    if [ ! -f "$WORK/status.json" ]; then
      # Launch-only (WAIT: no): report the job without waiting.
      node "$(cat "$WORK/companion")" status "$(cat "$WORK/job")" --cwd "$(cat "$WORK/cwd")" --json > "$WORK/status.json" 2>/dev/null
      echo "STATUS: started"
      echo "JOB: $(cat "$WORK/job")"
      python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("THREAD: " + (s["job"].get("threadId") or ""))' "$WORK/status.json" 2>/dev/null || echo "THREAD: "
      [ -f "$WORK/note" ] && cat "$WORK/note"
      return 0
    fi
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); j=s["job"]; print("STATUS: " + ("waiting-for-answer" if s.get("waitingForAnswer") else "notified" if s.get("hasNotifications") else "done" if j["status"]=="completed" else "failed")); print("JOB: " + j["id"]); print("THREAD: " + (j.get("threadId") or ""))' "$WORK/status.json"
    [ -f "$WORK/note" ] && cat "$WORK/note"
    if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("waitingForAnswer") else 1)' "$WORK/status.json"; then
      cat "$WORK/status.json"
    elif python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("hasNotifications") else 1)' "$WORK/status.json"; then
      python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); [print("- [" + str(n.get("receivedAt","")) + "] " + str(n.get("message",""))) for n in ((s["job"].get("live") or {}).get("notifications") or [])]' "$WORK/status.json"
    else
      node "$(cat "$WORK/companion")" result "$(cat "$WORK/job")" --cwd "$(cat "$WORK/cwd")"
    fi
  else
    [ -s "$WORK/out.txt" ] && echo "STATUS: done" || echo "STATUS: failed"
    local T
    T=$(grep -o 'Thread ready ([^)]*)' "$WORK/log" 2>/dev/null | tail -1 | sed 's/Thread ready (\(.*\))/\1/'); [ -n "$T" ] && echo "THREAD: $T"
    [ -f "$WORK/note" ] && cat "$WORK/note"
    cat "$WORK/out.txt" 2>/dev/null
    [ -s "$WORK/out.txt" ] || { echo '--- CODEX_FAILED, last 20 log lines:'; tail -20 "$WORK/log" 2>/dev/null; }
  fi
  return 0
}

do_events() {
  local CC
  CC=$(select_companion)
  if [ -z "$CC" ] || ! grep -q 'case "events":' "$CC"; then
    echo "EVENTS_UNSUPPORTED: the installed plugin has no events subcommand; wait with codex-worker instead"
    exit 2
  fi
  exec node "$CC" events "$@"
}

case "${1:-}" in
  launch)    do_launch "$2" ;;
  wait)      do_wait "$2" ;;
  collect)   do_collect "$2" ;;
  companion) select_companion ;;
  events)    shift; do_events "$@" ;;
  *) echo "usage: codex-worker.sh launch <input-file> | wait <WORK> | collect <WORK> | companion | events --cwd <repo>"; exit 1 ;;
esac
