# Claude Orchestra — project instructions

This repo contains the orchestra source files. Claude Code running here uses
`~/.claude/` exclusively — there are no project-level agents or commands active
automatically. Deploying is an explicit, conscious step.

## Key workflows

```bash
./deploy.sh          # deploy to ~/.claude/ (system-wide, all machines via NFS)
./collect.sh         # sync ~/.claude/ changes back to repo before committing
git add agents/ commands/ scripts/ config/ && git commit && git push
```

## Layout

- `agents/`   — planner (Sonnet 4.6), actor (Haiku 4.5), reviewer (Sonnet 4.6)
- `commands/` — /brain (full pipeline: Phase 0 inline + 3 subagents), /duo (lightweight: Planner + Actor)
- `scripts/orchestra-hook.sh` — PreToolUse / SubagentStop / PreCompact dispatcher
- `config/config.yaml` — global orchestra defaults
- `docs/design.md`    — full architecture reference

## Do not commit

- `.claude/` — entirely runtime (orchestra state, local-deploy artifacts); gitignored

## Smoke test

- **Timestamp:** 2026-04-28T14:24:09Z
- **Model:** claude-haiku-4-5-20251001
- **Reason:** Subagents smoke test — verifies that /duo can dispatch Actor as a Haiku subprocess
- **Timestamp:** 2026-04-28T14:49:27Z
- **Model:** claude-sonnet-4-6
- **Reason:** smoke 2 from subagents branch
- **Timestamp:** 2026-04-28T14:52:58Z
- **Model:** claude-sonnet-4-6
- **Reason:** smoke 3 from /brain — via brain pipeline
