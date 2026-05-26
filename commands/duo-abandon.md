---
description: Cancel the active /duo planning session. Writes .outcome=abandoned, removes the inflight marker (clearing the badge), and runs T2 telemetry so the bill is bounded. Refuses if no active /duo session.
---

# /duo-abandon — cancel the active /duo session

You are running the **duo** pipeline's abandonment step. `/duo-abandon` cleanly closes the active /duo planning session without executing it: it writes `.outcome=abandoned`, removes the inflight marker, runs the T2 telemetry summariser, and clears the status-line badge.

If no /duo session is active (no `.duo-inflight` in any session subdir), refuse and tell the operator there's nothing to abandon.

## Prerequisites

None beyond an active /duo session. Plan-mode state is irrelevant — this command does not call `ExitPlanMode` and does not dispatch any subagent.

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
  echo "NO_SESSION: no active /duo session to abandon."
  exit 0
fi
if [ "$ACTIVE_COUNT" -gt 1 ]; then
  echo "WARN: multiple active /duo sessions found; abandoning the first encountered."
fi
SESSION_DIR="$(dirname "$ACTIVE_INFLIGHT")"
echo "session_dir=${SESSION_DIR}"
```

If the output starts with `NO_SESSION:`, **stop now** — print the message and end.

Capture the `session_dir=...` value; use it as the literal path for the cleanup step.

## Cleanup + telemetry

Order matters: (1) write `.outcome` first so its mtime bounds the T2 time window correctly; (2) invoke the summariser **before** removing `.duo-inflight` so `telemetry.json` is guaranteed present when the next status-line render detects the section transition (accumulator reconciles against `cost_usd_estimate`). `PLAN.md` is left in place for forensics; the 30-day session reaper will eventually remove it.

Run via `Bash` (substitute `<SESSION_DIR>` with the literal value captured above):

```bash
printf '%s' "abandoned" > "<SESSION_DIR>/.outcome.tmp"
mv -f "<SESSION_DIR>/.outcome.tmp" "<SESSION_DIR>/.outcome"
# Remove session ID sidecar so otelHeadersHelper stops injecting the header.
rm -f "${HOME}/.claude/active-sessions/$(basename "<SESSION_DIR>").lck"
~/.claude/scripts/telemetry-summarize.sh \
    "<SESSION_DIR>" duo abandoned "$(cat \"<SESSION_DIR>/.transcript-uuid\" 2>/dev/null || echo \"${CLAUDE_SESSION_ID:-}\")" 2>&1 \
    | tail -n 1
rm -f "<SESSION_DIR>/.duo-inflight"
```

## Confirmation

Print to the operator:

> /duo session abandoned. Session dir: `<SESSION_DIR>` (PLAN.md preserved for forensics; auto-removed in 30 days).

---

## What this command does NOT do

- ❌ Call `ExitPlanMode`.
- ❌ Dispatch Actor.
- ❌ Delete `PLAN.md` or any session artefacts (only `.duo-inflight` is removed).
- ❌ Auto-commit or auto-push.
