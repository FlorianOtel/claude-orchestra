# Claude Orchestra — project instructions

This repo IS the orchestra. When Claude Code runs here, `.claude/agents/` and `.claude/commands/` are picked up automatically — no deploy needed to test agent/command changes.

## Key workflows

```bash
./deploy.sh --global       # promote committed changes to ~/.claude/ (system-wide)
./deploy.sh --local        # self-check: agents/commands always unchanged (source=dest)
./collect.sh               # sync ~/.claude/ changes back into repo before committing
git add .claude/ && git commit && git push   # version and publish
```

## Layout

- `.claude/agents/`   — planner (Sonnet 4.6), actor (Haiku 4.5), reviewer (Sonnet 4.6)
- `.claude/commands/` — /brain (full pipeline), /duo (lightweight), /orchestra-mode (preset)
- `scripts/orchestra-hook.sh` — PreToolUse / SubagentStop / PreCompact dispatcher
- `config/config.yaml` — global orchestra defaults
- `docs/design.md`    — full architecture reference

## Do not commit

- `.claude/orchestra/` — runtime state (PLAN.md, TASKS.json, logs, state.env)
- `.claude/scripts/`  — local-deploy copy of orchestra-hook.sh (source is `scripts/`)

## Deploy model

`deploy.sh` requires `--global` or `--local`. Global deploys to `~/.claude/` (NFS-shared across all machines). Local deploys to `$PWD/.claude/` of any target project for isolated testing.
