---
description: Commit the active /duo plan and execute — transitions from planning discussion to action. Calls ExitPlanMode, dispatches Actor (Haiku), and runs cleanup + telemetry. Refuses if no active /duo session.
---

# /duo-act — commit the active /duo plan and execute

You are running the **duo** pipeline's commit-and-execute step. `/duo-act` finalises the active /duo planning session: it presents the current `PLAN.md`, calls `ExitPlanMode`, dispatches the Actor (Haiku) subagent, then runs cleanup + telemetry.

If no /duo session is active (no `.duo-inflight` in any session subdir), refuse and tell the operator to run `/duo-plan` first.

## Prerequisites

1. **Plan mode is active.** `/duo-act` calls `ExitPlanMode`, which only fires from plan mode. If not, stop and say:
   > "Please enter plan mode first (Shift+Tab), then run `/duo-act`."
2. **An active /duo session exists.** Verified below.

## Locate the active session

Run via `Bash`:

```bash
CLAUDE_PROJECT_DIR="$(realpath "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$(pwd)}")"
SESSIONS_ROOT="${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions"
ACTIVE_INFLIGHT=""
ACTIVE_COUNT=0
if [ -d "$SESSIONS_ROOT" ]; then
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    ACTIVE_INFLIGHT="$path"
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
  done < <(find "$SESSIONS_ROOT" -mindepth 2 -maxdepth 2 -name '.duo-inflight' 2>/dev/null)
fi
if [ -z "$ACTIVE_INFLIGHT" ]; then
  echo "NO_SESSION: no active /duo session — run /duo-plan first."
  exit 0
fi
if [ "$ACTIVE_COUNT" -gt 1 ]; then
  echo "WARN: multiple active /duo sessions found; using the first encountered."
fi
SESSION_DIR="$(dirname "$ACTIVE_INFLIGHT")"
echo "session_dir=${SESSION_DIR}"
```

If the output starts with `NO_SESSION:`, **stop now** — print the message to the operator and end. Do not call `ExitPlanMode`, do not dispatch Actor.

Capture the `session_dir=...` value; use it as the literal path for the rest of this command.

## Read PLAN.md

Read `<SESSION_DIR>/PLAN.md`. If it does not exist (e.g. `/duo-plan` was interrupted), stop and tell the operator the session is malformed; suggest `/duo-abandon`.

You may show the operator a brief one-line confirmation of what's about to run, but you do not need to re-display the full plan — they have been refining it. Proceed directly to the approval gate.

## Plan approval gate

Call `ExitPlanMode` with the full text of `<SESSION_DIR>/PLAN.md`. The operator
will see Claude Code's standard "auto-edit / manually approve / cancel" prompt.

- **Approved (auto-edit or manually approve):** the parent exits plan mode and Phase 3 below proceeds. The permission posture set here applies to Actor's tool calls.
- **Rejected (cancel):** the assistant's turn pauses. The session **stays open** — `.duo-inflight` is preserved. The operator can refine more and run `/duo-act` again, or run `/duo-abandon` to give up. Do not run any cleanup on rejection.

---

## Phase 3 — Execute (Task → Actor subagent)

After `ExitPlanMode` is approved, dispatch Actor via the `Task` tool with `subagent_type: actor`. Prompt includes:

- The literal session directory path (`<SESSION_DIR>`).
- The full plan text from `PLAN.md`.
- An instruction to update `TASKS.json` in the session dir as steps complete.
- An instruction to return one of `ready_for_review | blocked | partial`.
- An instruction to include a diff summary in the final message.

Actor returns when:

- All steps complete: status `ready_for_review`, with diff summary. Show the diff to the operator.
- Blocked on a step: status `blocked: <reason>`. Surface to operator. Do not auto-retry. Decide whether to revise the plan and re-run, or abandon.
- Partial: status `partial: <details>`. Usually means dispatch Actor again for the remainder, possibly after operator clarification.

Map Actor's return to a cleanup `outcome`:

| Actor return | outcome |
|---|---|
| `ready_for_review` | `pass` |
| `blocked: …` | `block` |
| `partial: …` | `partial` |

---

## Phase 4 — Cleanup + telemetry

Use the literal session dir path captured above (substitute `<SESSION_DIR>`). Order matters: (1) write `.outcome` first so its mtime bounds the T2 time window; (2) invoke the summariser **before** removing `.duo-inflight` so `telemetry.json` is guaranteed present when the next status-line render detects the section transition (accumulator reconciles against `cost_usd_estimate`).

```bash
printf '%s' "<outcome: pass | block | partial>" > "<SESSION_DIR>/.outcome.tmp"
mv -f "<SESSION_DIR>/.outcome.tmp" "<SESSION_DIR>/.outcome"
# Remove session ID sidecar so otelHeadersHelper stops injecting the header.
rm -f "${HOME}/.claude/active-sessions/$(basename "<SESSION_DIR>").lck"
~/.claude/scripts/telemetry-summarize.sh \
    "<SESSION_DIR>" duo "<outcome>" "$(cat \"<SESSION_DIR>/.transcript-uuid\" 2>/dev/null || echo \"${CLAUDE_SESSION_ID:-}\")" 2>&1 \
    | tail -n 1
rm -f "<SESSION_DIR>/.duo-inflight"
```

Then clear any stale pipeline badge from state.env:

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
printf 'ORCHESTRA_MODE=default\nORCHESTRA_TITLE=\n' \
  >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"
```

The summariser writes `<SESSION_DIR>/telemetry.json` (full record) and appends one line to `~/.claude/orchestra/telemetry.jsonl` (global trend log). Errors are logged to `parser_warnings[]` in the JSON; the script never fails the pipeline.

---

## Final summary

Print to the operator:

- Session dir path.
- Files changed (from Actor's diff summary).
- Tests run (if Actor chose to run any).
- Anything to verify manually.

Do **not** commit, push, or open a PR unless explicitly asked.

---

## What this command does NOT do

- ❌ Open a new /duo session (that's `/duo-plan`).
- ❌ Cancel without executing (that's `/duo-abandon`).
- ❌ Spawn `claude -p` subprocesses or use `run-tier.sh`.
- ❌ Have a Reviewer (use `/brain` for that).
- ❌ Auto-commit or auto-push.
- ❌ Run multiple parallel Actor invocations (single Actor handles the whole plan).
