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
- `commands/` — /brain (full pipeline: Phase 0 inline + 3 subagents) + /brain-abandon (explicit cancel); /duo-plan, /duo-act, /duo-abandon (lightweight session-bracketed pipeline: Sonnet plans interactively across multiple turns, Haiku acts after /duo-act)
- `scripts/orchestra-hook.sh` — PreToolUse / SubagentStop / PreCompact / Stop dispatcher
- `scripts/otel-headers-helper.sh` — X-Orchestra-Session-ID injection; auto-creates native session entries
- `scripts/native-session-finalize.py` — Stop-hook helper: finalise one native session
- `scripts/session-report.{sh,py}` — unified cost report (native + orchestra)
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
- **Timestamp:** 2026-04-30T17:34:41Z
- **Model:** claude-sonnet-4-6
- **Reason:** /brain telemetry end-to-end smoke test — session 20260430T173441Z-1527612, cost=$0.9107, 6 T1 events, 3/3 checks passed. Cost persisted through all subagent phases.
- **Timestamp:** 2026-05-06T18:17:44Z
- **Model:** claude-sonnet-4-6
- **Reason:** /duo LiteLLM telemetry v1 — session 20260506T181744Z-1733561, cost=$1.5855, 3/3 standard checks passed. Revealed: `apiHeaders` is not a valid CC field (silently ignored); all Actor calls hit SoHoAI as `claude_code_native`. Fix: switched to `env.ANTHROPIC_CUSTOM_HEADERS`. cost_source=pricing_yaml (litellm also failed with `prompt_tokens` kwarg error).
- **Timestamp:** 2026-05-06T18:34:58Z
- **Model:** claude-sonnet-4-6
- **Reason:** /duo LiteLLM telemetry v1.5 — session 20260506T183458Z-1766043, cost=$2.0682, 3/3 standard checks passed. `ANTHROPIC_CUSTOM_HEADERS` fix deployed but SoHoAI attribution still returns 0 (env var is startup-time; subagents inherit parent env which predates the write). cost_source=litellm (litellm fallback now works — no `prompt_tokens` error). Next: investigate `otelHeadersHelper` for per-request dynamic header injection.
- **Timestamp:** 2026-05-07T10:29:03Z
- **Model:** claude-sonnet-4-6
- **Reason:** fix(telemetry): all report scripts now show YYYY-MM-DD--HH-MM timestamps; fixed is_session_active() multi-line lck parsing in native-session-report.py

## Telemetry Smoke Tests

Verify T1 (hook events) and T2 (transcript parse) after any /duo or /brain run.

### /duo smoke test
1. In plan mode, run: `/duo-plan add a comment line "# telemetry-smoke-test-<date>" to scripts/telemetry-report.sh`
2. (Optional) Refine across one or two turns to verify multi-turn refinement.
3. Run `/duo-act`, approve, and let Actor run.
4. After Phase 4 cleanup completes, run: `./scripts/smoke-test.sh`
5. Expected: T1 has ≥2 events (actor start + end), T2 cost > $0, subagents list contains "actor", `.outcome` mtime bounds the T2 window.

### /brain smoke test
1. In plan mode, run: `/brain add a comment line "# telemetry-smoke-test-<date>" to scripts/telemetry-report.sh`
2. Go through Phase 0 interrogation, approve plan, let pipeline run.
3. After cleanup, run: `./scripts/smoke-test.sh`
4. Expected: T1 has events for planner+actor+reviewer, T2 cost > $0, subagents list contains "planner", "actor", "reviewer". If parser_warnings mentions "T1 usage=null", that is expected (T1 is timing-only; T2 is authoritative).

### Native session telemetry smoke test
1. Open a fresh CC session (no /brain or /duo).
2. Run a trivial command (ask a question).
3. Close the session (Ctrl+C or exit).
4. In another CC session, trigger a Stop hook (send any message).
5. Check: `cat ~/.claude/native-sessions/telemetry.jsonl | tail -1 | jq .`
   Expected: record with `session_id` starting with `native-`, `cost_usd_estimate >= 0`.
6. Run: `~/.claude/scripts/session-report.sh --last 5`
   Expected: native session appears in the unified table.

### Reading the unified session report
```bash
~/.claude/scripts/session-report.sh --last 10
~/.claude/scripts/session-report.sh --since 2026-05-01
~/.claude/scripts/session-report.sh --source native
```
