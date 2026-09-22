---
title: "Claude Orchestra — v2 Deferred & TODO items"
created_at: 20260428-000000
created_by: Claude Code (Claude Haiku 4.5)
updated_by: Claude Code (Claude Opus 5)
updated_at: 2026-09-22--18-45
context: >
  Extract from the design.md reference document, capturing all deferred
  features, v2 architectural stubs, optimization opportunities, and open
  questions that did not ship in v1 but are tracked for v2 development.
---

# TODO & Deferred Items

## §0. Metrics gathering & decision policy

Telemetry exists to make cost/quality trade-off decisions **data-driven** rather than projected. The global log at `~/.claude/orchestra/telemetry.jsonl` accumulates one record per `/brain` or `/duo` invocation. On-demand report: `~/.claude/scripts/telemetry-report.sh --last N`.

### What is captured

| Field | Source | Purpose |
|---|---|---|
| `cost_usd_estimate` | T2 (transcript parse, authoritative) | USD cost per session |
| `total_tokens` | T2 | Aggregate token load |
| `parent.tokens` | T2 | Brain-tier cost (Opus/Sonnet) |
| `subagents[].tokens` per type | T2 | Per-tier cost attribution |
| `iterations.explore_dispatches` | T2 | Built-in Explore usage |
| `iterations.planner_replans` | T2 | Plan quality / rejection rate |
| `iterations.reviewer_fix_cycles` | T2 | Reviewer effectiveness |
| `outcome` | cleanup + Stop hook | Pass / fix-loop / block / abandoned |
| `regret_flag` | T2 | True if replans or fix cycles > 0 |
| `duration_s` | T2 | Wall-clock session time |

T1 hook events (`telemetry-events.jsonl`) capture subagent timing but the `usage` field is no longer emitted — hook payloads never exposed token counts. T2 is authoritative; T1 is timing-only.

### Data quality baseline

Sessions before commit `66c8a43` (2026-04-30) had parser bugs (model ID mismatch, `<synthetic>` model from `/compact`, `cross_check_t1_t2` crash). All pre-fix sessions have been removed from `telemetry.jsonl`. The log starts clean from:

- `20260430T145406Z-1387768` — first production `/brain` run (Opus 4.7, $40.27, 24M tokens, 22 min)
- `20260430T162017Z-1480179` — /duo smoke test ($0.15)
- `20260430T165550Z-1501376` — /duo smoke test ($0.27)
- `20260430T173441Z-1527612` — /brain smoke test ($0.91)

### Minimum sample before drawing conclusions

**N ≥ 20 sessions** for any cost-optimization decision. Fewer than 20 sessions risks acting on outliers (a single Opus session with a long Phase 0 dialogue can skew averages significantly).

### Decision gates — what telemetry should answer

**Gate 1 — Dedicated Researcher agent**

Current behaviour: `/brain` dispatches the built-in `Explore` subagent during Phase 0 research. Explore runs at Sonnet rates. The question is whether a dedicated Haiku-tier researcher would save meaningful cost.

Implement a Researcher agent **only if**:
- `iterations.explore_dispatches` averages ≥ 2 per `/brain` session across N ≥ 20 sessions, AND
- Explore's attributed token cost (`subagents[type=Explore].tokens × Sonnet rate`) exceeds **15%** of total session cost on average.

If Explore dispatches are rare or cheap, a Researcher agent adds complexity with negligible savings.

**Gate 2 — Haiku for planning (Planner tier cost)**

The Planner is currently Sonnet 5. If `subagents[type=planner].cost / total_cost` consistently < 5%, the Planner tier is not a meaningful cost target and should be left alone.

Revisit Planner model only if `planner_replans` rate is low (< 20% of sessions) AND planner cost fraction exceeds 10%.

**Gate 3 — 1-hour TTL prompt caching**

Collect inter-call timing between same-tier invocations (planner→planner, actor→actor within fix loops). If any tier shows a TTL-miss rate > 33% (cache expired between calls in the same session), 1-hour TTL pays off. See TODO §10.4 for break-even analysis. Requires verifying `claude -p` exposes TTL control.

**Gate 4 — Reviewer skip for low-risk tasks**

Track `reviewer_fix_cycles > 0` rate. If Reviewer rarely finds real issues (< 10% of sessions produce a FIX verdict), the review loop may be skippable for low-blast-radius tasks. This is a quality risk — only consider after ≥ 50 sessions with explicit quality outcome tracking.

**Gate 5 — Opus vs Sonnet for Brain**

Compare `cost_usd_estimate` and `regret_flag` rate across sessions where Brain was Opus 4.7 vs Sonnet 5. If Sonnet Brain sessions have equivalent `regret_flag` rate at ~5× lower cost, Sonnet becomes the default recommendation. Currently insufficient data.

### Retention policy

| Artefact | Location | Retention |
|---|---|---|
| Per-session dir (PLAN.md, TASKS.json, telemetry.json, etc.) | `${PROJECT}/.claude/orchestra/sessions/` | 30 days (lazy cleanup on next run) |
| Global trend log | `~/.claude/orchestra/telemetry.jsonl` | Indefinite; prune manually if > 1 MB |
| T1 event stream | `${SESSION_DIR}/telemetry-events.jsonl` | Same as session dir |
| Invocations log | `${PROJECT}/.claude/orchestra/invocations.log` | No rotation in v1 — prune manually |

Pricing rates: `config/pricing.yaml` carries `last_updated`. `telemetry-report.sh` warns if > 90 days stale. Verify against https://docs.anthropic.com/en/docs/about-claude/models/all-models before using cost data for decisions.

---

## Stage 2 telemetry — SoHoAI API integration (COMPLETED)

**Summary:** T2 cost attribution now uses SoHoAI as primary source (with fallback to litellm and pricing.yaml). Sessions are identified by `X-Orchestra-Session-ID` header injected into `settings.local.json`.

| Item | Status | Notes |
|---|---|---|
| Header injection (all 5 commands) | done | Atomic `_TMP + mv -f` pattern in setup/cleanup blocks |
| SoHoAI API query (`query_sohoai_cost`) | done | GET `/v1/usage/stats?session_id=&since=&until=`, ±60s buffer |
| litellm fallback (`query_litellm_cost`) | done | Model ID normalization, cache-token rates via `get_model_info()` |
| pricing.yaml fallback | done | Unchanged from original; used if SoHoAI and litellm return zero |
| `cost_source` field | done | Recorded in `telemetry.json` and `telemetry.jsonl`; values: `sohoai_api`, `litellm`, `pricing_yaml`, `none` |
| `telemetry-report.sh` Source column | done | Displays `cost_source` in default-mode output |
| `config/config.yaml` `sohoai:` block | done | `enabled: true`, `timeout_s: 5` |

Cost cascade: SoHoAI → litellm (with cache-token rates) → pricing.yaml. See `design.md` §"Stage 2 — SoHoAI API integration" for architecture details.

---

## §10. Deferred to v2 — stubs and future intent

### §10.1 `/orchestra-mode` — v1 stub

`~/.claude/commands/orchestra-mode.md` in v1:

- Accepts arg `default` | `acceptEdits` | `auto`.
- For `default` and `acceptEdits`: writes the preset name to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env` (simple `key=value` file) and echoes a confirmation. Does **not** change Claude Code's permission mode in v1 — that remains user-driven via `Shift+Tab` / `/permissions`. Keeps the stub harmless.
- For `auto`: prints "not yet implemented in v1 — see §10.2 for v2 intent" and exits without changing any state.

### §10.2 `/orchestra-mode auto` — v2 intent

When implemented, the `auto` preset will:

1. Sync both axes in one step: issue `/permissions bypassPermissions` (or set `--permission-mode` on next agent spawn) AND write orchestra-level overrides (`G2=notify`, `G5 cap=5`, `commit.policy=auto-on-branch`) to `state.env`.
2. Verify current git branch is not protected (default protected: `main`, `master`); if it is, auto-create `orchestra/auto-<UTC-ts>` and switch.
3. Arm the **CROSS-CHECK** stage — Brain-level read-only audit between REVIEW and FINALIZE, comparing `PLAN.md` checklist to `TASKS.json` claims to actual repo state.
4. Wire **checkpoint-commit-per-iteration**: after each IMPLEMENT step, Actor (or Brain) commits with `[orchestra auto iter N]` prefix so each iteration is a reviewable diff.
5. Arm the **test gate** (auto-detect `pytest` / `pnpm test` / `npm test` / `make test` / `cargo test`); refuse FINALIZE on red tests. Project can override via `config.yaml → test_gate.command`.
6. Enforce **iteration cap** (`crosscheck_loop_max`, default 5) and optional **token-budget cap** (`token_budget_usd`, default 5, 0 to disable).
7. On any rail trip (cap, red tests, unexpected state): write `orchestra/auto-halt-<UTC-ts>.md` with full context and halt cleanly. User reads it, decides, then either `/brain-resume` (also v2) or abandons.
8. **Never** auto-push; **never** auto-open a PR. Auto-commit stops at local commits on an isolated branch — a bounded relaxation of the global "never commit unless asked" rule.

v2 implementation notes:

- Most logic lives in the `/brain` skill body (CROSS-CHECK, branch isolation, checkpoint commits) rather than new infrastructure. The hook script just reads additional keys from `state.env`.
- CROSS-CHECK is not a new subagent; it's a Brain-level step inside the `/brain` skill.
- Halt-and-resume semantics share infrastructure with the `PreCompact` hook already wired in v1.

### §10.3 Other deferred items

- **Option A showcase** (separate `claude --model …` processes per tier in dedicated tmux windows) — build only if v1's in-process subagent pattern proves insufficient for some specific task.
- **Dedicated Researcher subagent** (`~/.claude/agents/researcher.md`) — only if Brain + built-in `Explore` prove inadequate for the G1 RESEARCH stage.
- **Lock sentinel** for cross-machine concurrent project sessions — only if real clobbers appear in practice. Additive; no v1 rework needed.
- **Non-NFS machine deployment helper** (`make install-orchestra` or similar to `rsync ~/.claude/` to a non-NFS host) — only when a Debian box outside the NFS mount shows up.
- **Review-loop escalation verbs** after cap-3 surface (`/fix`, `/accept-with-comments`, `/reject`) — v1 just lets Brain surface a text summary and the user decides in natural conversation.
- **`PreCompact` payload schema refinement** — v1 writes Brain's current `PLAN.md` reference, open `TASKS.json` items, last-N decisions, and active gate state to `brain-state.md`. Format evolves during v1 use.

## Hook-based model enforcement via `$CLAUDE_MODEL`

**Current state (v1):** `/brain` enforces minimum Sonnet 5 and `/duo` warns below Sonnet 5
via **LLM instruction-following** — Brain is instructed to read "The exact model ID is…" from
its system context, classify the model, and stop (`/brain`) or warn (`/duo`) accordingly. This
works because Claude Code injects the model ID into every session's system prompt, and Brain
reliably follows the instruction.

**Limitation:** Instruction-based, not runtime-enforced. Same trust level as the plan-mode
gate. A future change to Claude Code's system-prompt injection format could silently break
the detection, and a sufficiently degraded session state could miss it.

**Upgrade path:** Migrate `/brain`'s hard block to a **PreToolUse hook** that fires before
Brain's first tool call. The hook reads `$CLAUDE_MODEL` (or `$ANTHROPIC_MODEL`, or whatever
env var Anthropic exposes), compares it against the minimum (`claude-sonnet-5`,
`claude-opus-4-7`), and exits non-zero if the model is below minimum. A non-zero hook exit
causes Claude Code to surface an error and abort the action — making this a true runtime gate
independent of LLM instruction-following.

`/duo`'s advisory could similarly move to a hook that prints the warning and exits 0 (non-blocking).

**When to revisit:** When Anthropic exposes `$CLAUDE_MODEL` or equivalent as an environment
variable available in hook scripts, or when model info appears in the hook `HookInput` payload.

---

## §13.3 What would be required to close the live feed gap

A truly full live feed would require one of:

1. **A Claude Code streaming hook** — a new hook type that fires on each streamed token or on each model-output chunk (thinking block, prose segment, etc.). This would require an Anthropic-side change to Claude Code's hook architecture. Not available in v1 or v2 as currently documented; would need to be raised as a feature request.

2. **A dedicated subprocess per subagent** (Option A from the design history) — spawn each tier as a separate `claude --model … --print` process whose stdout Claude Code can pipe to the tmux window directly. This was explicitly rejected in favour of Option B (native subagents) because it requires managing inter-process communication and loses the native `ExitPlanMode` / permission-mode integration. Revisit only if native subagent visibility proves insufficient for real workflows.

3. **Agent self-reporting** (Tier 2 fallback) — instruct Actor/Planner/Reviewer to emit a structured progress line via `Bash` (e.g., `echo "[step] …" >> $LOGFILE`) after each significant action. This captures actor *intent* but not *thinking*, and requires every subagent prompt to carry the logfile path. Viable workaround; invasive.

## TO DO — v2 optimization (3): persistent subprocess per tier

**Premise.** Each tier currently spawns a fresh `claude -p` subprocess per invocation (spawn-per-call). For pipelines with many fix-loop iterations or many plan steps, this incurs ~1–2 s of startup overhead per call (loading config, parsing CLAUDE.md, initialising tools).

**Approach.** Keep one `claude -p --input-format stream-json --output-format stream-json` subprocess alive per tier across the entire pipeline run. Brain streams new task prompts to it via stdin (turn-by-turn input); subprocess responds via stdout. Lifecycle: open at start of Phase 3, close at end of Phase 3.

**Assumptions to verify before implementing:**
- `claude -p --input-format stream-json --output-format stream-json` accepts continuous turn-based input (not just one-shot)
- The stream-json `result` event marks turn boundaries cleanly so Brain can read full responses and the subprocess waits for the next prompt
- Subprocess crashes are rare enough that recovery cost is acceptable

**Implications:**
- Eliminates startup overhead per call
- Maintains session context across calls — Actor remembers what it did in step 1 when working on step 2 (currently context must be re-serialised by Brain)
- Maximises within-pipeline cache reuse — one continuous session, no TTL concerns
- Brain protocol shifts from spawn/poll/teardown-per-call to open/stream/stream/close-per-tier
- Tmux UX: one long-lived window per tier instead of one per invocation
- Failure mode: subprocess crash mid-pipeline loses tier session; recovery requires restarting and re-sending prior context (or accepting the loss for that pipeline run)

**When to revisit.** After v1 (spawn-per-call) ships and is stable, profile real pipeline runs: If startup overhead exceeds ~5% of total wall-clock time per pipeline run, OR if "Actor doesn't remember step 1 when running step 2" causes coordination bugs, then implement persistent subprocess. Otherwise the simplicity of spawn-per-call wins.

## TO DO — v2 optimization (4): 1-hour TTL prompt caching

**What it is.** Anthropic's prompt cache supports two TTL tiers:
- Default: 5 minutes (included in standard pricing)
- Extended: 1 hour (requires `cache_control: {type: "ephemeral", ttl: "1h"}` in the API request, with ~30% premium on the cache-write multiplier; cache reads cost the same)

**Why deferred.** `claude -p` does not currently expose `cache_control` TTL via CLI flag. Implementation would require either Claude Code adding the flag, or moving to direct Anthropic SDK calls (non-trivial).

**When it might pay off:**
- Pipelines that span >5 minutes between same-tier calls (long Actor steps where Reviewer's prior cache expires before the next call)
- Long human-decision pauses at G2 (`ExitPlanMode`) — user takes 10+ min to read the plan
- Heavy daily use where one user runs many `/brain` pipelines on similar tasks

**How to quantify:**

1. Instrument tier invocations to log API usage data:
   - `cache_creation_input_tokens` (cache write occurred)
   - `cache_read_input_tokens` (cache hit)
   - timestamp + tier + invocation ID

   These fields are already present in the `result.usage` block of the stream-json `result` event. Capture by parsing in `format-stream.sh` and appending to a usage log.

2. Run a representative sample (5–10 typical `/brain` runs, 5–10 typical `/duo` runs) covering normal task variety.

3. For each tier, compute the *miss rate due to TTL expiry*:
   - missed = invocations where the same tier's prefix was sent within prior 1 hour but >5 min ago (cache would have hit at 1h TTL but expired at 5m TTL)
   - rate = missed / total within-tier invocations

4. Decision rule: if any tier shows TTL-miss-rate >20%, 1-hour TTL would help that tier. Apply selectively (only the tier(s) that need it), not blanket.

5. Cost comparison:
   - Status quo: each TTL-miss costs full-input-rate × prefix tokens
   - With 1h TTL: extra ~30% premium on cache write paid once, then hits at 10% of normal rate
   - Break-even: at TTL-miss-rate r, switching is worthwhile when `r > 0.30 / (1.00 - 0.10) ≈ 33%` (rough — actual pricing has nuances)

## TO DO — optional FINALIZE doc-review stage

We chose the lightweight path (Planner pre-considers + Phase 4 post-checks) over a formal FINALIZE stage. If the lightweight approach proves insufficient, reconsider adding a formal FINALIZE stage between REVIEW and DONE in `/brain`, with Actor automatically dispatched to update docs based on the diff, followed by a *doc-only Reviewer pass* with distinct review style.

**When to revisit:**
- If the lightweight check misses doc updates more than ~20% of the time in real use.
- If doc review style needs to differ meaningfully from code review (style guides, terminology audits, link checking, screenshot regeneration, etc.).
- If you want the same strictness around docs that `auto` mode will bring to code.

**What would change if adopted:**
- `brain.md` gets a new Phase 4 body (FINALIZE stage with explicit Actor dispatch + Reviewer pass dedicated to docs).
- A `~/.claude/agents/documentarian.md` subagent file may be added if doc tool set diverges meaningfully from Actor's.
- `~/.claude/orchestra/config.yaml` gets a `finalize.doc_stage: enabled` toggle and a distinct `finalize.review_style: docs` key.
- The TODO design-history doc gets a new resolution note superseding this TO DO entry.

## v2 TO-DO classification (architecture-aware)

The 2026-04-26 migration to Option A (`claude -p` subprocesses on `main`) makes some v2 TO-DOs architecture-specific. The Option B (native Agent-tool subagents) work is preserved on the **`sub-agents`** git branch for fallback or future development.

| TO-DO | Common | Option A (`main`) | Option B (`sub-agents` branch) |
|---|---|---|---|
| Optional FINALIZE doc-review stage | ✓ | applies | applies |
| `auto` mode (existing detailed spec below) | concepts only | implementation needs rewrite | implementation matches the spec |
| Optimization (3): persistent subprocess per tier | | ✓ | n/a (Agent tool reuses session natively) |
| Optimization (4): 1-hour TTL prompt caching | | ✓ | n/a (Agent tool reuses Brain's session cache) |
| Lock sentinel for cross-machine project sessions | ✓ | applies | applies |

## Known v1 limitations (not bugs — deferred features)

| Limitation | Reason | Future fix location |
|---|---|---|
| Parallel Actor fan-out may close the wrong tmux window on `end` | v1 tracks last-window per stage in `state.env`; no unique correlation between `start` and `end` events for concurrent invocations of the same stage | v2 could use a per-invocation sentinel file with a unique token passed through the prompt |
| `/orchestra-mode` does not actually flip Claude Code permission mode | Deliberate — keeps v1 stub harmless; Axis X flip is user-driven via `Shift+Tab` | v2 `/orchestra-mode` implementation |
| `brain-state.md` payload is minimal (just pointers to state files + last 20 log lines) | Placeholder in v1; full payload schema depends on what `/brain-resume` will need | v2 schema refinement |
| No log rotation — `invocations.log` and per-invocation logfiles grow unboundedly | Acceptable for v1 usage volumes; user can `rm` periodically or add logrotate | Optional user-side hygiene |
| Model check is LLM-enforced, not runtime-enforced | No `$CLAUDE_MODEL` env var in Claude Code v1; check is instruction-based (same trust level as plan-mode gate) | v2 PreToolUse hook when env var becomes available — see "Hook-based model enforcement" section above |
| Window counter is tmux-session-wide, not per-project | A `plan` window from one project blocks `plan` in another until it auto-closes | Acceptable; window names include stage, not project; 120 s auto-close limits overlap |
| Hook writes a stale state.env entry that persists indefinitely | Each `start` appends a new `LAST_WINDOW_<STAGE>=…` line; `state.env` grows | Low-impact; later lines shadow earlier when sourced; a `state.env.tmp`+rename rewrite could be added if the file grows uncomfortably large |

---

## §14. SoHoAI attribution gap: orchestra subagents and native sessions

**Written after:** session `fix-telemetry-for-subagents` (2026-05-11), following
implementation of native session subagent cost tracking (Stage A: live display via
JSONL walking; Stage B: T2 finalization parity).

### What was implemented (context)

Stage A+B closes the native session gap: the status-line now adds subagent costs
(from `agent-*.jsonl` JSONL walking) to the parent's `cost.total_cost_usd`, and
`native-session-finalize.py` now calls `compute_cost(parent, subagents_list, ...)`
instead of `compute_cost(parent, [], ...)`. Both stages use `_walk_jsonl_for_tokens()`
and `compute_cost()` from `telemetry-summarize.py` via importlib — no new logic.

The convergence goal (T2 JSONL as single authoritative source for both native and
orchestra) is partially achieved: native T2 is now at parity with orchestra T2.

### What was left out of scope and why

**Orchestra subagent SoHoAI attribution** — the live cost for orchestra sessions comes
from `section-live-cost.sh` (formerly `sohoai-live-cost.sh`, removed 2026-05-26) which
calls `query_sohoai_usage(session_id=<orchestra-id>)` against SoHoAI's `usage_events`
SQLite. This returns costs attributed to the orchestra session ID via the
`inject_orchestra_session_id` FastAPI middleware in SoHoAI. It was previously unclear
whether **subagent** API requests (planner, actor, reviewer — each a separate CC process)
are correctly attributed to the **parent** orchestra session_id.

**Resolved 2026-05-26 by the smoke-session diagnostic** (octmux/20260525T113420Z-526645):
the orchestra session's telemetry shows `cost_source="sohoai_api+t2_parent"` with
`subagent_cost_usd=$18.13` while the JSONL-based pricing of the same six agent
transcripts yields only $2.05. The 9× gap means subagents ARE attributed to the parent
orchestra session in SoHoAI (the SQLite has events the JSONLs don't capture — likely
retries / streaming events / internal proxy traffic). Therefore SoHoAI is the
authoritative source for orchestra subagent cost both at session close and live
(via `section-live-cost.sh` with `timeout_s=5` and always-refresh caching).

Originally left out of scope because:
1. Answering required live traffic inspection (now done).
2. Fixing would have required cross-project changes in SoHoAI.
3. The JSONL-based T2 fallback (`process_transcript()`) already gave correct totals
   post-session, so the live gap was a display-lag issue, not a data-loss issue.

**Native session SoHoAI attribution** — `otelHeadersHelper` is not called by
CC 2.1.132/2.1.139, so native sessions (both parent and their subagents) send no
`X-Orchestra-Session-ID` header. SoHoAI sees all native traffic as anonymous
`claude_code_native`. The SoHoAI middleware reads `.lck` files to attribute requests,
but with multiple concurrent native sessions or subagents registering their own `.lck`
files, attribution is ambiguous. Left out of scope for the same reasons as above.

### Checks to perform before implementing

1. **Verify orchestra subagent attribution (current state):**
   - Run a short `/brain` session
   - During subagent execution, query SoHoAI directly:
     `curl "http://192.168.1.93:8000/v1/usage/stats?session_id=<orchestra-session-id>&since=<start>&until=<now>"`
   - Compare returned `cost_usd` with the T2 telemetry record's `cost_usd_estimate`
   - If they match → SoHoAI is already attributing subagents correctly → no fix needed
   - If SoHoAI shows only parent cost → subagents are not attributed → fix needed

2. **Inspect SoHoAI `usage_events` table:**
   ```bash
   sqlite3 ~/Gin-AI/projects/SoHoAI/telemetry.db \
     "SELECT orchestra_session_id, model, cost_usd FROM usage_events
      WHERE orchestra_session_id LIKE '%<session-basename>%'
      ORDER BY created_at;"
   ```
   Check whether subagent API calls have the same `orchestra_session_id` as the parent.

3. **Check `inject_orchestra_session_id` middleware logic:**
   - Does it match subagent CC processes to the parent `.lck` file?
   - Does it have a way to distinguish "this CC process is a subagent of session X"?

### What needs to be implemented (if checks show attribution is broken)

**Option A — Parent-child session registry (SoHoAI-side):**
- When `orchestra-hook.sh start` fires (PreToolUse for Agent), write a sidecar that maps
  the subagent CC process's PID (or expected session UUID) to the parent orchestra
  session_id. SoHoAI middleware reads this sidecar to attribute subagent requests.
- Requires: PID walk in `orchestra-hook.sh start` to identify the spawned CC process,
  writing a `~/.claude/active-sessions/<subagent-uuid>.parent` file, and updating
  SoHoAI's middleware to follow parent links when attributing.

**Option B — Native session attribution (both parent and subagents):**
- The `otelHeadersHelper` approach is blocked (CC 2.1.x doesn't call it).
- Alternative: write a per-request header injection via a custom `BASH_ENV` approach
  that sets a shell variable read by some proxy shim. Complex, fragile.
- More realistic: fix SoHoAI middleware to enumerate ALL active `.lck` files and
  attribute traffic from their cc_pid processes to those session_ids, using the most
  recently registered `.lck` as the best match for anonymous `claude_code_native`
  traffic. Ambiguous with multiple concurrent native sessions.

**Option C — Converge entirely on T2, drop SoHoAI live cost for native sessions:**
- Use JSONL walking (already implemented in Stage A) as the definitive live-cost source.
- Remove the SoHoAI query path for native sessions entirely.
- Live cost accuracy: ±30 s (TTL cache). Acceptable for a status bar.
- Leaves orchestra sessions still on SoHoAI for live cost (no change there).
- This is the pragmatic path if attribution fixes prove too invasive.

**Recommended order:** perform the checks first (§ above). If orchestra subagent
attribution is already working → only the native attribution gap remains, and Option C
is the pragmatic fix. If orchestra attribution is also broken → Option A is needed,
and Option C covers native while Option A covers orchestra.

---

## §15. Pricing.yaml staleness and live-cost badge exposure (2026-09-18 audit)

**Summary:** `config/pricing.yaml` contains stale rates for Anthropic models; live-cost badge accuracy depends on `section-live-cost.sh` which only uses tier-3 fallback (pricing.yaml), not the 3-tier cascade (SoHoAI → litellm → pricing.yaml). Session-end telemetry accuracy is unaffected because it uses the full cascade.

### Findings

**Stale Claude Sonnet 5 rates:**
- `config/pricing.yaml` declares: `claude-sonnet-5: input=$3.00, output=$15.00, cache_write=$3.75, cache_read=$0.30` (per MTok)
- Actual current rate (verified 2026-09-18 against live Anthropic price list): `input=$2.00, output=$10.00, cache_write=$2.50, cache_read=$0.20`
- The live Anthropic price list shows no introductory-versus-standard distinction for Sonnet 5 — it lists a single rate of $2/$10. The stale rates ($3/$15) are Sonnet 4.6 and 4.5's rates, which appear as legacy rows directly above Sonnet 5 on the same page.
- The `pricing.yaml notes:` block incorrectly asserts "introductory rate $2/$10 through 2026-08-31 vs standard $3/$15" — unsupported by the current live price list and contradicted by SoHoAI `main.py:112-115`.

**Missing model entries:**
- `claude-opus-4-8` and `claude-fable-5-1` are absent from `config/pricing.yaml` `models:` map entirely
- Both appear as parent models in retained telemetry (` claude-opus-4-8` $60.32, `claude-fable-5-1` $22.56, both `cost_source: litellm` — session-end telemetry priced them correctly via litellm fallback)

**Live badge exposure:**
- `scripts/section-live-cost.sh` calls `ts.compute_cost()` directly (tier-3 pricing.yaml fallback), **not** the full cascade
- `query_litellm_cost()` is never imported or called by `section-live-cost.sh`
- When a parent model is missing from pricing.yaml, `compute_cost()` silently returns $0 for that term with no warning
- **Derived, not observed:** reading the code path implies the live badge renders a $0 parent term for a parent model absent from pricing.yaml. This was NOT confirmed at runtime — a related prediction about `claude-opus-5[1m]` was made the same way and proved wrong (the bracketed id never reaches the pricing lookup; transcripts record plain `claude-opus-5`). Verify against a live Fable 5.1 or Opus 4.8 session before acting on it.

**Fallback-hierarchy gap:**
- `~/.claude/config/pricing.yaml` (candidate [0] in `load_pricing_yaml()` candidate list) does not exist but **would silently shadow** the deployed `~/.claude/orchestra/pricing.yaml` if created
- No protection against this precedence hazard

**Blast-radius measurement:**
- Across 208 telemetry records in `~/.claude/orchestra/telemetry.jsonl`: `cost_source` was `litellm` 125×, `sohoai_api*` 58×, `pricing_yaml` 1× (2026-05-06, predating the bad rate)
- Session-end telemetry largely unaffected by stale pricing (only 1 record used pricing.yaml, and it was before the rate changed)
- Live badge accuracy is the exposed surface (real-time display via `section-live-cost.sh`)

**Documentation drift:**
- `docs/Telemetry.md:467` in SoHoAI repo describes a "pricing.yaml override in `query_litellm_cost()`" — this override does not exist in the code

### What needs to be done

1. Update `config/pricing.yaml`: Sonnet 5 rates ($2/$10, cache $2.50/$0.20), add `claude-opus-4-8` and `claude-fable-5-1` entries
2. Fix `scripts/section-live-cost.sh` to use the full 3-tier cascade for live badge (SoHoAI → litellm → pricing.yaml), not pricing.yaml only
3. Add a warning in `compute_cost()` when a model key is not found (currently silent $0)
4. Document the fallback-hierarchy precedence hazard (candidate [0] shadowing candidate [1])

### Resolution (2026-09-19)

**What was actually done:**
- `config/pricing.yaml`: claude-sonnet-5 corrected 3.00/15.00 → 2.00/10.00 (cache 2.50/0.20); claude-opus-4-7 corrected 15.00/75.00 → 5.00/25.00 (cache 6.25/0.50) — a 3× overcharge that applied to many of this project's historical /brain sessions; claude-opus-4-8 and claude-fable-5-1 added; claude-fable-5-1 cache_read is 0.25 (Anthropic prices Fable 5.1 cache hits at 0.025× base input, not the standard 0.1×).
- The `notes:` block was rewritten fairly: the original author hedged against a REAL scheduled price increase. Anthropic's pricing page ([verified 2026-09-19](https://platform.claude.com/docs/en/about-claude/pricing)) now states the Sonnet 5 introductory rate became standard and the 2026-09-01 increase to $3/$15 "will not occur".
- `scripts/section-live-cost.sh` now uses the full 3-tier cascade for the orchestra subagent term.
- `compute_cost()` now warns on a missing model key instead of silently contributing $0.
- All rates verified against https://platform.claude.com/docs/en/about-claude/pricing on 2026-09-19.

---

## §16. Telemetry: blast_radius stub + T1 attribution + SubagentStop diagnostics (2026-09-19)

**Summary:** investigation triggered by an observed `/brain` session with `blast_radius: {files_read: 0, files_edited: 0, loc_changed_estimate: 0}` despite 8 files changed. Root causes identified via live payload capture and session transcript analysis. **The git stash is SUPERSEDED and was NOT applied.** Its accepted content was re-implemented fresh; its blast_radius implementation and its filename-inference attribution cascade were both rejected.

### Status of the git stash

A prior session parked working code (telemetry-summarize.py +167/−63, orchestra-hook.sh +71/−16) at commit `stash@{0}`. The stash is no longer the source of truth for any of the fixes below. Recommend `git stash drop` after code review — an OPERATOR action, not done here.

**Confirmed from the stashed handover:** `usage` null in 2724/2724 T1 events across 55 sessions in 9 projects; `blast_radius` a stub with zeros in all 49 telemetry.json records and read by nothing; `cross_check_t1_t2` unable to ever pass.

### Falsified claims from the stashed diagnosis

**Claim 1: "ends outnumber starts 2.8×–13.4× in every session across four projects"**

FALSIFIED by session recount. Actual: end:start ratio ranges 0.5× to 28× across 55 sessions, median 5.0, with 17 sessions at exactly 1.0. The diagnosis assumed a uniform ratio implying a uniform cause; the distribution is episodic. [Source: retained telemetry-events.jsonl across 55 sessions in 9 projects]

**Claim 2: "single-slot LAST_LOGFILE_REF under parallel dispatch explains the count anomaly"**

FALSIFIED as a root-cause explanation. A filename reference clobbering corrupts a LABEL; it cannot manufacture events. It does correctly explain the attribution failure (missing subagent type in T1). [Source: scripts/orchestra-hook.sh]

**Claim 3: "magnet effect — find_active_session_dir picking any unfinalised dir — caused excess events"** (raised during this session, tested, discarded)

FALSIFIED by the 28× specimen analysis: only 4 subagent sidecars for 112 end events; the one concurrent session in its window dispatched no subagents; telemetry.json presence does not separate high-ratio from ratio-1.0 sessions. The vulnerability is real but was NOT the operative cause. [Source: live session inspection]

### Root causes, established by live payload capture

**ROOT CAUSE 1: Claude Code's own internal helper agents on ~31s ticks**

Claude Code's internal agents (suggestion generator; per-background-task status describer) fire SubagentStop on a ~31 second cadence while a background task is alive, with **empty `agent_type`** and **no meta sidecar**. A REAL dispatched subagent fires SubagentStop ONCE, at completion, with `agent_type` populated and sidecar present. Captured evidence (snapshot of 59 payloads at time of writing; the probe remained live briefly afterwards so the file may contain more): every real dispatched subagent carried a populated `agent_type` (11 `actor`, 2 `reviewer`), and every internal-helper firing had it empty (46), with `last_assistant_message` values such as `<no suggestion>` and `Extracting union of capture keys` and no sidecar. [Source: raw SubagentStop payloads, captured 2026-09-19]

**ROOT CAUSE 2: Wrong-key attribution bug — 89% "unknown" rate**

The payload field is `.agent_type`; orchestra-hook.sh probed `.subagent_type`, `.tool_input.subagent_type`, and `.agent`, never `.agent_type`. Every end event that ever resolved did so via filename inference (logfile sidecar), which is why researcher and researcher-deep had 86 starts between them and zero ends — no `agent-*` filename pattern was recognized. [Source: scripts/orchestra-hook.sh line ~163, end-arm SUBAGENT probe (pre-2026-09-19)]

### What shipped

- `usage` field removed from T1 events
- `cross_check_t1_t2()` and `read_telemetry_events()` deleted; spurious delta warnings eliminated
- `compute_blast_radius()` and `blast_radius` field deleted (stub with zeros, unread)
- `compute_cost()` now emits warning on missing model key instead of silent $0
- `.agent_type` attribution cascade: payload `.agent_type` → `agent-<id>.meta.json` sidecar `agentType` → give up (drop the firing)
- Session-identity gate: `.transcript-session-ids` companion, `~/.claude/active-sessions/*.lck` liveness check via `kill -0`, fail-open on no identity
- `orchestra-hook.sh` drops internal-agent firings (empty agent_type, no sidecar) instead of recording as "unknown"
- `find_active_session_dir()` now prefers inflight-marker presence (`.brain-inflight` / `.duo-inflight`) in candidate ranking — reduces "magnet" vulnerability (though the vulnerability did not cause the measured excess events)
- Pricing corrections (Sonnet 5, Opus 4-7, new models)
- `scripts/section-live-cost.sh` uses full 3-tier cascade for orchestra subagent term
- Repo hygiene: `scripts/__pycache__/` gitignored (new .gitignore pattern added); `scripts/orchestra-hook.sh.orig` removed

### Still open / worth filing upstream

**What remains undocumented:** That SubagentStop fires for Claude Code's internal helper agents at all is undocumented. The [hooks reference](https://code.claude.com/docs/en/hooks) describes the event only as running "when a Claude Code subagent has finished responding", with no mention of repeats or internal agents. A documentation clarification upstream would help others building telemetry on top of this hook.

**Why the earlier hypotheses were incomplete:** The original stashed diagnosis considered `LAST_LOGFILE_REF` single-slot clobbering, filename pattern gaps, and parallel-dispatch "magnet" effects — all real vulnerabilities — but none of them explain a 28:1 ratio with only 4 sidecars. The internal helper agents firing every 31s while a background task is alive is the primary volume driver. The variable distribution (not uniform 2.8–13.4 as claimed) is consistent with a hypothesis that sessions with no background tasks during dispatch run at 1:1 (one end per start), while sessions with background activity see higher ratios as internal agents contribute repeat firings. However, this hypothesis about why 17 sessions sit at exactly 1.0 was not verified — we did not check whether those sessions actually lacked background tasks during their dispatch phases.

**Update 2026-09-22 — the other tail is now diagnosed.** §16 explained only ratios *above* 1.0 (internal helpers firing repeatedly). Ratios *below* 1.0 — starts with no end, which is what leaves the `▶` badge lit forever — were recorded as an observed number and never root-caused. See §18.

### Unresolved, recorded as inconsequential

Two Phase-0 researchers disagreed on how many retained sessions sit at exactly 1.0 ratio (one reported 17, the other ~34). The discrepancy was not run to ground because it affects no decision: all sessions are processed correctly regardless. The measurement is included here for transparency.

---

## §17. Context-window staleness in config/context-windows.yaml (2026-09-19, flagged not-scheduled)

**Status:** deliberately NOT changed in this session; flagged for awareness and future work.

**Finding:** `config/context-windows.yaml` contains stale context-window entries for production models:
- `claude-sonnet-5: 200000` — STALE. Anthropic's live model page lists Claude Sonnet 5's context window as 1M tokens (verified 2026-09-19 against https://platform.claude.com/docs/en/about-claude/models).
- Missing entries: `claude-opus-4-8` and `claude-fable-5-1` are absent from that file.

Changing the context denominator affects the status-line `ctx` segment display (e.g., `12% 120K/200K` becomes `1% 120K/1M`) and warrants a separate review to verify no unintended consequence. Not changed here; flagged for deliberate operator decision in a follow-up session.

---

## §18. Starts without ends — the low-ratio tail, diagnosed and fixed (2026-09-22)

§16 measured end:start ratios of 0.5×–28× and explained only the high side: Claude Code's
internal helper agents fire `SubagentStop` on a ~31 s cadence. The **low** side — ratios below
1.0, meaning a `start` that never got a matching `end` — was left as an observed number. That is
the tail that leaves the status line's `▶ stage` badge lit indefinitely, because nothing ever
retired an unmatched start.

### Measured before the fix

| project | starts | ends | matched | unmatched starts |
|---|---|---|---|---|
| AYA | 351 | 2086 | 290 | 61 |
| claude-orchestra | 174 | 360 | 86 | **88 (51%)** |
| octmux | 329 | 409 | 284 | 45 |

The dominant cause was **not** concurrency. `end` events whose `agent_type` could not be read
arrive as subagent `unknown` and previously fell through to the sidecar read, deleting a live
agent's logfile:

| project | `end` with `subagent:"unknown"` | of which consumed a sidecar |
|---|---|---|
| AYA | 1784 / 2086 (86%) | 33 |
| claude-orchestra | 335 / 360 (93%) | 61 |

Unmatched starts are long-standing — 13–22% per month since May, stable. The unknown-end flood
is recent: 1952 in September against 110 in June on comparable start volume. That coincides with
agent dispatch becoming asynchronous; recorded as correlation with a plausible mechanism (more
background agents → more `SubagentStop` firings with unparseable payloads), not as established
causation.

### Two further defects found while reading

- **The PID fallback could never match.** `.last-logfile.${STAMP_PID}` keyed on `$$`, the hook
  process's own PID, which differs between the `start` and `end` invocations. The 120-minute
  prune existed to sweep the resulting litter.
- **`researcher` and `researcher-deep` had no case in `stage_for_subagent`**, so they fell
  through to `agent` — the same bucket unidentified ends map to. An `unknown` end could
  therefore retire a live researcher's marker. This is why researcher starts paired so badly
  (45 starts / 10 ends in AYA), and is the concrete mechanism behind §16's note at line 470 that
  "researcher and researcher-deep had 86 starts between them and zero ends".

### Disposition — what the fix does and does not do

| Path | Disposition |
|---|---|
| Unidentified `end` consumes a live marker | **Eliminated** — only identified ends retire a marker; the line itself is no longer written |
| Single-slot clobbering under concurrency | **Eliminated** — one marker per dispatch under `.pending-agents/<stage>/` |
| PID-keyed fallback can never match | **Eliminated** — markers live under `ORCHESTRA_DIR`, stable across both invocations |
| `researcher`/`researcher-deep` sharing the `agent` bucket | **Eliminated** — both now map to `research` |
| `SubagentStop` never fires (killed subagent) | **Mitigated only**, by the TTL reaper |
| `has_active_orchestra_session()` strips the `end` write mid-flight | **Mitigated only**, by the TTL reaper |
| A genuine subagent whose payload lacks `agent_type` hits the internal-helper `exit 0` | **Mitigated only**, by the TTL reaper |

### Separate phenomenon, deliberately not fixed here

Agents also linger in **Claude Code's own task rows** — distinct from the orchestra badge — when
a subagent shells out to an unbounded command and the grandchild outlives it: the agent cannot
finalise until every child exits. One `find /` ran as `bfs` for 74 minutes at load ~9.6, with its
parent reported `completed` an hour earlier. Orchestra cannot make the harness close such a row.
What it can do, and now does:

- **Prevent** — `agents/{actor,researcher,researcher-deep,reviewer}.md` gained a shell-discipline
  block (never search from `/`; bound long commands with `timeout`; go to the path rather than
  scanning for it; confirm children have exited before returning). `planner.md` is untouched — it
  has no `Bash`, and is the only tier never observed stalling.
- **Detect** — `scripts/check-orphans.sh`, called advisorily from the `start` hook. It matches the
  binary (`pgrep -x`), never a pattern string, and excludes its **whole ancestor chain**: a
  two-level `$$`/`$PPID` guard is not enough, because under command substitution the caller is the
  grandparent, and that caller is typically Claude Code's own Bash wrapper. That was observed
  during development, not theorised.
- **Surface** — `/brain` and `/duo-act` now treat the harness's "background work of its own still
  running… the result below may be interim" notice as a signal that the returned result may be
  **partial**, not merely that a row is untidy.

Recorded as prevented and detected, **not** eliminated.
