---
description: Resume a /brain run after Phase 0 RESEARCH is complete. Reads RESEARCH.md from the run's state subdir, dispatches Planner → Actor + Reviewer loop → Phase 4 summary. Requires explicit slug or unique prefix.
---

# /brain-resume — continue a /brain run from Phase 1

Argument is the run **slug** (or any unambiguous prefix). Mandatory.

If `$ARGUMENTS` is empty, refuse: "Specify a slug. See `/brain-status` for active
runs awaiting resume."

If `$ARGUMENTS` doesn't match exactly one slug by prefix, refuse with the list of
candidates from `runs-registry.sh resolve`.

## Resolve and validate

1. Resolve:
   ```bash
   RUN_ID=$(~/.claude/scripts/runs-registry.sh resolve "$ARGUMENTS")
   ```
2. Verify state is `research_complete`:
   ```bash
   STATE=$(~/.claude/scripts/runs-registry.sh latest-state "$RUN_ID")
   ```
   - If `research_complete`: proceed.
   - If `start`: research dialogue not finished. Tell user to either complete it in
     the spawned window/terminal or `/brain-abandon` it. Stop.
   - If anything else (`plan_dispatched`, `done`, `abandoned`, etc.): inform user
     of current state. Stop.

3. Verify `RESEARCH.md` exists at `${PROJECT_DIR}/.claude/orchestra/runs/${RUN_ID}/RESEARCH.md`.
   If missing: surface error, suggest `/brain-abandon ${SLUG}` and starting fresh.

## Pipeline (v1, post-Phase-0)

Execute Phases 1 through 4, parameterised on `RUN_ID`. The per-run state subdir is
`${PROJECT_DIR}/.claude/orchestra/runs/${RUN_ID}/` — referred to as `${RUN_DIR}`
below.

### Phase 1 — PLAN

Append `plan_dispatched` event to registry:
```bash
~/.claude/scripts/runs-registry.sh transition "$RUN_ID" "plan_dispatched"
```

Dispatch Planner via `run-tier.sh` with `--run-id`. Build a self-contained prompt
that includes RESEARCH.md so Planner respects the agreed approach:

```bash
PROMPT_FILE=$(mktemp /tmp/planner-prompt.XXXXXX)
RUN_DIR="${CLAUDE_PROJECT_DIR}/.claude/orchestra/runs/${RUN_ID}"
RESEARCH_CONTENT=$(cat "${RUN_DIR}/RESEARCH.md")
cat > "$PROMPT_FILE" <<EOF
# Phase 0 RESEARCH conclusions (treat as the agreed approach; do not re-litigate)

${RESEARCH_CONTENT}

# Your task
Produce a numbered plan that EXECUTES the approach decided above. If you find the
agreed approach technically unsound, return a 'plan rejected: <reason>' string.

Write PLAN.md to ${RUN_DIR}/PLAN.md via atomic-rename (PLAN.md.tmp first, then mv -f).
Return the plan text as your final response.
EOF

RESULT_FILE=$(~/.claude/scripts/run-tier.sh plan claude-sonnet-4-6 planner default \
  "$PROMPT_FILE" --run-id "$RUN_ID" \
  --allowedTools "Read,Grep,Glob,WebFetch,Bash,Write,TodoWrite")

for i in $(seq 1 300); do [ -s "$RESULT_FILE" ] && break; sleep 2; done
PLANNER_RESPONSE=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE" "$PROMPT_FILE"
```

If `$PLANNER_RESPONSE` starts with `plan rejected:`, surface that to the user and
stop. The user can re-open Phase 0 by `/brain <new task formulation>`.

### Phase 2 — G2 approval via ExitPlanMode

Read `${RUN_DIR}/PLAN.md` and call `ExitPlanMode` with its content. Same rules as
the original brain.md: do not call `ExitPlanMode` before Planner returns; iterate
with Planner if the plan misses something.

If user rejects: stay in plan mode, refine, re-run Phase 1 (re-dispatch Planner with
revised prompt). Do not dispatch Actor on a rejected plan.

### Phase 3 — IMPLEMENT + REVIEW loop (auto-loop cap 3)

Same as the previous brain.md but parameterised on `RUN_ID`. For each step:

1. Dispatch Actor via `run-tier.sh implement claude-haiku-4-5-20251001 actor
   bypassPermissions <prompt> --run-id "$RUN_ID" --allowedTools "Read,Edit,Write,Bash,Grep,Glob,TodoWrite"`.
   Prompt includes the single step + reference to `${RUN_DIR}/PLAN.md` and
   `${RUN_DIR}/TASKS.json`.

2. Receive Actor's status. If `blocked`, surface and stop.

3. If `ready_for_review`, dispatch Reviewer via `run-tier.sh review
   claude-sonnet-4-6 reviewer default <prompt> --run-id "$RUN_ID" --allowedTools "Read,Grep,Glob,Bash,Write,TodoWrite"`.

4. Reviewer verdict:
   - `PASS` — next step
   - `FIX` — re-dispatch Actor with the issue list, increment iteration counter
   - `BLOCK` — surface, stop

5. Cap: 3 fix loops per step.

### Phase 4 — VERIFY / DONE

1. Read `${RUN_DIR}/TASKS.json`; confirm all done.
2. Doc-delta check on the actual file diff.
3. Memory-worthy-fact check.
4. Final summary in chat panel.
5. Append `done` event:
   ```bash
   ~/.claude/scripts/runs-registry.sh transition "$RUN_ID" "done"
   ```
6. **Do NOT commit, push, or open a PR.**

## Critical posture (preserved from old brain.md Critical stance)

Brain in the launcher chat panel is sceptical of Planner's output. If the plan misses
a risk flagged in RESEARCH.md, makes silent choices, or doesn't match the agreed
approach — iterate with Planner before surfacing.

$ARGUMENTS
