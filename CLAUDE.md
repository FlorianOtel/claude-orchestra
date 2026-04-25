# Claude Orchestra — project instructions

This repo contains the orchestra source files. Claude Code running here uses
`~/.claude/` exclusively — there are no project-level agents or commands active
automatically. Deploying is an explicit, conscious step.

## Key workflows

```bash
./deploy.sh --global       # promote committed changes to ~/.claude/ (system-wide)
./deploy.sh --local        # deploy to this project only ($PWD/.claude/)
./collect.sh               # sync ~/.claude/ changes back to repo before committing
git add agents/ commands/ scripts/ config/ && git commit && git push
```

## Layout

- `agents/`   — planner (Sonnet 4.6), actor (Haiku 4.5), reviewer (Sonnet 4.6)
- `commands/` — /brain (full pipeline), /duo (lightweight), /orchestra-mode (preset)
- `scripts/orchestra-hook.sh` — PreToolUse / SubagentStop / PreCompact dispatcher
- `config/config.yaml` — global orchestra defaults
- `docs/design.md`    — full architecture reference

## Do not commit

- `.claude/` — entirely runtime (orchestra state, local-deploy artifacts); gitignored
