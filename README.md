# Claude Orchestra

A three-tier orchestration layer for [Claude Code](https://claude.ai/code) that routes tasks across model tiers by complexity, adds a structured PLAN → IMPLEMENT → REVIEW pipeline, and provides live visibility into each tier's work via tmux windows. Designed to be as idiomatic as possible and work identically in both terminal (tmux) and VSCode Claude Code extension environments.

## Model tiers

| Tier | Model | Role |
|---|---|---|
| **Brain** | Claude Opus 4.7 | Your main session — orchestrates, delegates, approves |
| **Planner** | Claude Sonnet 4.6 | Decomposes tasks into numbered, reviewable plans |
| **Actor** | Claude Haiku 4.5 | Executes individual plan steps; scoped, fast, cheap |
| **Reviewer** | Claude Sonnet 4.6 | Reviews Actor's output; emits PASS / FIX / BLOCK verdicts |

## Pipelines

Two invocation styles depending on how much structure the task warrants:

### `/brain` — full pipeline

```
PLAN → [G2 approval] → IMPLEMENT + REVIEW loop (cap 3) → VERIFY + doc/memory update
```

Planner (Sonnet) drafts a numbered plan; Brain surfaces it for your approval via `ExitPlanMode`; Actor (Haiku) executes each step; Reviewer (Sonnet) reviews each step with up to 3 fix iterations; Brain does a doc-delta check and memory update on completion.

Use for: multi-file refactors, architecture changes, anything where a review loop matters.

### `/duo` — lightweight pipeline

```
Interactive plan (Sonnet) → [G2 approval] → Execute all steps (Haiku, auto)
```

You and Sonnet refine the plan interactively across as many turns as needed; Haiku executes all approved steps automatically in a single Actor invocation. No review tier, no loop.

Use for: simple, well-scoped tasks (≤ 10 steps) where the plan is clear enough to trust unreviewed execution.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured
- `jq` (for the deploy script and hook JSON parsing)
- `tmux` (optional — for per-stage windows; falls back to logfile-only without it)
- `bash` 5+

## Install

```bash
git clone https://github.com/FlorianOtel/claude-orchestra
cd claude-orchestra
./deploy.sh --global
```

`deploy.sh` requires an explicit target argument and is idempotent — safe to re-run after any update.

```bash
./deploy.sh --global              # install / update system-wide (~/.claude/)
./deploy.sh --local               # deploy to current project only ($PWD/.claude/)
./deploy.sh --global --dry-run    # preview without writing
./deploy.sh --local  --diff       # show unified diff for local deploy
```

`--global` and `--local` are mutually exclusive. `--dry-run` and `--diff` are additive.

**`--global`** installs everything and:

1. Copies `.claude/agents/`, `.claude/commands/`, `scripts/`, and `config/` to `~/.claude/`
2. Merges orchestra hooks (`PreToolUse → Agent`, `SubagentStop`, `PreCompact`) into `~/.claude/settings.json` without touching existing entries
3. Patches `~/.claude/scripts/status-line.sh` to add orchestra state indicators (if you have one; skipped otherwise)
4. Adds `.claude/orchestra/` to your global gitignore so auto-created runtime state is never accidentally committed

**`--local`** deploys agents, commands, scripts, and config to `$PWD/.claude/` of the current project. Skips settings.json hooks, status-line patch, and gitignore setup (those are global-only). Use this to test a change in a specific project without touching `~/.claude/`:

```bash
cd /path/to/my-project
/path/to/claude-orchestra/deploy.sh --local
```

When Claude Code is launched inside a project that has been locally deployed, its `.claude/agents/` and `.claude/commands/` take precedence over the system-wide `~/.claude/` versions — giving you isolated testing without affecting any other project.

## Development workflow (dogfooding)

Source files live in `agents/` and `commands/` at the repo root. Claude Code running
in this directory has **no** project-level agents or commands — it uses `~/.claude/`
exclusively. Deploying to the local project is a conscious, explicit step, not automatic.

```
repo (agents/, commands/)   ← edit source here
        │
        │  ./deploy.sh --local   (explicit: deploy to this project for testing)
        │  ./deploy.sh --global  (explicit: promote to ~/.claude/ system-wide)
        ▼
target/.claude/  (agents, commands, hook, config)
```

```bash
# Typical development cycle:
# 1. Edit agents/planner.md, commands/brain.md, etc. in the repo
# 2. Commit
git add agents/ commands/ && git commit -m "..."
# 3. Deploy — choose scope deliberately:
./deploy.sh --local   # test in this project only ($PWD/.claude/)
./deploy.sh --global  # promote system-wide (~/.claude/)
# 4. Push
git push
```

**No silent shadowing.** Working in this repo does not activate any dev version of
the orchestra automatically. Changes only take effect after an explicit deploy.

## Usage

```
# 1. Enter plan mode (required for G2 approval gate)
Shift+Tab   (or /plan-mode in Claude Code)

# 2. Choose a pipeline
/brain implement the X feature         — full pipeline
/duo   add a docstring to function Y   — lightweight
```

Orchestra is globally on once installed — no per-project setup needed. Each project's runtime state (PLAN.md, TASKS.json, logs) is written to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/` and is globally gitignored.

## Status line

If you use a custom `status-line.sh`, `deploy.sh` appends orchestra indicators automatically. If you don't, the block is available standalone at `status-line/orchestra-block.sh`.

Status line shows (when orchestra is installed):

```
✦ Opus 4.7 | [bar] 10% | ↯ 100k/1000k | ◆ MyProject | ⎇ main | ♪ default
                                                                  ▲
                                                          orchestra badge

♪ duo ▶ Haiku:implement          — Haiku Actor is currently running
♪ brain ⚠ >200K                  — Brain context too large to delegate safely
```

## Updating

After iterating on files directly in `~/.claude/`:

```bash
cd claude-orchestra
./collect.sh        # sync live files back to repo
git diff            # review
git add -p          # stage selectively
git commit -m '...'
git push
```

After pulling new changes from the repo:

```bash
./deploy.sh         # apply to ~/.claude/
```

## Cross-machine deployment

If `~/.claude/` is shared across machines (e.g. via an NFS-mounted home directory or a symlinked dotfiles store), installed files are immediately available everywhere with no further action. On any machine where `~/.claude/` is local, run `./deploy.sh` to install from the repo.

## Files

`.claude/` is entirely runtime (gitignored). Source files live at the repo root
and are deployed explicitly — no automatic shadowing.

```
claude-orchestra/
├── agents/
│   ├── planner.md         Sonnet 4.6 — writes numbered plan to PLAN.md
│   ├── actor.md           Haiku 4.5  — executes one scoped step
│   └── reviewer.md        Sonnet 4.6 — reviews diff, emits PASS/FIX/BLOCK
├── commands/
│   ├── brain.md           /brain slash command — full pipeline
│   ├── duo.md             /duo slash command   — lightweight pipeline
│   └── orchestra-mode.md  /orchestra-mode      — set autonomy preset (v1 stub for auto)
├── scripts/
│   └── orchestra-hook.sh      PreToolUse / SubagentStop / PreCompact hook dispatcher
├── status-line/
│   └── orchestra-block.sh     Orchestra additions for status-line.sh
├── config/
│   ├── config.yaml            Global orchestra configuration
│   └── settings-hooks.json    Hook entries to merge into settings.json
├── docs/
│   ├── design.md              Full design reference (architecture, decisions, TO DOs)
│   └── design-history.md      Design session notes and change log
├── deploy.sh                  Install / update (--global or --local)
└── collect.sh                 Sync changes from ~/.claude/ back to repo
```

## Architecture

Full architecture, gate policy (G1–G7), autonomy presets (`default` / `acceptEdits` / `auto`), NFS/cross-machine concurrency notes, tmux window naming, and v2 auto-mode spec are in [docs/design.md](docs/design.md).

## v2 roadmap

`/brain --mode auto` (fully unattended PLAN → IMPLEMENT → REVIEW → CROSS-CHECK → FINALIZE) is documented but not yet implemented. See the TO DO section at the end of [docs/design.md](docs/design.md) for the 10 design decisions that need to be resolved before building it.
