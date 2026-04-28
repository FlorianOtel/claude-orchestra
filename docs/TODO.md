---
title: "Claude Orchestra — v2 Deferred & TODO items"
date: 2026-04-28
created_by: Claude Code (Claude Haiku 4.5)
context: >
  Extract from the design.md reference document, capturing all deferred
  features, v2 architectural stubs, optimization opportunities, and open
  questions that did not ship in v1 but are tracked for v2 development.
---

# TODO & Deferred Items

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
| Window counter is tmux-session-wide, not per-project | A `plan` window from one project blocks `plan` in another until it auto-closes | Acceptable; window names include stage, not project; 120 s auto-close limits overlap |
| Hook writes a stale state.env entry that persists indefinitely | Each `start` appends a new `LAST_WINDOW_<STAGE>=…` line; `state.env` grows | Low-impact; later lines shadow earlier when sourced; a `state.env.tmp`+rename rewrite could be added if the file grows uncomfortably large |
