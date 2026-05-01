---
title: "Claude Orchestra — v2 Deferred & TODO items"
created_at: 20260428-000000
created_by: Claude Code (Claude Haiku 4.5)
updated_by: Claude Code (Claude Sonnet 4.6)
updated_at: 20260430-195438
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

T1 hook events (`telemetry-events.jsonl`) capture subagent timing but have `usage=null` — hook payloads do not expose token counts. T2 is authoritative; T1 is timing-only and drives the real-time status-line cost indicator.

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

The Planner is currently Sonnet 4.6. If `subagents[type=planner].cost / total_cost` consistently < 5%, the Planner tier is not a meaningful cost target and should be left alone.

Revisit Planner model only if `planner_replans` rate is low (< 20% of sessions) AND planner cost fraction exceeds 10%.

**Gate 3 — 1-hour TTL prompt caching**

Collect inter-call timing between same-tier invocations (planner→planner, actor→actor within fix loops). If any tier shows a TTL-miss rate > 33% (cache expired between calls in the same session), 1-hour TTL pays off. See TODO §10.4 for break-even analysis. Requires verifying `claude -p` exposes TTL control.

**Gate 4 — Reviewer skip for low-risk tasks**

Track `reviewer_fix_cycles > 0` rate. If Reviewer rarely finds real issues (< 10% of sessions produce a FIX verdict), the review loop may be skippable for low-blast-radius tasks. This is a quality risk — only consider after ≥ 50 sessions with explicit quality outcome tracking.

**Gate 5 — Opus vs Sonnet for Brain**

Compare `cost_usd_estimate` and `regret_flag` rate across sessions where Brain was Opus 4.7 vs Sonnet 4.6. If Sonnet Brain sessions have equivalent `regret_flag` rate at ~5× lower cost, Sonnet becomes the default recommendation. Currently insufficient data.

### Retention policy

| Artefact | Location | Retention |
|---|---|---|
| Per-session dir (PLAN.md, TASKS.json, telemetry.json, etc.) | `${PROJECT}/.claude/orchestra/sessions/` | 30 days (lazy cleanup on next run) |
| Global trend log | `~/.claude/orchestra/telemetry.jsonl` | Indefinite; prune manually if > 1 MB |
| T1 event stream | `${SESSION_DIR}/telemetry-events.jsonl` | Same as session dir |
| Invocations log | `${PROJECT}/.claude/orchestra/invocations.log` | No rotation in v1 — prune manually |

Pricing rates: `config/pricing.yaml` carries `last_updated`. `telemetry-report.sh` warns if > 90 days stale. Verify against https://docs.anthropic.com/en/docs/about-claude/models/all-models before using cost data for decisions.

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

**Current state (v1):** `/brain` enforces minimum Sonnet 4.6 and `/duo` warns below Sonnet 4.6
via **LLM instruction-following** — Brain is instructed to read "The exact model ID is…" from
its system context, classify the model, and stop (`/brain`) or warn (`/duo`) accordingly. This
works because Claude Code injects the model ID into every session's system prompt, and Brain
reliably follows the instruction.

**Limitation:** Instruction-based, not runtime-enforced. Same trust level as the plan-mode
gate. A future change to Claude Code's system-prompt injection format could silently break
the detection, and a sufficiently degraded session state could miss it.

**Upgrade path:** Migrate `/brain`'s hard block to a **PreToolUse hook** that fires before
Brain's first tool call. The hook reads `$CLAUDE_MODEL` (or `$ANTHROPIC_MODEL`, or whatever
env var Anthropic exposes), compares it against the minimum (`claude-sonnet-4-6`,
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
