---
description: Cancel the active /brain session. Writes .outcome=abandoned, removes the inflight marker, runs T2 telemetry so the bill is bounded, and clears the status-line badge. Refuses if no active /brain session.
---

# /brain-abandon — cancel the active /brain session

You are running the **brain** pipeline's abandonment step. `/brain-abandon` cleanly closes the active /brain session without further execution: it writes `.outcome=abandoned`, removes the `.brain-inflight` marker, runs the T2 telemetry summariser, and clears the status-line badge in `state.env`.

If no /brain session is active (no `.brain-inflight` in any session subdir), refuse and tell the operator there's nothing to abandon.

## Prerequisites

None beyond an active /brain session. Plan-mode state is irrelevant — this command does not call `ExitPlanMode` and does not dispatch any subagent.

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
  done < <(find "$SESSIONS_ROOT" -mindepth 2 -maxdepth 2 -name '.brain-inflight' 2>/dev/null)
fi
if [ -z "$ACTIVE_INFLIGHT" ]; then
  echo "NO_SESSION: no active /brain session to abandon."
  exit 0
fi
if [ "$ACTIVE_COUNT" -gt 1 ]; then
  echo "WARN: multiple active /brain sessions found; abandoning the first encountered."
fi
SESSION_DIR="$(dirname "$ACTIVE_INFLIGHT")"
echo "session_dir=${SESSION_DIR}"
```

If the output starts with `NO_SESSION:`, **stop now** — print the message and end.

Capture the `session_dir=...` value; use it as the literal path for the cleanup step.

## Cleanup + telemetry

Order matters: (1) write `.outcome` first so its mtime bounds the T2 time window correctly; (2) invoke the summariser **before** removing `.brain-inflight` so `telemetry.json` is guaranteed present when the next status-line render detects the section transition (accumulator reconciles against `cost_usd_estimate`). `RESEARCH.md` and `PLAN.md` (if present) are left in place for forensics; the 30-day session reaper will eventually remove them.

Run via `Bash` (substitute `<SESSION_DIR>` with the literal value captured above):

```bash
printf '%s' "abandoned" > "<SESSION_DIR>/.outcome.tmp"
mv -f "<SESSION_DIR>/.outcome.tmp" "<SESSION_DIR>/.outcome"
# Remove session ID sidecar so otelHeadersHelper stops injecting the header.
rm -f "${HOME}/.claude/active-sessions/$(basename "<SESSION_DIR>").lck"
~/.claude/scripts/telemetry-summarize.sh \
    "<SESSION_DIR>" brain abandoned "$(cat \"<SESSION_DIR>/.transcript-uuid\" 2>/dev/null || echo \"${CLAUDE_SESSION_ID:-}\")" 2>&1 \
    | tail -n 1
rm -f "<SESSION_DIR>/.brain-inflight"
```

Then clear the pipeline badge from state.env:

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
printf 'ORCHESTRA_MODE=default\nORCHESTRA_TITLE=\n' \
  >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"
```

## Confirmation

Print to the operator:

> /brain session abandoned. Session dir: `<SESSION_DIR>` (RESEARCH.md/PLAN.md preserved for forensics; auto-removed in 30 days).

---

## What this command does NOT do

- ❌ Call `ExitPlanMode`.
- ❌ Dispatch Planner, Actor, or Reviewer.
- ❌ Delete `RESEARCH.md`, `PLAN.md`, or any session artefacts (only `.brain-inflight` is removed).
- ❌ Auto-commit or auto-push.
