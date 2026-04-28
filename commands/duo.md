---
description: Lightweight pipeline — Sonnet plans interactively (you), dispatches Actor as a Haiku subagent. No Phase 0, no Reviewer. For simple, well-scoped tasks.
---

# /duo — Sonnet plans, Haiku acts

You are running the **duo** pipeline. You (Sonnet 4.6) plan interactively with the operator; then you dispatch a single **Actor subagent** (Haiku 4.5) via the `Task` tool to execute. There is no Phase 0 RESEARCH (use `/explore` if you need interrogation). There is no Reviewer.

Use `/duo` when the task is simple enough that a plan + execute is sufficient, and you don't need a review loop.

## When to use /duo vs /explore

| Situation | Use |
|---|---|
| Simple, well-scoped, ≤ 10 steps, low blast-radius | `/duo` |
| Multi-file refactor, architecture change, anything where review matters | `/explore` |

## Cost note

`/duo` is designed to run from a **Sonnet 4.6 session** for the planning phase. Switch with `/model claude-sonnet-4-5` before invoking if you're currently on Opus. The Actor subagent is pinned to Haiku 4.5 by frontmatter regardless of parent model.

## Prerequisites

1. **Plan mode is active.** If not, stop and say:
   > "Please enter plan mode first (Shift+Tab), then run `/duo` again."
2. **Sonnet 4.6 at parent** (recommended, not enforced).
3. **Bypass-flattens-down caveat.** Same as `/explore`: if the operator launched the parent with `--dangerously-skip-permissions`, Actor inherits bypass and the Plan-Then-Execute gate is decorative.

## Setup — per-invocation artifact directory + housekeeping

Same idiom as `/explore`: create a fresh subdir, export it for the Actor subagent, lazily clean up old subdirs.

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
export CLAUDE_ORCHESTRA_SESSION_DIR="${SESSION_DIR}"
echo "session_dir=${SESSION_DIR}"
echo "retention_days=${RETENTION_DAYS}"
```

After creating the session directory, write a `.duo-inflight` marker containing the task title. The title is the operator's invocation text (the args after `/duo`), truncated to 30 printable characters, with single-quotes replaced by spaces. Run via `Bash`:

```bash
printf '%s' "<task title, ≤30 chars, no single-quotes>" \
  > "${CLAUDE_ORCHESTRA_SESSION_DIR}/.duo-inflight.tmp"
mv -f "${CLAUDE_ORCHESTRA_SESSION_DIR}/.duo-inflight.tmp" \
      "${CLAUDE_ORCHESTRA_SESSION_DIR}/.duo-inflight"
```

Replace `<task title, ≤30 chars, no single-quotes>` with the first 30 printable characters of the operator's task description, stripping any single-quote characters.

Print the session_dir so the operator can locate `PLAN.md` and `TASKS.json` later.

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

**Keep it tight:** if more than ~10 steps, recommend `/explore` instead.

Persist via atomic-rename:

```bash
cat > "${CLAUDE_ORCHESTRA_SESSION_DIR}/PLAN.md.tmp" <<'EOF'
[full plan text]
EOF
mv -f "${CLAUDE_ORCHESTRA_SESSION_DIR}/PLAN.md.tmp" "${CLAUDE_ORCHESTRA_SESSION_DIR}/PLAN.md"
```

---

## Phase 2 — Plan approval gate

Before calling `ExitPlanMode`, remove the in-flight marker so the status line clears as soon as planning ends:

```bash
rm -f "${CLAUDE_ORCHESTRA_SESSION_DIR}/.duo-inflight"
```

Then call `ExitPlanMode` with the full plan content. You are the only caller — do not call it before the plan is fully agreed.

The operator will see Claude Code's standard "auto-edit / manually approve / cancel" prompt at the parent layer. Their choice sets the permission posture for Phase 3.

On rejection: stay in plan mode, re-create the marker and refine the plan, repeat Phase 1:

```bash
printf '%s' "<task title>" > "${CLAUDE_ORCHESTRA_SESSION_DIR}/.duo-inflight.tmp"
mv -f "${CLAUDE_ORCHESTRA_SESSION_DIR}/.duo-inflight.tmp" "${CLAUDE_ORCHESTRA_SESSION_DIR}/.duo-inflight"
```

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

Short summary to the operator:

- Session dir path.
- Files changed.
- Tests run (if Actor chose to run any).
- Anything to verify manually.

Do **not** commit, push, or open a PR unless explicitly asked.

---

## What this command does NOT do

- ❌ Spawn `claude -p` subprocesses or use `run-tier.sh`.
- ❌ Have a Phase 0 RESEARCH stage (use `/explore` for that).
- ❌ Have a Reviewer (use `/explore` for that).
- ❌ Auto-commit or auto-push.
- ❌ Run multiple parallel Actor invocations (single Actor handles the whole plan).

$ARGUMENTS
