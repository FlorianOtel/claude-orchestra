---
description: Open a /duo planning session — sets up artifacts, drafts initial PLAN.md, and yields back for multi-turn refinement. Run /duo-stop to commit and execute, or /duo-abandon to cancel.
---

# /duo-start — open a planning session

You are running the **duo** pipeline. `/duo-start` opens a multi-turn planning session: it does setup, drafts an initial `PLAN.md`, and **yields control back** to the operator for refinement. ExitPlanMode is **not** called here; refinement happens across subsequent normal plan-mode turns until the operator runs `/duo-stop` (commit + execute) or `/duo-abandon` (cancel).

There is no Phase 0 RESEARCH (use `/brain` if you need formal interrogation). There is no Reviewer.

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
   > "Please enter plan mode first (Shift+Tab), then run `/duo-start` again."
2. **Model check (advisory):** Read "The exact model ID is…" from your system context.
   - If on `claude-sonnet-4-6` or higher (including any Opus): proceed silently.
   - If on any other model, note it to the operator before continuing:
     > "⚠️ /duo recommends Sonnet 4.6 for planning. You are on [MODEL-ID]. Switch with `/model claude-sonnet-4-6` if desired — proceeding anyway."
3. **Bypass-flattens-down caveat.** Same as `/brain`: if the operator launched the parent with `--dangerously-skip-permissions`, Actor inherits bypass and the Plan-Then-Execute gate is decorative.

## Refusal — one active /duo session per project

Before setup, refuse if any `.duo-inflight` already exists under
`${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions/*/`. The session-bracketed
design assumes a single active /duo session at a time; concurrent sessions are
out of scope.

Run via `Bash`:

```bash
CLAUDE_PROJECT_DIR="$(realpath "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$(pwd)}")"
SESSIONS_ROOT="${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions"
EXISTING=""
if [ -d "$SESSIONS_ROOT" ]; then
  EXISTING="$(find "$SESSIONS_ROOT" -mindepth 2 -maxdepth 2 -name '.duo-inflight' 2>/dev/null | head -1)"
fi
if [ -n "$EXISTING" ]; then
  ACTIVE_DIR="$(dirname "$EXISTING")"
  echo "REFUSE: an active /duo session already exists at:"
  echo "  ${ACTIVE_DIR}"
  echo "Run /duo-stop to commit it, or /duo-abandon to cancel, before /duo-start."
  exit 0
fi
```

If the bash call output starts with `REFUSE:`, **stop now** — do not run setup, do not draft a plan. Tell the operator the active session path and stop.

## Setup — per-invocation artifact directory + housekeeping

Create a fresh subdir and write the `.duo-inflight` marker in **one Bash call** so the
status-line badge appears immediately. (Env exports do not persist across Bash tool
calls, so session dir creation and inflight write must share the same shell.)

Replace `<task title, ≤30 chars, no single-quotes>` with the first 30 printable
characters of the operator's task description, stripping any single-quote characters.

Run via `Bash`:

```bash
# CLAUDE_PROJECT_DIR may be unset in Bash subprocesses — resolve it first.
CLAUDE_PROJECT_DIR="$(realpath "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$(pwd)}")"
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
# Stays live through refinement and actor execution; removed by /duo-stop or /duo-abandon.
printf '%s' "<task title, ≤30 chars, no single-quotes>" \
  > "${SESSION_DIR}/.duo-inflight.tmp"
mv -f "${SESSION_DIR}/.duo-inflight.tmp" "${SESSION_DIR}/.duo-inflight"
# Capture current session transcript UUID before subagents create new JSONLs
_MANGLED="$(printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}" | tr '/' '-')"
_TRANSCRIPTS="${HOME}/.claude/projects/${_MANGLED}"
_TRANSCRIPT_UUID=""
if [ -d "$_TRANSCRIPTS" ]; then
  _LATEST="$(ls -t "$_TRANSCRIPTS"/*.jsonl 2>/dev/null | head -1)"
  if [ -n "$_LATEST" ]; then
    _TRANSCRIPT_UUID="$(basename "$_LATEST" .jsonl)"
    printf '%s\n' "$_LATEST" > "${SESSION_DIR}/.transcript-path" 2>/dev/null || true
  fi
fi
printf '%s\n' "${_TRANSCRIPT_UUID}" > "${SESSION_DIR}/.transcript-uuid" 2>/dev/null || true
echo "session_dir=${SESSION_DIR}"
echo "retention_days=${RETENTION_DAYS}"
```

Capture the `session_dir=...` value from the output — you will use this literal path
in `${SESSION_DIR}/PLAN.md` writes during this turn and any refinement turns. Do not
rely on `${CLAUDE_ORCHESTRA_SESSION_DIR}`; it is not set in later bash subprocesses.

---

## Phase 1 — Initial plan draft (this turn only)

Work with the operator interactively to produce a *first* draft of the plan in
**this same response**. Read files, propose an approach, optionally ask one or
two clarifying questions before drafting.

When the initial plan is drafted, write it with this structure:

1. **Intent** — one line: what will be true when done.
2. **Steps** — numbered, imperative, each executable by Actor as a single edit or shell command.
3. **Expected outcome per step** — one line each.
4. **Doc impact** — which project docs need updating; include as numbered steps if any.
5. **Risks / unknowns** — anything you couldn't verify by reading.
6. **Out of scope** — the hard fence Actor must not cross.

**Keep it tight:** if more than ~10 steps, recommend `/brain` instead and offer to abandon this session.

Persist via atomic-rename:

```bash
cat > "<SESSION_DIR>/PLAN.md.tmp" <<'EOF'
[full plan text]
EOF
mv -f "<SESSION_DIR>/PLAN.md.tmp" "<SESSION_DIR>/PLAN.md"
```

---

## Yield back to the operator

After persisting the initial `PLAN.md`, **do not** call `ExitPlanMode`. End the response with a clear handoff message, for example:

> Plan drafted at `<SESSION_DIR>/PLAN.md`.
>
> Refine the plan across subsequent turns — give me feedback and I'll iterate on `PLAN.md` in place. When you're ready:
>
> - Run `/duo-stop` to commit the plan, exit plan mode, and dispatch Actor.
> - Run `/duo-abandon` to cancel this session and clear the badge.

Stop here. The next operator turn will be either a refinement message, `/duo-stop`, or `/duo-abandon`.

---

## Refinement turns (no slash command)

These happen between `/duo-start` and `/duo-stop`/`/duo-abandon`. The operator types feedback; you re-read `${SESSION_DIR}/PLAN.md`, integrate the feedback, and rewrite it via the same atomic-rename pattern. This is exactly Claude Code's native plan-mode iteration — the slash command does not need to drive it.

Locate the active `${SESSION_DIR}` on each refinement turn the same way `/duo-stop` and `/duo-abandon` do (find the `.duo-inflight` under the project's sessions root). One active session per project; if there's none, tell the operator to run `/duo-start` first.

Do **not** call `ExitPlanMode` during refinement. That's `/duo-stop`'s job.

---

## What this command does NOT do

- ❌ Call `ExitPlanMode` (that's `/duo-stop`).
- ❌ Dispatch Actor (that's `/duo-stop`).
- ❌ Write `.outcome` or run telemetry (that's `/duo-stop` or `/duo-abandon`).
- ❌ Spawn `claude -p` subprocesses or use `run-tier.sh`.
- ❌ Have a Phase 0 RESEARCH stage (use `/brain`).
- ❌ Have a Reviewer (use `/brain`).
- ❌ Auto-commit or auto-push.

$ARGUMENTS
