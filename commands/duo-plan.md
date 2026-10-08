---
description: Open a /duo planning session — sets up artifacts, drafts initial PLAN.md, and yields back for multi-turn refinement. This is the start of a planning discussion. Run /duo-act to commit and execute, or /duo-abandon to cancel.
---

# /duo-plan — open a planning session

You are running the **duo** pipeline. `/duo-plan` opens a multi-turn planning session: it does setup, drafts an initial `PLAN.md`, and **yields control back** to the operator for refinement. ExitPlanMode is **not** called here; refinement happens across subsequent normal plan-mode turns until the operator runs `/duo-act` (commit + execute) or `/duo-abandon` (cancel).

There is no Phase 0 RESEARCH (use `/brain` if you need formal interrogation). There is no Reviewer.

> **PLAN-MODE OVERRIDE — run setup bash immediately**: The refusal check and session setup bash calls below are /duo lifecycle management, not project-code edits. They MUST be executed at the start of this response, before any exploration. The plan-mode "MUST NOT run non-readonly tools" constraint does NOT apply to them. Skipping them means `.duo-inflight` is never written, /duo mode never activates, and no badge appears.

Use `/duo` when the task is simple enough that a plan + execute is sufficient, and you don't need a review loop.

## When to use /duo vs /brain

| Situation | Use |
|---|---|
| Simple, well-scoped, ≤ 10 steps, low blast-radius | `/duo` |
| Multi-file refactor, architecture change, anything where review matters | `/brain` |

## Cost note

`/duo` is designed to run from a **Sonnet 5 session** for the planning phase. Switch with `/model claude-sonnet-5` before invoking if you're currently on Opus. The Actor subagent is pinned to Haiku 4.5 by frontmatter regardless of parent model.

## Prerequisites

1. **Plan mode is active.** If not, stop and say:
   > "Please enter plan mode first (Shift+Tab), then run `/duo-plan` again."
2. **Model check (advisory):** Read "The exact model ID is…" from your system context.
   - If on `claude-sonnet-5` or higher (including any Opus): proceed silently.
   - If on any other model, note it to the operator before continuing:
     > "⚠️ /duo recommends Sonnet 5 for planning. You are on [MODEL-ID]. Switch with `/model claude-sonnet-5` if desired — proceeding anyway."
3. **Bypass-flattens-down caveat.** Same as `/brain`: if the operator launched the parent with `--dangerously-skip-permissions`, Actor inherits bypass and the Plan-Then-Execute gate is decorative.

## Setup — refusal check, session directory, markers (one script call)

Run **exactly this one command** via `Bash` — verbatim, as a single call. Do **not** inline,
shorten, reorder or re-implement the script's steps yourself: a previous session did, dropped
the transcript-UUID step, and the status-line badge never appeared.

Replace `<task description>` with the operator's task text (the script strips single-quotes and
truncates the title itself; if the text contains a single-quote, wrap it as `'...'\''...'`).

```bash
bash "$HOME/.claude/scripts/session-setup.sh" duo '<task description>'
```

The script enforces one active /duo session per project, creates the session dir, writes
`.transcript-uuid` and `.duo-inflight`, registers the `.lck`, and verifies all of them. Act on
the first line of its output:

- `REFUSE:` — an active /duo session exists. **Stop now**: do not draft a plan; tell the operator the printed session path and that they must run `/duo-act` or `/duo-abandon` first.
- `SETUP_FAILED:` — **stop now**; report the message verbatim. Do not attempt to repair or hand-write the markers.
- `SETUP_OK` — proceed. Capture the `session_dir=...` line: use that literal path for `${SESSION_DIR}/PLAN.md` writes in this turn and every refinement turn. Do not rely on `${CLAUDE_ORCHESTRA_SESSION_DIR}`; it is not set in later bash subprocesses.

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
> - Run `/duo-act` to commit the plan, exit plan mode, and dispatch Actor.
> - Run `/duo-abandon` to cancel this session and clear the badge.

Stop here. The next operator turn will be either a refinement message, `/duo-act`, or `/duo-abandon`.

---

## Refinement turns (no slash command)

These happen between `/duo-plan` and `/duo-act`/`/duo-abandon`. The operator types feedback; you re-read `${SESSION_DIR}/PLAN.md`, integrate the feedback, and rewrite it via the same atomic-rename pattern. This is exactly Claude Code's native plan-mode iteration — the slash command does not need to drive it.

At the start of each refinement turn, locate the active session by running:

```bash
CLAUDE_PROJECT_DIR="$(realpath "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$(pwd)}")"
SESSIONS_ROOT="${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions"
ACTIVE_INFLIGHT="$(find "$SESSIONS_ROOT" -mindepth 2 -maxdepth 2 -name '.duo-inflight' 2>/dev/null | head -1)"
if [ -z "$ACTIVE_INFLIGHT" ]; then
  echo "NO_SESSION: no active /duo session — run /duo-plan first."
  exit 0
fi
SESSION_DIR="$(dirname "$ACTIVE_INFLIGHT")"
echo "session_dir=${SESSION_DIR}"
```

If the output starts with `NO_SESSION:`, tell the operator there is no active session and stop. Otherwise, use the captured `session_dir=...` value as the literal path for reading and rewriting `PLAN.md`.

Do **not** call `ExitPlanMode` during refinement. That's `/duo-act`'s job.

---

## What this command does NOT do

- ❌ Call `ExitPlanMode` (that's `/duo-act`).
- ❌ Dispatch Actor (that's `/duo-act`).
- ❌ Write `.outcome` or run telemetry (that's `/duo-act` or `/duo-abandon`).
- ❌ Spawn `claude -p` subprocesses or use `run-tier.sh`.
- ❌ Have a Phase 0 RESEARCH stage (use `/brain`).
- ❌ Have a Reviewer (use `/brain`).
- ❌ Auto-commit or auto-push.

$ARGUMENTS
