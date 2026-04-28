---
description: Launch a /brain pipeline — spawns a separate Opus 4.7 dialogue session for Phase 0 RESEARCH. Heavyweight opt-in. Use /brain-resume <slug> to continue after research is done.
---

# /brain — launch a pipeline run (Phase 0 dispatch only)

You are the **launcher** for a `/brain` pipeline. Your job is small and bounded:
spawn a Phase 0 RESEARCH dialogue session in a separate window/terminal, register
the run, print user-facing instructions, and exit. **The launcher does NOT do the
research dialogue itself, and does NOT orchestrate Phases 1-4** — those happen in
the spawned session and via `/brain-resume <slug>` respectively.

## When to use /brain vs /duo

| Situation | Use |
|---|---|
| Multi-step task warranting research dialogue + planning + review | `/brain` |
| Simple, well-scoped, ≤ 10 steps, low blast-radius | `/duo` |

`/duo` is the lightweight pipeline (no Phase 0, no Reviewer); use it when you don't
need the full interrogation+planning+review structure.

## Architecture (Option II.b + concurrent — see docs/design.md)

- **Launcher chat panel** (this session): spawns Phase 0, then is **freed**. You can
  use it for anything else, including a second `/brain` for a different task.
- **Spawned dialogue session** (separate tmux window or terminal split): interactive
  Claude on Opus 4.7 (regardless of launcher's model) with strict critical-stance
  system prompt. User has the research dialogue THERE.
- **Run registry** (`.claude/orchestra/runs.jsonl`): tracks all runs, their state,
  and ages. Multiple concurrent runs supported.
- **Per-run state subdir** (`.claude/orchestra/runs/<run_id>/`): RESEARCH.md, PLAN.md,
  TASKS.json, review-comments.md, logs.

## What you do (this entire skill, end to end)

1. **Validate `$ARGUMENTS`.** If empty, refuse: "Usage: `/brain <task>`. Provide a
   description of the task to research and plan." Stop.

2. **Spawn the dialogue session.** Run via `Bash`:
   ```bash
   OUTPUT=$(~/.claude/scripts/start-research.sh "$ARGUMENTS")
   echo "$OUTPUT"
   ```
   Parse the output (key=value pairs):
   - `RUN_ID=<run_id>` — always present
   - `MODE=tmux` or `MODE=manual` — environment branch
   - `WINDOW=<name>` — present when MODE=tmux
   - `LAUNCH_SCRIPT=<path>` — present when MODE=manual
   - `CLIPBOARD=<tool>` or `CLIPBOARD=no` — present when MODE=manual

3. **Compute slug from RUN_ID.** Slug is everything after the timestamp prefix:
   ```bash
   SLUG="${RUN_ID#*Z-}"
   ```

4. **Print user-facing instructions** based on MODE:

   ### If MODE=tmux

   ```
   ✓ Run started: <slug>
     run_id:      <run_id>
     model:       claude-opus-4-7
     window:      <window>  (in tmux)

   Switch to that tmux window now to begin the Phase 0 dialogue.
   When research concludes (the spawned session writes RESEARCH.md and exits),
   return here and run:

       /brain-resume <slug>

   To list all active /brain runs:    /brain-status
   To abandon this run:               /brain-abandon <slug>
   ```

   ### If MODE=manual (VSCode without tmux, or tmux failed)

   **If CLIPBOARD is not "no" (clipboard injection succeeded):**
   ```
   ✓ Run started: <slug>
     run_id:      <run_id>
     model:       claude-opus-4-7
     window:      manual launcher (no tmux)

   VSCode detected (or tmux unavailable). To start the Phase 0 dialogue:

   1. Open a terminal split (Ctrl+` in VSCode)
   2. Paste and press Enter (command already in clipboard)
      (or run manually: bash <LAUNCH_SCRIPT>)
   3. Have the research dialogue in that terminal
   4. When done, the spawned session writes RESEARCH.md and exits

   Then return here and run:

       /brain-resume <slug>

   Other commands:    /brain-status  /brain-abandon <slug>
   Keyboard shortcut: Ctrl+Shift+P → Tasks: Run Task → Start Brain Run
   ```

   **If CLIPBOARD is "no" (manual fallback):**
   ```
   ✓ Run started: <slug>
     run_id:      <run_id>
     model:       claude-opus-4-7
     window:      manual launcher (no tmux)

   VSCode detected (or tmux unavailable). To start the Phase 0 dialogue:

   1. Open a terminal split (Ctrl+` in VSCode)
   2. Run:    bash <LAUNCH_SCRIPT>
   3. Have the research dialogue in that terminal
   4. When done, the spawned session writes RESEARCH.md and exits

   Then return here and run:

       /brain-resume <slug>

   Other commands:    /brain-status  /brain-abandon <slug>
   Keyboard shortcut: Ctrl+Shift+P → Tasks: Run Task → Start Brain Run
   ```

5. **End your turn.** Do NOT enter a dialogue, do NOT do research yourself, do NOT
   wait for RESEARCH.md. The launcher's job is done. The user will:
   - Switch to the spawned window/terminal for Phase 0
   - Eventually return to this chat panel and run `/brain-resume <slug>`

## What this launcher does NOT do

- ❌ Run the research dialogue (that's the spawned session's job)
- ❌ Wait/poll for RESEARCH.md (the launcher session is freed)
- ❌ Dispatch Planner / Actor / Reviewer (that's `/brain-resume`)
- ❌ Call `ExitPlanMode` (that's `/brain-resume`)
- ❌ Track pipeline state across turns (the registry does that)

## Concurrency

This launcher can be invoked multiple times for different tasks. Each invocation
gets its own `run_id`, state subdir, and spawned window. The launcher chat panel
remains usable between invocations.

If multiple runs reach `research_complete` state, the user must specify which to
resume by slug — there is no "most recent" default. See `/brain-status` and
`/brain-resume`.

$ARGUMENTS
