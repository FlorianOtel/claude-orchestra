---
description: Lightweight Plan (Sonnet 4.6, interactive) → Act (Haiku 4.5, auto) pipeline. No review tier, no Opus Brain. For simple, well-scoped tasks where unreviewed direct execution is acceptable.
---

# /duo — Sonnet plans interactively, Haiku acts automatically

You are running the **duo pipeline**: you (Sonnet 4.6) plan interactively with the user; Haiku 4.5 executes automatically without permission prompts. There is no Reviewer, no review loop, no CROSS-CHECK stage. Use this for well-scoped tasks where the plan is clear enough to trust Haiku to execute unsupervised.

## Cost note

Duo is designed to run from a **Sonnet 4.6 session** to keep the planning phase cheap. If you are running as Opus 4.7, the pipeline still works but the planning tokens cost Opus rates. For the intended cost profile, start from:
```
claude --model claude-sonnet-4-5
```
or switch with `/model claude-sonnet-4-5` before typing `/duo`.

## When to use /duo vs /brain

| Situation | Use |
|---|---|
| Simple, well-scoped, ≤ 10 steps, low blast-radius | `/duo` |
| Multi-file refactor, architecture change, or anything where a review loop matters | `/brain` |
| Overnight / unattended run with test gate and branch isolation | `/brain --mode auto` (v2, not yet implemented) |

## Prerequisites

**Plan mode must be active.** The G2 gate requires it. If you are not in plan mode, tell the user:
> "Please enter plan mode first (Shift+Tab or `/plan-mode`), then run `/duo` again."

## Phase 1 — Interactive plan

Signal the pipeline is active by appending to `state.env` via `Bash`:
```bash
mkdir -p "${CLAUDE_PROJECT_DIR}/.claude/orchestra"
echo "ORCHESTRA_MODE=duo" >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"
```
This makes the status-line badge show `♪ duo` while the pipeline runs.

Work with the user interactively to crystallise the plan. Read files, explore the codebase, ask questions, propose alternatives. The user can push back, redirect, or narrow scope across as many turns as needed — this is the "interactive" part.

When the plan is agreed, write it with this structure:

1. **Intent** — one line: what will be true when done.
2. **Steps** — numbered, imperative, each executable by Actor as a single edit or shell command.
3. **Expected outcome per step** — one line each.
4. **Doc impact** — which project docs (CLAUDE.md, README, TROUBLESHOOTING.md, etc.) need updating; include as numbered steps if any.
5. **Risks / unknowns** — anything you couldn't verify by reading.
6. **Out of scope** — the hard fence Actor must not cross.

**Keep it tight:** if more than ~10 steps, recommend `/brain` instead.

Persist PLAN.md via atomic-rename:
1. Write full plan text to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/PLAN.md.tmp`.
2. `Bash`: `mv -f "${CLAUDE_PROJECT_DIR}/.claude/orchestra/PLAN.md.tmp" "${CLAUDE_PROJECT_DIR}/.claude/orchestra/PLAN.md"`.

## Phase 2 — G2 approval

Call **ExitPlanMode** with the plan content. You are the only caller — do not call it before the plan is fully agreed.

On rejection: stay in plan mode, refine, repeat Phase 1.

## Phase 3 — Execute (Haiku, auto)

On approval, dispatch the Actor as a `claude -p` subprocess via `~/.claude/scripts/run-tier.sh`.
This runs Actor on Haiku 4.5 with `bypassPermissions` set explicitly — no `Shift+Tab` needed,
the model and permission mode are set per-subprocess. The `implement` tmux window (or
`tail -f .claude/orchestra/live.log` for VSCode users) shows the full live feed: thinking,
prose, tool calls with arguments, and tool results.

```bash
PROMPT_FILE=$(mktemp /tmp/actor-prompt.XXXXXX)
cat > "$PROMPT_FILE" <<'EOF'
[full plan text from above]

Execute all steps sequentially. Stay in scope per the plan's "Out of scope" section.
Hard-deny rules apply: no `rm -rf`, no `git push`, no commits.
Update ${CLAUDE_PROJECT_DIR}/.claude/orchestra/TASKS.json via atomic-rename as steps complete.
Return one of: "ready_for_review", "blocked: <reason>", or "partial: <details>".
EOF

RESULT_FILE=$(~/.claude/scripts/run-tier.sh implement claude-haiku-4-5-20251001 actor \
  bypassPermissions "$PROMPT_FILE" \
  --allowedTools "Read,Edit,Write,Bash,Grep,Glob,TodoWrite")

for i in $(seq 1 300); do [ -s "$RESULT_FILE" ] && break; sleep 2; done
ACTOR_STATUS=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE" "$PROMPT_FILE"
```

If Actor reports `blocked` on any step, surface that to the user and stop — do not auto-retry.

## Phase 4 — Done

Short summary:
- Files changed.
- Tests run, if Actor chose to run them.
- Memory-worthy facts from this task (Brain writes to `~/.claude/projects/<encoded-pwd>/memory/` directly if any decisions were made that future sessions should know).
- Anything the user should verify manually.

Restore the idle badge via `Bash`:
```bash
echo "ORCHESTRA_MODE=default" >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"
```

**Do NOT commit, push, or open a PR** unless explicitly asked.

$ARGUMENTS
