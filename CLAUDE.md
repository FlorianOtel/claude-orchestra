# Claude Orchestra — project instructions

## Project workflows

```bash
./deploy.sh          # deploy to ~/.claude/ (system-wide, all machines via NFS)
./collect.sh         # sync ~/.claude/ changes back to repo before committing
```

## Layout

- `agents/`   — planner (Sonnet 4.6), actor (Haiku 4.5), reviewer (Sonnet 4.6)
- `commands/` — /brain (full pipeline: Phase 0 inline + 3 subagents) + /brain-abandon (explicit cancel); /duo-plan, /duo-act, /duo-abandon (lightweight session-bracketed pipeline: Sonnet plans interactively across multiple turns, Haiku acts after /duo-act)
- `scripts/orchestra-hook.sh` — PreToolUse / SubagentStop / PreCompact / Stop dispatcher
- `scripts/otel-headers-helper.sh` — X-Orchestra-Session-ID injection; auto-creates native session entries (CC 2.1.132: not called — fallback via bash-session-init.sh)
- `scripts/bash-session-init.sh` — sourced via `BASH_ENV`; registers native session as `native-<UUID>.lck` on first Bash call (UUID-keyed, cc_pid for liveness only)
- `scripts/native-session-finalize.py` — Stop-hook helper: finalise one native session; T2 fallback via `_walk_jsonl_for_tokens` + `pricing.yaml`
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
- **Timestamp:** 2026-05-07T14:46:42Z
- **Model:** claude-sonnet-4-6
- **Reason:** native session T2 fallback smoke test — session native-20260507T143424Z-2001330, cost=$13.3918, source=pricing_yaml, model=claude-sonnet-4-6. Diagnosed: otelHeadersHelper not called by CC 2.1.132 (no .lck files), SoHoAI query returns 0 (no session attribution). Fix: Stop hook self-registers each session; T2 fallback parses JSONL transcript via session_uuid + pricing.yaml.
- **Timestamp:** 2026-05-07T17:09:00Z
- **Model:** claude-sonnet-4-6
- **Reason:** fix(telemetry): BASH_ENV bridge — bash-session-init.sh writes uuid-<CC_MAIN_PID> sidecar; Stop hook reads /proc/NODE/stat for parent lookup. Fixes: CLAUDE_CODE_SESSION_ID not set in hook context (only in Bash subprocesses). Bug caught: ||exit 0 logic killed all Bash calls when UUID was set — fixed to if/then guard.
- **Timestamp:** 2026-05-07T17:39:00Z
- **Model:** claude-sonnet-4-6
- **Reason:** refactor(telemetry): UUID-keyed native sessions — bash-session-init.sh now writes native-<UUID>.lck directly (registration moved from Stop hook). Eliminated PID ancestry traversal (/proc/stat). Session IDs are now native-<UUID>. Bug caught during implementation: `[ -z ] && return || exit` idiom kills bash when UUID is set — must use `if/then`.
- **Timestamp:** 2026-05-10T18:51:03Z
- **Model:** qwen3-coder-next (Actor) + deepseek-v4-pro (Planner / Actor-heavy) + claude-sonnet-4-6 (Reviewer / planner-long fallback)
- **Reason:** graduated SoHoAI rollout — Phases A+B+C: pricing.yaml + tier annotations + actor-heavy + planner-long + Reviewer-stays-Sonnet. Smoke tests pending — session 20260510T180922Z-2575990. Cost/duration TBD-post-smoke.
- **Timestamp:** 2026-05-10T20:45:52Z
- **Model:** claude-opus-4-7[1m] (Brain) + kimi-k2.6 (actor-heavy) + claude-sonnet-4-6 (reviewer-long)
- **Reason:** status-line ctx + SoHoAI live-cost segments — implemented via /brain heavy-tier workflow, deployed, all smoke tests pass (ctx bar colors, 1M denominator, SoHoAI query, JSONL fallback).
- **Timestamp:** 2026-05-19T00-00
- **Model:** claude-sonnet-4-6[1m]
- **Reason:** fix(status-line): restore [1m] ctx window after first API call — CC's API response strips the [1m] CC-local routing marker; orchestra-block.sh now reads settings.json to re-inject it, restoring 1M denominator and "(1M context)" display name in projects configured with sonnet[1m].
- **Timestamp:** 2026-05-22T19-00
- **Model:** claude-sonnet-4-6[1m]
- **Reason:** fix(status-line): restore [1m] used_pct recalculation — 385c011 accidentally removed it; result was "56% 111K/1M" instead of "11% 111K/1M" for current session (~112K tokens). Verified: CC reports used_pct=56 (200K basis), fix recalculates to 11 (1M basis), ctx-segment renders correct green bar at 11%.
- **Timestamp:** 2026-05-23T17-54
- **Model:** claude-sonnet-4-6[1m]
- **Reason:** fix(status-line): add parent cost to SoHoAI orchestra cost display — status line was showing SoHoAI subagent cost only (~$9.55) vs telemetry total of $20.60 ($7.99 parent + $12.61 subagents). Root cause: SoHoAI query returns subagent costs only (parent Brain lacks X-Orchestra-Session-ID header at startup); fallback that adds cost.total_cost_usd was skipped when SoHoAI returned non-empty. Fix: parse SoHoAI ~$X.YZ result, add cost.total_cost_usd parent cost, re-format combined total — mirrors telemetry-summarize.py's sohoai_api+t2_parent at session close.
- **Timestamp:** 2026-05-23T23-47
- **Model:** claude-sonnet-4-6[1m]
- **Reason:** fix(status-line): post-session stale cost-cache override — after /brain session ends, status bar showed ~$9.30 (stale native cache from turns between brain sessions) instead of $16.73 (telemetry). Root cause: native cost-cache not updated during SoHoAI-path brain sessions; after telemetry.json written, native mode activated showing stale cache. Fix: in native fallback block, scan sessions_root for most recent completed session with matching .transcript-uuid, override _total with telemetry.json cost_usd_estimate (30s TTL cache in native-<UUID>.orchcost-cache). SUPERSEDED by v3 fix below.
- **Timestamp:** 2026-05-24T00-00
- **Model:** claude-sonnet-4-6[1m]
- **Reason:** fix(status-line): reset native cost to $0 after orchestra session ends (v3, commit f97015e) — v2 froze cost at orchestra telemetry value; user wanted each logical CC section to start from $0. v3: on first native render after orchestra closes, detect session ID change via sentinel (native-<UUID>.orchcost-reset), delete stale cost-cache, reset _total to 0. Subsequent native renders grow from 0. _orchcost_cache now stores session ID (not cost float). Works for both /brain and /duo. SUPERSEDED by v4 fix below.
- **Timestamp:** 2026-05-24T00-00
- **Model:** claude-sonnet-4-6[1m]
- **Reason:** fix(status-line): delta-based post-orchestra cost reset (v4, commit 3741769) — v3 regression: _cc_cost (CC's cumulative total) and _sub_cost (orchestra subagents via JSONL pricing) are both non-zero immediately after session ends, so status bar jumped to ~$24.79 on second native render instead of $0.00. Fix: at reset time, store _cc_cost and _sub_cost as baselines in ${sentinel}.cc/.sub; on every subsequent native render, override _total with delta max(0,cc-cc_base)+max(0,sub-sub_base). Shows $0.00 immediately, grows only from new activity.
- **Timestamp:** 2026-05-24T15-30
- **Model:** claude-opus-4-7[1m] (Brain) + claude-sonnet-4-6 (Planner / Reviewer) + claude-haiku-4-5 (Actor)
- **Reason:** refactor(status-line): replace v1–v4 layered cost-reset machinery with single section-based state model. /brain pipeline session 20260524T135107Z-102392, cost=$34.45 (parent $24.51 + subagents $9.94), 8.96M tokens, outcome=pass. One state file (`<UUID>.section` with SECTION_ID/CC_BASE/SUB_BASE/LAST_NONZERO) replaces 6 prior files (.cost-cache, .orchcost-cache, .orchcost-reset*). One formula per section type (orchestra: SoHoAI+cc_delta or LAST_NONZERO fallback; native: cc_delta+sub_delta with transient-zero guard). Section transitions detected by SECTION_ID comparison — abandoned/passed/aborted orchestra all follow identical reset path. Validation hook in telemetry-summarize.py compares orchestra LAST_NONZERO vs cost_usd_estimate, writes `cost_divergence` event to invocations.log if > 5% drift. Manual smoke tests pending (4a–4e in PLAN.md). 3 files changed (+176 −113).
- **Timestamp:** 2026-05-26T00-00
- **Model:** claude-opus-4-7[1m]
- **Reason:** refactor(status-line): replace dual-source delta formula with JSONL-derived time-windowed cost. Diagnosed via brain session octmux/20260525T113420Z-526645 — telemetry $53.95, status line displayed $27.96 just before reset. Root cause: (1) `sohoai-live-cost.sh` used `timeout_s=1` and routinely timed out against busy SoHoAI SQLite, leaving cache stale at $0.83 for 38 min; cache was only refreshed when result > 0; (2) `cc.total_cost_usd` is unreliable for parent (reported $6.03 for a session whose T2 parent was $35.82). Fix: new `section-live-cost.sh` uses same data sources as telemetry-summarize.py at session close — parent JSONL+pricing.yaml always; SoHoAI for orchestra subagents (timeout 5s, always-refresh cache); time-windowed agent-*.jsonl walk for native subagents. State file shrinks from `SECTION_ID/CC_BASE/SUB_BASE/LAST_NONZERO` to `SECTION_ID/SECTION_START_UNIX/LAST_NONZERO`. No dual-source delta math, no `cc.total_cost_usd` dependency, no native-vs-orchestra branching in orchestra-block.sh. Dead-code removed in same commit: scripts/sohoai-live-cost.sh, scripts/native-subagent-cost.sh. Manual smoke tests pending operator post-deploy.
- **Timestamp:** 2026-05-27T00-00
- **Model:** claude-opus-4-7[1m]
- **Reason:** refactor(status-line): per-CC-session accumulator. Display = total cost since CC session start, growing monotonically, never resetting at section transitions. State file gains `ACCUMULATED_TOTAL` field; transitions freeze just-ended section's final cost (telemetry.json `cost_usd_estimate` for orchestra, LAST_NONZERO for native) into the total. Cleanup-order tweak in /brain and /duo-act runs telemetry-summarize.sh BEFORE inflight removal so telemetry.json is guaranteed present at transition (race-free reconciliation). Manual smoke tests pending operator post-deploy: accumulator never resets, telemetry reconciliation visible at brain-end, back-to-back orchestra growth, `--resume --fork-session` resets to $0 (new UUID = no state file).

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

### Status-line ctx + SoHoAI cost smoke test (no CC restart needed)
1. Deploy: `./deploy.sh`
2. Test ctx segment (low fill, expect green):
   `~/.claude/scripts/ctx-segment.sh 12 24000 200000 claude-sonnet-4-6`
   → colored `ctx ▓░░░░░░░░░ 12% 24K/200K`
3. Test ctx segment (high fill, expect orange):
   `~/.claude/scripts/ctx-segment.sh 85 170000 200000 claude-sonnet-4-6`
   → `ctx ▓▓▓▓▓▓▓▓░░ 85% 170K/200K` in orange
4. Test ctx 1M variant:
   `~/.claude/scripts/ctx-segment.sh 12 120000 1000000 'claude-opus-4-7[1m]'`
   → `ctx ▓░░░░░░░░░ 12% 120K/1M`
5. Test section-live-cost helper (replace PARENT_UUID with a current CC
   session ID; SECTION_ID is either an orchestra dir basename or
   `native:<id>` for native sections):
   `~/.claude/scripts/section-live-cost.sh PARENT_UUID SECTION_ID $(date +%s) /tmp/test-cost-cache`
   → 4-decimal float (`0.0000` if no in-window activity); cold path <6s
     (parent JSONL parse + up to 5s SoHoAI for orchestra); cache hit <50ms
6. Live render: send any message to CC; observe status bar shows
   `model | ctx ▓▓░░░░░░░░ N% XK/YM | ~$X.YZ | ◆ project | ⎇ branch`
   (cost shown for paid models; absent for local/* zero-cost models)

### Native session telemetry smoke test
1. Open a fresh CC session (no /brain or /duo).
2. Run a trivial Bash command (triggers BASH_ENV → `bash-session-init.sh` writes `native-<UUID>.lck`).
3. Close the session (Ctrl+C or exit).
4. In another CC session, send any message (triggers Stop hook → finds dead `.lck` → T2 finalization).
5. Check: `cat ~/.claude/native-sessions/telemetry.jsonl | tail -1 | jq .`
   Expected: `session_id="native-<UUID>"`, `cost_usd_estimate > 0`, `cost_source: "pricing_yaml"`, `model` field present.
6. Run: `~/.claude/scripts/session-report.sh --source native --last 5`
   Expected: new row with cost, model, duration.

**Telemetry flow (CC 2.1.132):**
- `otelHeadersHelper` is configured but NOT called by CC 2.1.132 — no session attribution to SoHoAI, `cost_source: "none"` without the fallback
- `bash-session-init.sh` (sourced via `BASH_ENV`) registers the session on first Bash call: writes `~/.claude/active-sessions/native-<UUID>.lck` with `cc_pid` (stable CC main process), `session_uuid`, `started_at`
- `CLAUDE_CODE_SESSION_ID` is available in Bash subprocesses but NOT in hooks — registration happens in bash-session-init.sh, not the Stop hook
- Stop hook only finalizes dead sessions: iterates `native-*.lck`, checks `kill -0 <cc_pid>`, runs `native-session-finalize.py` when dead → T2 parses JSONL → `cost_source: "pricing_yaml"`
- Session IDs: `native-<UUID>` (stable, globally unique — no timestamp-PID suffix)
- **Requires**: `BASH_ENV=/home/florian/.claude/scripts/bash-session-init.sh` in `settings.json` env (NOT managed by deploy.sh — must be set manually or kept in settings.json)

### Reading the unified session report
```bash
~/.claude/scripts/session-report.sh --last 10
~/.claude/scripts/session-report.sh --since 2026-05-01
~/.claude/scripts/session-report.sh --source native
```
