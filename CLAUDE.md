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
- **Timestamp:** 2026-04-30T16:55:50Z
- **Model:** claude-sonnet-4-6
- **Reason:** /duo telemetry end-to-end smoke test — session 20260430T165550Z-1501376, cost=$0.2744, 3/3 checks passed (T1 timing-only/usage=null expected; T2 authoritative)

## Telemetry Smoke Tests

Verify T1 (hook events) and T2 (transcript parse) after any /duo or /brain run.

### /duo smoke test
1. In plan mode, run: `/duo add a comment line "# telemetry-smoke-test-<date>" to scripts/telemetry-report.sh`
2. Approve and let Actor run.
3. After Phase 4 cleanup completes, run: `./scripts/smoke-test.sh`
4. Expected: T1 has ≥2 events (actor start + end), T2 cost > $0, subagents list contains "actor".

### /brain smoke test
1. In plan mode, run: `/brain add a comment line "# telemetry-smoke-test-<date>" to scripts/telemetry-report.sh`
2. Go through Phase 0 interrogation, approve plan, let pipeline run.
3. After cleanup, run: `./scripts/smoke-test.sh`
4. Expected: T1 has events for planner+actor+reviewer, T2 cost > $0, subagents list contains "planner", "actor", "reviewer". If parser_warnings mentions "T1 usage=null", that is expected (T1 is timing-only; T2 is authoritative).

### Reading the global log
```bash
~/.claude/scripts/telemetry-report.sh --last 5
```
