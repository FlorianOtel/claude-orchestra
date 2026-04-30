---
description: Lightweight pipeline — Sonnet plans interactively (you), dispatches Actor as a Haiku subagent. No Phase 0, no Reviewer. For simple, well-scoped tasks.
---

# /duo — Sonnet plans, Haiku acts

You are running the **duo** pipeline. You (Sonnet 4.6) plan interactively with the operator; then you dispatch a single **Actor subagent** (Haiku 4.5) via the `Task` tool to execute. There is no Phase 0 RESEARCH (use `/brain` if you need interrogation). There is no Reviewer.

Use `/duo` when the task is simple enough that a plan + execute is sufficient, and you don't need a review loop.

## When to use /duo vs /brain

| Situation | Use |
|---|---|
| Simple, well-scoped, ≤ 10 steps, low blast-radius | `/duo` |
| Multi-file refactor, architecture change, anything where review matters | `/brain` |

## Cost note

`/duo` is designed to run from a **Sonnet 4.6 session** for the planning phase. Switch with `/model claude-sonnet-4-6` before invoking if you're currently on Opus. The Actor subagent is pinned to Haiku 4.5 by frontmatter regardless of parent model.

## Prerequisites

1. **Plan mode is active.** If not, stop and say:
   > "Please enter plan mode first (Shift+Tab), then run `/duo` again."
2. **Model check (advisory):** Read "The exact model ID is…" from your system context.
   - If on `claude-sonnet-4-6` or higher (including any Opus): proceed silently.
   - If on any other model, note it to the operator before continuing:
     > "⚠️ /duo recommends Sonnet 4.6 for planning. You are on [MODEL-ID]. Switch with `/model claude-sonnet-4-6` if desired — proceeding anyway."
3. **Bypass-flattens-down caveat.** Same as `/brain`: if the operator launched the parent with `--dangerously-skip-permissions`, Actor inherits bypass and the Plan-Then-Execute gate is decorative.

## Setup — per-invocation artifact directory + housekeeping

Create a fresh subdir and write the `.duo-inflight` marker in **one Bash call** so the
status-line badge appears immediately. (Env exports do not persist across Bash tool
calls, so session dir creation and inflight write must share the same shell.)

Replace `<task title, ≤30 chars, no single-quotes>` with the first 30 printable
characters of the operator's task description, stripping any single-quote characters.

Run via `Bash`:

```bash
SESSIONS_ROOT="${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions"
_parse_retention() {
  awk '
    /^housekeeping:/ { in_hk = 1; next }
    in_hk && /^[^ ]/ { in_hk = 0 }
    in_hk && /session_retention_days:/ {
      gsub(/[^0-9]/, "", $2); print $2; exit
    }
  ' "$1" 2>/dev/null
}
# Precedence: per-project override > global default > hardcoded 30.
RETENTION_DAYS=$(_parse_retention "${CLAUDE_PROJECT_DIR}/.claude/orchestra/config.yaml")
[ -z "${RETENTION_DAYS}" ] && \
  RETENTION_DAYS=$(_parse_retention "${HOME}/.claude/orchestra/config.yaml")
RETENTION_DAYS="${RETENTION_DAYS:-30}"

if [ -d "${SESSIONS_ROOT}" ]; then
  find "${SESSIONS_ROOT}" -mindepth 1 -maxdepth 1 -type d \
       -mtime +"${RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null
fi

SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SESSION_DIR="${SESSIONS_ROOT}/${SESSION_ID}"
mkdir -p "${SESSION_DIR}"
# Write inflight marker in the same shell so SESSION_DIR is available.
# Stays live through actor execution; removed in Phase 4 cleanup.
printf '%s' "<task title, ≤30 chars, no single-quotes>" \
  > "${SESSION_DIR}/.duo-inflight.tmp"
mv -f "${SESSION_DIR}/.duo-inflight.tmp" "${SESSION_DIR}/.duo-inflight"
echo "session_dir=${SESSION_DIR}"
echo "retention_days=${RETENTION_DAYS}"
```

Capture the `session_dir=...` value from the output — you will use this literal path
in all subsequent Bash calls (Phase 2, Phase 3 prompt, Phase 4). Do not rely on
`${CLAUDE_ORCHESTRA_SESSION_DIR}`; it is not set in later bash subprocesses.

---

## Phase 1 — Interactive plan (you)

Work with the operator interactively to crystallise the plan. Read files, explore the codebase, ask questions, propose alternatives. The operator can push back, redirect, or narrow scope across as many turns as needed — this is the "interactive" part.

When the plan is agreed, write it with this structure:

1. **Intent** — one line: what will be true when done.
2. **Steps** — numbered, imperative, each executable by Actor as a single edit or shell command.
3. **Expected outcome per step** — one line each.
4. **Doc impact** — which project docs need updating; include as numbered steps if any.
5. **Risks / unknowns** — anything you couldn't verify by reading.
6. **Out of scope** — the hard fence Actor must not cross.

**Keep it tight:** if more than ~10 steps, recommend `/brain` instead.

Persist via atomic-rename:

```bash
cat > "${CLAUDE_ORCHESTRA_SESSION_DIR}/PLAN.md.tmp" <<'EOF'
[full plan text]
EOF
mv -f "${CLAUDE_ORCHESTRA_SESSION_DIR}/PLAN.md.tmp" "${CLAUDE_ORCHESTRA_SESSION_DIR}/PLAN.md"
```

---

## Phase 2 — Plan approval gate

Call `ExitPlanMode` with the full plan content. Do not remove `.duo-inflight` here —
it stays alive through actor execution so the status-line badge persists. It is
removed in Phase 4 cleanup.

The operator will see Claude Code's standard "auto-edit / manually approve / cancel"
prompt at the parent layer. Their choice sets the permission posture for Phase 3.

On rejection: stay in plan mode and refine the plan, then repeat Phase 1. The
`.duo-inflight` marker is already present; no need to recreate it.

---

## Phase 3 — Execute (Task → Actor subagent)

Dispatch Actor via the `Task` tool with `subagent_type: actor`. Prompt includes:

- The session directory path (`${CLAUDE_ORCHESTRA_SESSION_DIR}`).
- The full plan text from `PLAN.md`.
- An instruction to update `TASKS.json` in the session dir as steps complete.
- An instruction to return one of `ready_for_review | blocked | partial`.
- An instruction to include a diff summary in the final message.

Actor returns when:

- All steps complete: status `ready_for_review`, with diff summary. Show the diff to the operator.
- Blocked on a step: status `blocked: <reason>`. Surface to operator. Do not auto-retry. Decide whether to revise the plan and re-run, or abandon.
- Partial: status `partial: <details>`. Usually means dispatch Actor again for the remainder, possibly after operator clarification.

---

## Phase 4 — Done

### Telemetry finalisation (per-session)

Before the final summary, remove the inflight marker, write the outcome, and trigger
the T2 telemetry pass. Use the literal session dir path captured from the setup step
(substitute `<SESSION_DIR>` with that value):

```bash
rm -f "<SESSION_DIR>/.duo-inflight"
printf '%s' "<outcome: pass | block | partial>" > "<SESSION_DIR>/.outcome"
~/.claude/scripts/telemetry-summarize.sh \
    "<SESSION_DIR>" duo "<outcome>" "${CLAUDE_SESSION_ID:-}" 2>&1 \
    | tail -n 1
```

The summariser writes `${CLAUDE_ORCHESTRA_SESSION_DIR}/telemetry.json` (full record) and appends one line to `~/.claude/orchestra/telemetry.jsonl` (global trend log). Errors are logged to `parser_warnings[]` in the JSON; the script never fails the pipeline.

---

Short summary to the operator:

- Session dir path.
- Files changed.
- Tests run (if Actor chose to run any).
- Anything to verify manually.

Do **not** commit, push, or open a PR unless explicitly asked.

---

## What this command does NOT do

- ❌ Spawn `claude -p` subprocesses or use `run-tier.sh`.
- ❌ Have a Phase 0 RESEARCH stage (use `/brain` for that).
- ❌ Have a Reviewer (use `/brain` for that).
- ❌ Auto-commit or auto-push.
- ❌ Run multiple parallel Actor invocations (single Actor handles the whole plan).

$ARGUMENTS
