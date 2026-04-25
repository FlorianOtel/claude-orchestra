---
description: Run a task through the full Claude Orchestra pipeline (PLAN → IMPLEMENT → REVIEW, auto-loop cap 3). Heavyweight opt-in; use for tasks that warrant the pipeline structure, not for simple edits.
---

# /brain — run the Orchestra pipeline

You are about to run a task through the full Claude Orchestra pipeline. The user has invoked `/brain`, which is a heavyweight opt-in for tasks big enough to benefit from explicit planning + review.

## Prerequisites

1. **You must be in plan mode** so that `ExitPlanMode` can surface the plan for user approval. If you are not already in plan mode, ask the user to enter it (`Shift+Tab` cycle or `/permissions plan`) before you continue. Do not try to proceed without plan mode — the G2 gate depends on it.

## Critical stance

Before delegating to Planner, Brain must interrogate the request. This is non-negotiable — do not skip it to be helpful.

**Push back on the request itself.** Ask: is this the right thing to do? Is the framing correct? Is there a simpler solution that doesn't need the full pipeline? If the request is vague, contradictory, or under-specified, stop and demand clarity. Do not interpret charitably when precision matters.

**Surface alternatives explicitly.** Whenever more than one reasonable approach exists — different architectures, different scopes, different trade-offs — do not silently pick one. Present them as a structured comparison:
- Name each alternative.
- State the concrete pros and cons of each (not vague, not one-sided).
- Explain the key trade-off in plain terms.
- State which you recommend and why — but make the user's choice explicit before proceeding.

Do not proceed to Planner until the approach is unambiguous and agreed.

**Force clarity at every gap.** If any of the following are unclear, stop and ask:
- What the definition of "done" looks like
- Which files, systems, or interfaces are in scope vs out of scope
- Whether existing code should be reused or replaced
- Whether tests are expected, and which framework
- Whether this affects any documented behaviour, APIs, or contracts

**Be sceptical of the plan Planner returns.** Brain's role is not rubber-stamping. If Planner's plan:
- Misses a risk flagged in the original request
- Includes steps that seem over-engineered or under-engineered
- Makes a silent choice where an explicit decision was needed
- Fails to match the agreed-upon approach

…then iterate with Planner rather than surfacing a bad plan to the user.

## Pipeline (v1)

Execute these phases in order:

### Phase 1 — PLAN

Signal the pipeline is active by appending to `state.env` via `Bash`:
```bash
mkdir -p "${CLAUDE_PROJECT_DIR}/.claude/orchestra"
echo "ORCHESTRA_MODE=orchestra" >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"
```
This makes the status-line badge show `♪ orchestra` for the duration of the pipeline.

Dispatch the Planner as a `claude -p` subprocess via `~/.claude/scripts/run-tier.sh`. The
subprocess runs in its own tmux window (or VSCode users tail `live.log`) showing the full
live feed — thinking, prose, tool calls, and tool results — as the Planner works.

**Critical: prompts must be fully self-contained.** The subprocess has NO access to this
conversation's history. Include explicitly:
- The user's original request (full text, not summarised)
- Files / decisions already discussed in this conversation
- An explicit instruction to write `PLAN.md` to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/PLAN.md` via atomic-rename
- An explicit instruction to return the plan text as the final response

Dispatch via `Bash`:
```bash
PROMPT_FILE=$(mktemp /tmp/planner-prompt.XXXXXX)
cat > "$PROMPT_FILE" <<'EOF'
[user's full request]

[any conversation context Planner needs]

Write PLAN.md to ${CLAUDE_PROJECT_DIR}/.claude/orchestra/PLAN.md using atomic-rename
(write to PLAN.md.tmp first, then `mv -f` to PLAN.md). Return the plan text as your
final response.
EOF

RESULT_FILE=$(~/.claude/scripts/run-tier.sh plan claude-sonnet-4-6 planner default \
  "$PROMPT_FILE" --allowedTools "Read,Grep,Glob,WebFetch,Bash,Write,TodoWrite")

# Block until subprocess writes its result (poll, max ~10 min).
for i in $(seq 1 300); do
  [ -s "$RESULT_FILE" ] && break
  sleep 2
done
PLANNER_RESPONSE=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE" "$PROMPT_FILE"
```

The Planner runs on `claude-sonnet-4-6` with permission mode `default` (Planner is read-only
+ writes only PLAN.md). After completion, read PLAN.md from disk and use `$PLANNER_RESPONSE`
for the plan text in Phase 2.

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

Both Actor and Reviewer run as `claude -p` subprocesses via `run-tier.sh` — same self-
contained-prompt rule as Phase 1. Each gets its own tmux window (`implement`, `review`)
or appears sequentially in `live.log` for VSCode users.

For each numbered step in the approved plan:

1. Dispatch the Actor via `run-tier.sh`:
   ```bash
   PROMPT_FILE=$(mktemp /tmp/actor-prompt.XXXXXX)
   cat > "$PROMPT_FILE" <<EOF
   You are executing step N from PLAN.md. The step is:

   [text of the single step]

   Read PLAN.md and TASKS.json from \${CLAUDE_PROJECT_DIR}/.claude/orchestra/ for context.
   Stay in scope. Do NOT do other steps. Update TASKS.json via atomic-rename when done.
   Return one of: "ready_for_review" / "blocked: <reason>" / "partial: <details>".
   EOF

   RESULT_FILE=$(~/.claude/scripts/run-tier.sh implement claude-haiku-4-5-20251001 actor \
     bypassPermissions "$PROMPT_FILE" \
     --allowedTools "Read,Edit,Write,Bash,Grep,Glob,TodoWrite")

   for i in $(seq 1 300); do [ -s "$RESULT_FILE" ] && break; sleep 2; done
   ACTOR_STATUS=$(cat "$RESULT_FILE")
   rm -f "$RESULT_FILE" "$PROMPT_FILE"
   ```
   Model: `claude-haiku-4-5-20251001`. Perm-mode: `bypassPermissions` (Actor runs uninterrupted).

2. Inspect `$ACTOR_STATUS`.
3. If status starts with `blocked`, surface to the user — do not auto-retry.
4. If `ready_for_review`, dispatch the Reviewer:
   ```bash
   PROMPT_FILE=$(mktemp /tmp/reviewer-prompt.XXXXXX)
   cat > "$PROMPT_FILE" <<EOF
   Review the work just done by Actor for step N.

   PLAN.md and TASKS.json are at \${CLAUDE_PROJECT_DIR}/.claude/orchestra/. The step Actor
   just completed:

   [text of the step]

   Compare the actual change (run \`git diff\` or read the affected files) against PLAN.md
   and TASKS.json. Write review-comments.md via atomic-rename. Return verdict on its own
   line as "PASS", "FIX: <issues>", or "BLOCK: <reason>".
   EOF

   RESULT_FILE=$(~/.claude/scripts/run-tier.sh review claude-sonnet-4-6 reviewer default \
     "$PROMPT_FILE" --allowedTools "Read,Grep,Glob,Bash,Write,TodoWrite")

   for i in $(seq 1 300); do [ -s "$RESULT_FILE" ] && break; sleep 2; done
   REVIEW_VERDICT=$(cat "$RESULT_FILE")
   rm -f "$RESULT_FILE" "$PROMPT_FILE"
   ```
   Model: `claude-sonnet-4-6`. Perm-mode: `default`.

5. Parse `$REVIEW_VERDICT`:
   - **PASS** — move to the next step in the plan.
   - **FIX** — re-dispatch Actor with the issue list as the new step description; increment iteration counter.
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

   If Planner's plan already covered the necessary doc updates (i.e. they were numbered steps and Actor executed them), skip this check. Otherwise dispatch the Actor ONCE more (via `run-tier.sh`, same pattern as Phase 3) with a prompt that:
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

If the user is in tmux, subagent invocations will spawn `plan` / `implement` / `review` tmux windows automatically via the hook — each window shows tool calls in real time as the subagent runs. No action needed from you.

If the user is in VSCode or a non-tmux terminal, tell them to open a terminal split and run:
```
tail -f "${CLAUDE_PROJECT_DIR}/.claude/orchestra/live.log"
```
This symlink always points to the most recently started subagent's logfile and shows live tool-call lines as they execute. It persists across pipeline stages without needing to be restarted.

$ARGUMENTS
