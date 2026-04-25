---
description: Run a task through the full Claude Orchestra pipeline (PLAN → IMPLEMENT → REVIEW, auto-loop cap 3). Heavyweight opt-in; use for tasks that warrant the pipeline structure, not for simple edits.
---

# /brain — run the Orchestra pipeline

You are about to run a task through the full Claude Orchestra pipeline. The user has invoked `/brain`, which is a heavyweight opt-in for tasks big enough to benefit from explicit planning + review.

## Prerequisites

1. **You must be in plan mode** so that `ExitPlanMode` can surface the plan for user approval. If you are not already in plan mode, ask the user to enter it (`Shift+Tab` cycle or `/permissions plan`) before you continue. Do not try to proceed without plan mode — the G2 gate depends on it.

## Pipeline (v1)

Execute these phases in order:

### Phase 1 — PLAN

Signal the pipeline is active by appending to `state.env` via `Bash`:
```bash
mkdir -p "${CLAUDE_PROJECT_DIR}/.claude/orchestra"
echo "ORCHESTRA_MODE=orchestra" >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"
```
This makes the status-line badge show `♪ orchestra` for the duration of the pipeline.

Delegate to the `planner` subagent via the Agent tool with a clear, self-contained prompt:

- The user's original request (summarized if long).
- Relevant context from this conversation (files already discussed, decisions already made).
- An explicit instruction to write `PLAN.md` to the project's orchestra directory using the atomic-rename pattern.

Wait for Planner's response. It will contain the plan text AND confirm persistence to `PLAN.md`.

### Phase 2 — G2 approval via ExitPlanMode

Read Planner's returned plan. If you need to amend it before surfacing (minor edits for clarity are fine; structural changes mean you should iterate with Planner, not rewrite silently), do so.

Call the **`ExitPlanMode`** tool with the plan content. This is the G2 approval gate. **Do not call `ExitPlanMode` yourself before delegating to Planner** — the canonical flow is Planner-first, then Brain surfaces.

If the user rejects the plan:
- Stay in plan mode.
- Ask for clarification, redirect, or abandon — user's call.
- If they redirect, re-run Phase 1 with the updated intent.
- Do not dispatch Actor on a rejected plan.

If the user approves, exit plan mode (the tool does this automatically on approval) and continue.

### Phase 3 — IMPLEMENT + REVIEW loop (auto-loop cap 3)

For each numbered step in the approved plan:

1. Delegate to the `actor` subagent with a prompt that contains:
   - The one step Actor is to do.
   - A reminder: "Stay in scope. Do NOT do other steps. Update TASKS.json via atomic-rename when done."
2. Receive Actor's status report.
3. If Actor reports `blocked`, surface to the user — do not auto-retry.
4. If Actor reports `ready_for_review`, delegate to the `reviewer` subagent with a prompt that contains:
   - Reference to PLAN.md and TASKS.json.
   - The specific step just completed.
5. Receive Reviewer's verdict:
   - **PASS** — move to the next step in the plan.
   - **FIX** — delegate to Actor again with Reviewer's issue list. Increment iteration counter for this step.
   - **BLOCK** — stop the loop for this step, surface to user.
6. Iteration cap: **3 fix loops per step**. On the 4th iteration request, stop and surface a summary to the user.

### Phase 4 — VERIFY / DONE

After all steps are PASS (or the user has resolved any blocks / caps manually):

1. **Consolidate state.** Read `${CLAUDE_PROJECT_DIR}/.claude/orchestra/TASKS.json` to confirm every task is `done` or explicitly accepted.

2. **Doc-delta check.** Run `git diff --stat HEAD` (or the staged-diff equivalent if changes aren't committed). For each non-doc file changed, ask: does this change make any statement in a project doc stale? Common targets:
   - `CLAUDE.md` (project instructions) — architectural or config changes
   - `TROUBLESHOOTING.md` — bug fixes that resolve documented issues
   - `README*.md` — user-facing behaviour changes
   - `*-strategy.md` — design-decision changes
   - Any doc named in CLAUDE.md's project-file inventory

   If Planner's plan already covered the necessary doc updates (i.e. they were numbered steps and Actor executed them), skip this check. Otherwise dispatch `actor` ONCE more with a prompt that:
   - Names the specific doc(s) and the specific change(s) needing reflection.
   - Reminds Actor to use atomic-rename and to reflect only WHAT actually changed — no speculation, no cleanup beyond the targeted doc.

   Treat this as one Actor invocation + one Reviewer pass (verdict PASS to finish; FIX loops still bounded by the cap-3 policy from Phase 3).

3. **Memory-worthy-fact check.** Review what was decided or learned during this pipeline. For each of the four memory types defined in the global CLAUDE.md (user / feedback / project / reference), ask: "does anything from this task warrant persisting so a future session benefits?" If yes, update the auto-memory under `~/.claude/projects/<encoded-pwd>/memory/` per the global rules (new memory file + `MEMORY.md` index entry, or an update to an existing file). **This is Brain's direct responsibility — do NOT delegate to Actor.** Memory files live in Claude-side state, not project state, and Actor is unaware of them by design.

4. **Final summary.** Produce a short report for the user:
   - Steps completed.
   - Files changed (include docs if updated in step 2).
   - Tests run, if any.
   - Memory entries created or updated, if any.
   - Anything the user should verify manually.

5. Restore the idle badge via `Bash`:
   ```bash
   echo "ORCHESTRA_MODE=default" >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"
   ```

6. **Do NOT commit, push, or open a PR.** v1 respects the global "never commit unless asked" rule unconditionally. If the user wants a commit, they will request it separately.

## Non-goals in v1

- No `auto` mode. If the user invoked `/orchestra-mode auto`, it is stubbed — ignore any such state and proceed in `default`/`acceptEdits` semantics.
- No CROSS-CHECK stage (v2).
- No checkpoint commits (v2, `auto` only).
- No branch isolation (v2, `auto` only).

## If the user said "just do it" or similar

They still want the pipeline; that's why they invoked `/brain`. Follow the phases. If they meant a one-shot small edit, politely remind them that `/brain` is for heavyweight tasks and suggest dropping the slash command for regular conversational delegation.

## Visibility

If the user is in tmux, subagent invocations will spawn `plan` / `implement` / `review` tmux windows automatically via the hook — no action needed from you.

If the user is in VSCode or a non-tmux terminal, tell them they can tail `${CLAUDE_PROJECT_DIR}/.claude/orchestra/invocations.log` in a separate terminal split for live visibility. Not required.

$ARGUMENTS
