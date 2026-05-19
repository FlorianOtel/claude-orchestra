---
title: "Claude Orchestra — three-tier Brain/Planner/Actor pattern over Claude Code"
created_at: 20260424-000000
created_by: Claude Code (Claude Opus 4.7, 1M context)
updated_by: Claude Code (Claude Sonnet 4.6)
updated_at: 2026-05-19--16-28
context: >
  Reference architecture for Claude Orchestra — a three-tier orchestration
  pattern layered on Claude Code using native subagents. The design supports
  fully autonomous review loops and operates across multiple machines via NFS.
  This is the summary document; for implementation history and deferred items,
  see design-history.md, resources.md, and TODO.md.
---

# Claude Orchestra

A three-tier orchestration system for Claude Code: **Brain** (Opus 4.7 or Sonnet 4.6) delegates reasoning, implementation, and review across **Planner** (Sonnet 4.6), **Actor** (Haiku 4.5), and **Reviewer** (Sonnet 4.6) tiers using Claude Code's native `Task` tool for subagent dispatch. Single global install at `~/.claude/`; usable from any project.

## Intro

Claude Orchestra solves the cost/capability trade-off for multi-step code work. A single powerful Brain (Opus 4.7) orchestrates cheaper specialized tiers: a read-only Planner for structured reasoning, a write-capable Actor for implementation, and a read-only Reviewer for quality gates. The key design choice: **Option B — native Claude Code subagents, not separate processes** — which keeps the architecture simple and preserves permission modes and plan-approval gates.

Use it when you want code changes reviewed before landing, or when you want to isolate reasoning from implementation for cost control.

## How to use it

### Interactive conversation (default)

Talk to Brain normally. Brain delegates to Planner/Actor/Reviewer as needed. No forced pipeline. Example: "explain the SoHoAI routing architecture" — Brain reads files and answers directly.

### /duo — lightweight (Sonnet plans, Haiku acts), session-bracketed

`/duo` is a three-command session-bracketed pipeline. `/duo-plan <task>` opens a planning session (sets up the session_dir, drafts an initial `PLAN.md`, and yields back). The operator then refines the plan across as many normal plan-mode turns as needed. `/duo-act` commits the plan, calls `ExitPlanMode`, dispatches Actor (Haiku), and runs cleanup + telemetry. `/duo-abandon` cancels the active session cleanly. No Reviewer. Example: "add a docstring to rag_engine/search.py::search_rag" — low risk, no review needed.

Workflow: (1) `claude --model claude-sonnet-4-6`. (2) `Shift+Tab` to enter plan mode. (3) `/duo-plan <task>`. (4) Refine across turns until the plan is right. (5) `/duo-act` to execute (or `/duo-abandon` to cancel); on approval, `Shift+Tab` to bypassPermissions if desired, Actor runs uninterrupted.

Splitting the plan-approval gate into an explicit `/duo-act` (rather than the slash command barrelling through to `ExitPlanMode` in one response) means rejection-or-redirect during planning is now first-class: refinement is a normal multi-turn conversation, not a rejected-plan-and-informally-keep-chatting situation. Telemetry attribution stays correct because `.outcome`-file mtime bounds the T2 time window (see §Telemetry).

### /brain — full pipeline (Opus orchestrates, cap-3 review loop)

Enter plan mode, type `/brain <task>`. Opus runs Phase 0 (RESEARCH, inline — interrogates you across as many turns as needed; the operator's natural-language signal — "proceed", "go ahead" — ends Phase 0), then Phase 1 (PLAN via Planner), Phase 2 (IMPLEMENT via Actor, one step at a time), Phase 3 (REVIEW via Reviewer, loop up to 3 times). Example: "refactor the SoHoAI LiteLLM routing to support a new provider" — high-risk, multi-step, needs review loop.

`/brain-abandon` cancels the active /brain session cleanly at any point — writes `.outcome=abandoned`, removes the inflight marker, runs T2 telemetry, and clears the badge. The cleanup block also runs automatically on Phase 0 abandonment ("never mind", "drop it"), Phase 1 outright rejection at the plan-approval gate, and Phase 3 BLOCK verdict — so every exit path bounds the T2 telemetry window.

**Pipeline-rules guard (2026-05-05):** plan-mode and `/brain` give Brain conflicting instructions about who produces the plan — plan-mode's per-turn "build your plan in `~/.claude/plans/<name>.md` using Write" reminder out-competed `/brain.md`'s loaded-once "dispatch Planner via Task tool" instruction in long Phase 0 sessions, causing Brain to write the plan and execute the implementation directly under Opus 4.7. Hybrid fix: (a) `commands/brain.md` reinforced with an explicit override clause, concrete `Task`-tool dispatch templates at the top of each Phase, a self-check guard, phase-boundary reinforcement, and a negative-examples block; (b) a per-turn guard block at `claude-md-block/orchestra-guard.md` injected by `deploy.sh` into `~/.claude/CLAUDE.md` between sentinels `<!-- ORCHESTRA_GUARD_START -->` / `<!-- ORCHESTRA_GUARD_END -->`. The CLAUDE.md guard is the load-bearing component because it loads on every turn (parallel to plan-mode's reminder cadence), while `/brain.md` reinforcement makes the command body self-coherent. Cost overhead is < 5% of typical /brain session due to prompt caching of stable system-prompt content.

**`/duo-plan` setup-bash override (2026-05-06):** the same plan-mode override conflict affects `/duo-plan`'s setup phase: plan-mode's "MUST NOT run non-readonly tools" clause suppressed the refusal-check and session-dir-creation bash calls, meaning `.duo-inflight` was never written, /duo mode never activated, and the session ran as plain plan mode + direct edits. Fix: `commands/duo-plan.md` now opens with a prominent `PLAN-MODE OVERRIDE` callout at line 11, before `## When to use /duo vs /brain`, explicitly exempting the setup bash calls (lifecycle management, not code edits) from the plan-mode restriction.

When NOT to use /brain: simple tasks with ≤5 steps, low blast radius. Use /duo instead.

## How the workflow works

### Agents

| Agent | Model | File | Tools | Role |
|---|---|---|---|---|
| **Brain** | Opus 4.7 (or Sonnet for /duo) | — (main session) | all | Orchestrates; calls `ExitPlanMode` at plan approval (G2) |
| **Planner** | `claude-code-deepseek-v4-pro` | `~/.claude/agents/planner.md` | Read, Grep, Glob, WebFetch, TodoWrite (read-only) | Decomposes task into numbered plan; Brain persists to PLAN.md; Sonnet 4.6 via `planner-long` for >30 KB inputs |
| **Planner** (long) | Sonnet 4.6 | `~/.claude/agents/planner-long.md` | Read, Grep, Glob, WebFetch, TodoWrite (read-only) | Fallback for large inputs (>30 KB); preserves Anthropic cache discount |
| **Actor** | `claude-code-qwen3-coder-next` | `~/.claude/agents/actor.md` | Read, Edit, Write, Bash, Grep, Glob (+ denies on rm -rf, git push) | Executes one step per invocation; self-persists TASKS.json via atomic-rename |
| **Actor** (heavy) | `claude-code-kimi-k2.6` | `~/.claude/agents/actor-heavy.md` | Read, Edit, Write, Bash, Grep, Glob (+ denies on rm -rf, git push) | Complex multi-file refactors; triggered by `[tier: heavy]` step annotations |
| **Reviewer** | Sonnet 4.6 | `~/.claude/agents/reviewer.md` | Read, Grep, Glob, TodoWrite (read-only) | Reviews diff against PLAN.md; returns PASS / FIX / BLOCK |

### Model requirements

| Command | Minimum | Recommended | Enforcement |
|---|---|---|---|
| `/brain` | Sonnet 4.6 | Opus 4.7 | Hard block — Brain reads model ID from system context and refuses to proceed if below minimum |
| `/duo` | none | Sonnet 4.6 | Advisory only — Brain warns and continues |

Both checks happen at command startup before any Bash or setup runs. The check is LLM-enforced (Brain reads "The exact model ID is…" injected by Claude Code into every session's system context) — same trust level as the plan-mode gate. See TODO.md for the hook-based upgrade path when `$CLAUDE_MODEL` becomes available.

### Sequential Phase Architecture & gates

| Phase | Gate before | Policy | Mechanism |
|---|---|---|---|
| 0 RESEARCH | PLAN | skip | Brain interrogates operator inline (Brain only, not separate agent) |
| 1 PLAN | IMPLEMENT | **approve (required)** | **`ExitPlanMode` called by Brain — NOT by Planner** |
| 2 IMPLEMENT | REVIEW | follow permission mode | Standard Claude Code approval UX per tool |
| 3 REVIEW | LOOP/DONE | **auto-loop, cap 3** | Brain counts; surfaces PASS/FIX/BLOCK verdict |

RESEARCH is served by Brain itself (with user input) or by built-in `Explore` subagent. No dedicated Researcher agent in v1.

### Autonomy presets

Two presets fully wired in v1; third is a stub:

| Preset | Permission mode | Review loop | When to use |
|---|---|---|---|
| `default` | default (per-edit prompts) | auto-loop cap 3 | all interactive work; user reviews each edit |
| `acceptEdits` | bypassPermissions (no prompts) | auto-loop cap 3 | low-risk tasks; full automation of edits |
| `auto` (v2 stub) | bypassPermissions | checkpoint commits + CROSS-CHECK + test gate | unattended runs; NOT implemented in v1 |

No `/orchestra-mode` command in v1 (`auto` is deferred to v2).

## Design details

### Hooks

Five hook types in `~/.claude/settings.json`, dispatching to `~/.claude/scripts/orchestra-hook.sh`:

1. **PreToolUse(Agent)** — `start` mode. Logs subagent invocation to invocations.log.
2. **SubagentStop** — `end` mode. Logs subagent completion.
3. **PreCompact** — `compact` mode. Saves `brain-state.md` (plan/task/decision snapshot for resumption post-`/clear`).
4. **Stop** — `stop` mode (safety net). Fires at the end of **every response turn** (not only on process exit). Walks session_dirs that have no `telemetry.json` **and** no inflight marker — i.e., sessions where cleanup already started (inflight markers removed by `/duo-act`/`/duo-abandon`/`/brain`) but `telemetry-summarize.sh` failed to write `telemetry.json`. Gate (updated 2026-05-06): skip if `.duo-inflight` or `.brain-inflight` is present (session still in-progress — removing the marker here would destroy the badge and cause `NO_SESSION` errors on the next refinement turn); then check for artefacts (`PLAN.md`, `RESEARCH.md`, `telemetry-events.jsonl`). Writes `.outcome=abandoned` before invoking the summariser (mtime bounds the T2 window), and resets `state.env` when finalising a /brain session so the badge clears. Inflight marker removal is the exclusive responsibility of `/duo-act`, `/duo-abandon`, and `/brain`/`/brain-abandon` cleanup.
5. (No tool-call hooks; subagent tool dispatch is opaque by design.)

### Status line

The Claude Code status line is extended by `status-line/orchestra-block.sh`, injected into `~/.claude/scripts/status-line.sh` at deploy time via the `# ORCHESTRA_BLOCK_START` / `# ORCHESTRA_BLOCK_END` sentinels.

#### What it displays

The orchestra block produces a **full status line layout** (not just a badge). It replaces the CC-native progress bar and token-count fields and inserts its own fields immediately after the model name:

```
model | ctx ▓▓▓▓░░░░░░░░░░░░░░░░ 21% 210K/1M | ~$X.YZ | ◆ project | ⎇ branch | [♪ badge]
```

Fields injected by the orchestra block:

**`ctx`** — context window utilization (always shown). Colored 20-cell bar (1 cell = 5%), percentage, and token usage. Example: `ctx ▓▓░░░░░░░░░░░░░░░░░░ 12% 24K/200K` (green). Color thresholds:
- **Green**: < 50% utilization
- **Yellow**: 50–79% utilization
- **Orange**: ≥ 80% utilization

The utilization denominator is looked up from `context-windows.yaml` per model ID, with fallback to Claude Code's native `context_window.context_window_size`. Model ID normalization strips `[1m]`, `[200k]`, and date suffixes before lookup. Models with `[1m]` in their ID force a 1,000,000 denominator.

**Non-Anthropic models (`claude-code-*`).** Claude Code does not report token counts for non-Anthropic models (e.g. `claude-code-kimi-k2.6`). A SoHoAI fallback reaches into `usage_events` via `query_sohoai_usage()` in `scripts/telemetry-summarize.py` and `sohoai-live-cost.sh`. Key constraints:
- **Latest request only**: the fallback reads `latest_total_tokens` (size of the most recent API request), NOT cumulative tokens across all turns — cumulative would produce absurd percentages (14M/256K ≈ 5500%).
- **Model-scoped**: query uses `model = ? OR model LIKE ?` (e.g. `kimi-k2.6` matches `kimi-k2.6:cloud` in the DB). Source filter is intentionally omitted because SoHoAI's LiteLLM callback tags non-Anthropic models with `source='unknown'`.
- **Time-scoped**: `created_at >=` from the `.lck` `started_at` field isolates this session's requests from other concurrent or prior sessions with the same model.
- **Denominator consistency**: percentage and display both use `context-windows.yaml` as the denominator. Without this fix CC's `context_window_size` for non-Anthropic models would report ~200K for a 256K-window model, inflating the percentage to 101%.
- **TTL**: 8 s, so the token bar updates every ~8 s rather than continuously (sufficient for a progress indicator).

**`~$X.YZ`** — live running cost (always shown, including `~$0.00` from the very first render so the display is visibly live from session start). Source differs by session type:
- **Orchestra sessions**: SoHoAI `usage_events` table query via SQLite direct read (primary, NFS-accessible) or HTTP API fallback (TTL=8 s cache). Stale cache marked `*`. No `(est)` fallback — JSONL is not used (SoHoAI-proxied sessions do not write `costUSD` to JSONL entries).
- **Native sessions (no recent orchestra)**: `cost.total_cost_usd` from CC's own `statusLine` JSON input — precise, always current, no external query needed. Last non-zero total (parent + subagents) is written to `active-sessions/<session>.cost-cache` (atomic rename); when CC reports 0 at tool-call turn boundaries the cached value is shown instead, keeping the field continuously visible.
- **Native sessions (after orchestra session ends in same project)**: `cost_usd_estimate` from the most recent `telemetry.json`, shown instead of the CC JSON estimate — authoritative (SoHoAI subagents + T2 parent). Guard: `telemetry.json` mtime must be strictly greater than the native session's `.lck` mtime (proves the pipeline ended *during* this session, not before). If the `.lck` does not exist yet (`mtime=0`), falls back to CC JSON. This prevents false positives when a new session is opened after an orchestra session ends.

**`♪ badge`** — orchestra session badge (shown only during active /duo or /brain sessions, or when a subagent is running). Badge formats in descending priority:

| Condition | Badge |
|---|---|
| `/duo` session active (one) | `♪ orchestra -> plan <title>  [▶ stage]` |
| `/duo` sessions active (many) | `♪ orchestra -> plan #N` |
| `/brain` session active | `♪ orchestra -> brain <title>  [▶ stage]` |
| Subagent running (no /brain or /duo context) | `♪ orchestra  ▶ stage` |
| No orchestra activity | *(nothing — orchestra block is silent for badge)* |

#### When it updates

The status line script is called by Claude Code on each render tick — after every model turn and when tool calls are shown in the UI. **The active-subagent indicator (`▶ stage`) appears in real-time**: the `PreToolUse(Agent)` hook writes the `start` event to `invocations.log` *before* the Task tool executes, so the indicator is already present by the time the subagent begins running.

#### Data sources

| Signal | Source | Written by |
|---|---|---|
| `/duo` title and inflight state | `${SESSION_DIR}/.duo-inflight` | `/duo-plan` command setup |
| `/brain` title and mode | `.claude/orchestra/state.env` (`ORCHESTRA_MODE=brain`, `ORCHESTRA_TITLE=…`) | `/brain` command setup |
| `/brain` inflight marker (session-discovery for `/brain-abandon` and explicit CMD-classification by Stop-hook) | `${SESSION_DIR}/.brain-inflight` | `/brain` command setup |
| Active subagent stage | `.claude/orchestra/invocations.log` (last `start` event with no matching `end`) | `orchestra-hook.sh start` (PreToolUse) |
| Live cost (orchestra) | SoHoAI `usage_events` SQLite (direct) → HTTP API fallback via `sohoai-live-cost.sh` (TTL=8 s) | T2 via SoHoAI API |
| Live cost (native) | `cost.total_cost_usd` from CC `statusLine` JSON input | CC accumulates cost internally |
| Live cost (ctx segment) | `context_windows.yaml` + CC context width | ctx-segment.sh |

#### ctx segment implementation details

The ctx segment uses `scripts/ctx-segment.sh` which reads `context-windows.yaml` from `~/.claude/orchestra/`. Model ID normalisation strips `[1m]`, `[200k]`, and `-YYYYMMDD` suffixes before lookup. If the original ID contains `[1m]`, the denominator is forced to 1,000,000 regardless of the map entry.

Bar: 20 cells, each representing 5% of the context window (filled `▓`, empty `░`). Prior to 2026-05-12 the bar was 10 cells at 10% each; prior to 2026-05-11 it was 8 cells at 12.5% each.

Token formatting: values ≥ 1,000,000 show as `XM` (e.g., `1.2M`), values ≥ 1,000 show as `XK`, otherwise raw `XK`.

**CC/API [1m] context window mismatch (2026-05-19, commits a2a70c7 + dd8dba0).** `[1m]` is a CC-local shorthand that routes `claude-sonnet-4-6` requests to a 1M-context deployment tier server-side via API parameters (beta headers or access flags). The Anthropic API always returns the canonical model name `claude-sonnet-4-6` with `context_window: 200000` in its response metadata — the 1M routing is invisible to the API's model spec. CC uses the configured model for its **initial** status-line render (reports `context_window_size=1000000`), but updates from the API response on subsequent renders, losing the `[1m]` indicator. Two symptoms result: (1) the display name reverts from "Sonnet 4.6 (1M context)" to "Sonnet 4.6"; (2) `used_percentage` is computed against 200K (e.g., 82K tokens → 41%), while the `ctx` denominator field still shows 1M — an inconsistent "41% 82K/1M".

**Why this is Sonnet 4.6-specific:** Opus 4.7 (`claude-opus-4-7`) has 1M as its canonical API context window — the API itself returns `context_window: 1000000`, so no mismatch occurs. The `[1m]` shorthand exists only for Sonnet 4.6 because Sonnet's standard spec is 200K and the 1M tier is an extended capability, not the default. Future models that include 1M as their native API spec would not be affected.

**Workaround (not a CC fix — CC behaviour is unchanged):**
1. `orchestra-block.sh` reads `settings.json` (project-level, then global) after extracting `model_id` from CC JSON. If the configured model contains `[1m]` and `model_id` does not, but the base model matches (mapping CC shorthands: `sonnet` → `claude-sonnet-4-6`, `opus` → `claude-opus-4-7`, `haiku` → `claude-haiku-4-5`), it re-appends `[1m]` to `model_id`. A follow-on bash substitution also restores "(1M context)" in the already-built `status_line` display name string.
2. `ctx-segment.sh` recalculates `used_pct` after `advertised_size` is finalised: when `forced_1m=true` and `tokens > 0`, `used_pct = 100 * tokens / advertised_size`. This ensures bar fill, percentage, and denominator are all derived from the same 1M denominator.

#### CC statusLine JSON schema (CC 2.1.139+)

CC passes a rich JSON object to the `statusLine` command on every render. Key fields used by the orchestra block:

| Field | Type | Notes |
|---|---|---|
| `session_id` | string | CC session UUID — used directly for native cost display; no `.lck` check |
| `transcript_path` | string | Absolute path to this session's JSONL transcript |
| `session_name` | string | Human-readable session name (set via `/rename`) |
| `cost.total_cost_usd` | float | Precise accumulated session cost (all subagents included) |
| `model.id` / `model.display_name` | string | Model identifier and display name |
| `context_window.*` | object | Token counts and utilization percentage |
| `workspace.current_dir` | string | Session working directory |
| `version` | string | CC version string |

`session_id` identifies the native session for cost display directly — no `.lck` file check. The `.lck` is only for session finalization (Stop hook → `native-session-finalize.py` → T2 record); removing it from the cost gate fixes resumed sessions (Stop hook removes the old lck at end of each turn; no new lck until the first Bash call). `cost.total_cost_usd` is used as the live cost — precise, always current, no SoHoAI query needed.

#### SoHoAI live cost (orchestra sessions only)

SoHoAI cost for orchestra sessions is retrieved via `scripts/sohoai-live-cost.sh`:

**Primary: SQLite direct read**
- Reads `usage_events` table from SoHoAI's SQLite DB at `sohoai.db_path` in `config.yaml` (or `SOHOAI_DB_PATH` env var)
- Query: `SELECT SUM(cost_usd) FROM usage_events WHERE orchestra_session_id = ?`
- No time filter needed — `orchestra_session_id` uniquely identifies the session
- Instant (<5 ms), no HTTP overhead, no timeout risk
- Returns the running accumulated cost (same data as SoHoAI HTTP API)

**Fallback: SoHoAI HTTP API**
- Fires only when SQLite DB is unavailable/unconfigured
- `started_at` is derived from `.transcript-path` mtime (written once at session init), NOT from the passed `started_at_unix` (which is the session dir mtime — updated on every file write, effectively always near-now, which caused the original oscillation)
- 1s timeout; stale cache returned with trailing `*` on failure

**Why `costUSD` JSONL is not used**
Sessions routed through SoHoAI proxy do not receive a `costUSD` field in JSONL entries (CC only writes this when calling Anthropic directly). Token-based estimation from pricing.yaml overcounts by ~55% because SoHoAI/LiteLLM applies different effective cache_read rates. The SQLite DB contains SoHoAI's own billing records and is the authoritative source.

**TTL**: 8 s (cache hit < 50 ms). Stale cache marked `*`.

Native sessions bypass this path entirely and use `cost.total_cost_usd` from the JSON input instead.

Model ID lookup in `context-windows.yaml` uses:
- Primary: exact `model.id` match
- Fallback: `display_name` (lowercase, hyphenated, sans parentheses)

#### Deploy / portability

`status-line/orchestra-block.sh` is a **portable standalone snippet** — it defines its own color variables so it can be dropped into any host status-line script. `deploy.sh` strips the old block and re-injects the current source whenever the two diverge, making status-line updates idempotent.

### NFS / cross-machine

All state at `~/.claude/` is shared via NFS symlink (`~/.claude → /mnt/nfs/Florian/Gin-AI/.claude`), so agents and config are instantly visible on all Debian hosts.

Per-project state (`PLAN.md`, `TASKS.json`, logs) lives at `${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions/<UTC-timestamp>-<PID>/` — per-invocation isolation.

Concurrency safety via hostname + PID + timestamp stamping in log lines; atomic-rename for state files; no lock sentinel in v1.

### File inventory

**Global (~/.claude/):**
```
agents/
  planner.md, actor.md, reviewer.md
commands/
  brain.md, brain-abandon.md
  duo-plan.md, duo-act.md, duo-abandon.md
scripts/
  orchestra-hook.sh, ctx-segment.sh, sohoai-live-cost.sh
orchestra/
  config.yaml, context-windows.yaml
  invocations.log (append-only)
CLAUDE.md  (sentinel-bracketed orchestra-guard block injected by deploy.sh
            from claude-md-block/orchestra-guard.md in the repo)
```

**Per-project (.claude/orchestra/):**
```
sessions/
  <UTC-ts>-<PID>/
    PLAN.md, TASKS.json, review-comments.md
    .duo-inflight          (present during /duo planning phase + execution; removed by /duo-act or /duo-abandon)
    .brain-inflight        (present throughout /brain Phase 0/1/2/3; removed by cleanup block or /brain-abandon)
    .last-logfile          (sidecar: hook start writes logfile path; end reads+deletes)
    .outcome               (pass | block | partial | abandoned)
    telemetry-events.jsonl (T1 live hook stream)
    telemetry.json         (T2 final record, written at cleanup)
    logs/
      <stage>-<UTC-ts>-<HOST>-<PID>.log  (auto-deleted after 30 days)
state.env          (ORCHESTRA_MODE + ORCHESTRA_TITLE, append-only)
invocations.log    (subagent start/end events, append-only)
brain-state.md     (pre-compact snapshot)
```

### Cost model

Mixed-tier pricing; orchestration overhead is paid by Brain (Opus is ~7–10× Haiku):

- **Brain** (Opus 4.7): most expensive; receives every subagent's return. Mitigated by prompt caching + `PreCompact` hook saving state.
- **Planner** (Sonnet): called once per plan.
- **Actor** (Haiku): called once per step (cheap).
- **Reviewer** (Sonnet): called once per review (up to 3 per step).

Rule of thumb: use `/brain` for tasks where the review loop actually earns the Brain overhead (architecture, multi-file refactors). Use `/duo` for simple, low-risk tasks.

### Disabling and troubleshooting

**Global disable**: `mv ~/.claude/scripts/orchestra-hook.sh{,.bak}` (intentionally loud; next `claude` invocation will fail visibly).

**Full uninstall**: `rm -rf ~/.claude/agents/{planner,actor,reviewer}.md ~/.claude/commands/{brain,duo}.md ~/.claude/scripts/orchestra-hook.sh ~/.claude/orchestra/`, then edit `~/.claude/settings.json` to remove hook entries.

Quick-ref troubleshooting:

| Symptom | Likely cause | Check |
|---|---|---|
| Status-line badge doesn't appear | `config.yaml` missing or `cwd` unset in status-line input | `ls ~/.claude/orchestra/config.yaml`; run `status-line.sh` manually with test JSON |
| `PLAN.md` garbled | Atomic-rename not used — direct write instead | Inspect for `.tmp` sibling; check Planner prompt |
| `/brain` command unrecognised | `~/.claude/commands/brain.md` missing or malformed | `/help` lists commands; inspect file frontmatter |
| `.last-logfile.*` files accumulating in `orchestra/` | Old bug: sidecar used PID of hook process so `end` could never find and delete `start`'s file | Fixed: sidecar now lives in session dir (shared path for start and end); stale files auto-cleaned after 120 min at hook startup |
| `logs/*.log` growing unbounded | No rotation | Auto-rotated at hook startup: files older than 30 days deleted |
| `~$X.YZ` cost never appears | T1 hook not writing to `telemetry-events.jsonl` | Check `orchestra-hook.sh` is executable and wired in `settings.json` |

### Deviations from canonical Claude Code

Aligned with canonical:
- Subagent definitions (`.claude/agents/*.md` with frontmatter)
- Hooks (`PreToolUse`, `SubagentStop`, `PreCompact`)
- Permission modes (`default` / `acceptEdits` / `plan` / `bypassPermissions`)
- Slash commands (`.claude/commands/*.md`)
- Plan approval via `ExitPlanMode`

Deliberate deviations:
- **Custom state dir `.claude/orchestra/`** — pragmatic co-location with other Claude Code config.
- **Per-invocation subdirs** — isolation and lazy cleanup (30-day retention).
- **Atomic-rename pattern** — POSIX standard, documented in prompts, not enforced at hook level.
- **Pinned model snapshots** — `claude-sonnet-4-5`, `claude-haiku-4-5-20251001` (no auto-upgrade).

### Live feed limitations

Hooks fire at tool-call boundaries only. They capture *what the subagent is doing* (Edit/Write/Bash calls) but **not** *why* (thinking blocks) or *what it sees* (tool results). Full live feed would require a Claude Code streaming hook (not available in v1) or subagents running as separate `claude -p` processes (Option A, rejected in favor of simplicity).

See design-history.md §13.3 for three potential approaches to close the gap.

---

## Telemetry

### Rationale

Multi-tier orchestration has a non-obvious cost structure. Brain (Opus or Sonnet) dominates by token volume — it re-sends its full context every turn (cached after the first hit, but still billed at the cache-read rate of the most expensive model) and receives all subagent returns. Planner and Reviewer (Sonnet) are single-call-per-phase. Actor (Haiku) is cheap per token but may iterate. Without measurement, cost/quality trade-offs are guesses: which tier to change? which phase to skip? does the built-in `Explore` subagent justify a dedicated cheaper Researcher agent? Telemetry makes those decisions data-driven (see `TODO.md §0` for the full decision-gate framework).

Every `/brain` and `/duo` run is instrumented post-hoc by `scripts/telemetry-summarize.{sh,py}`, invoked from each command's cleanup block. Native (non-orchestra) CC sessions are tracked automatically via `bash-session-init.sh` (sourced on every Bash tool call through `BASH_ENV`) and finalized by the Stop hook — see §Native session tracking below.

Two complementary approaches cover the full cost picture. They are tried in priority order; the first to return a non-zero value is used.

---

### Approach 1 — Local JSONL (T1 + T2 hybrid)

**Prerequisite:** works with **any** Anthropic API endpoint — direct or proxied — as long as JSONL transcripts are written locally by Claude Code under `~/.claude/projects/`. No proxy required.

#### How it works

Two layers instrument every orchestra session:

**T1 — hook-based, real-time.** `orchestra-hook.sh` appends one JSON event per subagent dispatch / completion to `${SESSION_DIR}/telemetry-events.jsonl`. Captures subagent type, timing, and stage identity. Token counts are always `null` (hook payloads do not expose them). T1 drives the live `~$X.YZ` status-line badge.

**T2 — transcript parsing, authoritative.** Runs once at cleanup. `telemetry-summarize.py` walks all `*.jsonl` files in the project's transcripts directory whose records fall within the session time window — capturing content split across multiple JSONLs by `--fork-session` or `/clear`-induced UUID rotation. For each in-window parent JSONL, it walks `<uuid>/subagents/agent-*.jsonl` (subagent transcripts), attributed via `agent-*.meta.json` sidecars (`{"agentType": "…"}`). Token counts accumulate across all contributing JSONLs; USD cost is computed via the cost-source cascade (see §Cost-source cascade).

T2 writes:
- `${SESSION_DIR}/telemetry.json` — rich per-session record: parent + subagent tokens per tier, USD cost estimate (`cost_usd_estimate` = `subagent_cost_usd` + `parent_cost_usd` when source is SoHoAI), iteration counts, outcome, `cost_source`, `parser_warnings`.
- `~/.claude/orchestra/telemetry.jsonl` — global append-only trend log; one line per session (includes `session_dir` for cross-project lookup).
- T2 supersedes T1 for all cost figures.

**T2 time window:** `[started_at, ended_at]`. `started_at` is parsed from the session-dir basename (`<YYYYMMDDTHHMMSSZ>-<PID>`). `ended_at` is the mtime of `${SESSION_DIR}/.outcome` when present, falling back to `time.time()`. All exit paths — `/duo-act`, `/duo-abandon`, `/brain` cleanup (all verdicts), `/brain-abandon`, and the Stop-hook safety net — write `.outcome` before invoking the summariser. This makes the window deterministic and re-runs of the summariser idempotent (the window does not expand to "now").

**Safety net:** the `Stop` hook runs T2 on session dirs where cleanup started (inflight markers already removed) but `telemetry.json` was never written. Sessions that still have `.duo-inflight` or `.brain-inflight` are skipped — they are in-progress.

---

### Native session tracking

Native (non-orchestra) CC sessions are tracked via a two-step mechanism that avoids the need for any per-request header or proxy instrumentation.

**Registration — `scripts/bash-session-init.sh` (sourced via `BASH_ENV`).**
Claude Code sets `CLAUDE_CODE_SESSION_ID` in the environment of every Bash tool call, but not in hook subprocesses. `bash-session-init.sh` exploits this: it is sourced automatically at the start of each Bash tool call (via `BASH_ENV=/home/florian/.claude/scripts/bash-session-init.sh` in `settings.json`). On the first call it writes a `.lck` file to `~/.claude/active-sessions/native-<UUID>.lck` containing:

```
cc_pid=<stable-claude-PID>
session_id=native-<UUID>
started_at=<ISO8601>
session_uuid=<UUID>
```

`cc_pid` is the stable top-level `claude` process — found by checking if `$PPID.comm == "claude"` (normal case) or walking one level up (if PPID is a transient node subprocess). The script is a no-op for subsequent calls (file already exists) and skips orchestra sessions (`.brain-inflight` / `.duo-inflight` present — handled by orchestra telemetry instead). The UUID serves as the primary key; the PID is stored solely for liveness detection.

**Status-line identification.** The `statusLine` command subprocess does not receive `CLAUDE_CODE_SESSION_ID` as an env var (unlike Bash tool call subprocesses). Session identification for the live cost display uses `session_id` from the CC `statusLine` JSON input instead — no PID walking, no env vars. See §CC statusLine JSON schema.

**Finalization — `scripts/orchestra-hook.sh` stop mode.**
The Stop hook fires per response turn. It iterates all `native-*.lck` files and for each runs `kill -0 <cc_pid>`. If the process is dead the session has ended: it invokes `native-session-finalize.py` (T2 cost attribution via the cost-source cascade) and removes the `.lck`. Since `CLAUDE_CODE_SESSION_ID` is not available in hook context, finalization of session N is triggered by the Stop hook of session N+1 — typically within seconds of the user opening a new session. Edge case: if no new session is opened after session N ends, the `.lck` persists until the next CC session starts. `session-report.py` guards against this by calling `os.kill(cc_pid, 0)` in `load_active_native_sessions()` and silently skipping any stale entry whose process is already dead.

**Re-finalization and dedup (2026-05-12).** `native-session-finalize.py` writes atomically via a `.tmp` rename and strips any prior record for the same `session_id` before writing, so a re-run (e.g. manual finalize followed by a Stop-hook finalize) produces exactly one authoritative record. `session-report.py`'s `load_native_telemetry()` additionally deduplicates on read (last record per `session_id` wins) as a safety net for records written before this fix.

**Cross-source dedup — orchestra-parent suppression (2026-05-14).** When `/brain` or `/duo` runs, the parent CC process registers as a native session (via `bash-session-init.sh`) AND is finalized as an orchestra session. Both have the same `started_at` timestamp (the orchestra session ID encodes the start time; `bash-session-init.sh` records the same value in the `.lck`). Two fixes prevent double-counting:
- `native-session-finalize.py` skips writing a native record if `started_at` already appears in `~/.claude/orchestra/telemetry.jsonl` — prevents future duplicates from accumulating in source files.
- `session-report.py` filters out native records whose `started_at` matches any orchestra record at display time — retroactively fixes historical duplicates already in the JSONL files.
`session-report.py`'s `load_orchestra_telemetry()` also deduplicates by `session_id` (last record wins), mirroring the same pattern in `load_native_telemetry()`.

**Session IDs.** Native session IDs written by `bash-session-init.sh` are `native-<UUID>` (e.g. `native-6dedcd3d-37e5-46a9-958e-fb0a822b5e3a`). The UUID is the CC session UUID (`CLAUDE_CODE_SESSION_ID`), making IDs globally unique and stable. Older sessions (before the UUID-keyed registration refactor, 2026-05-07) used a `native-<timestamp>-<PID>` format; both formats are stored in `~/.claude/native-sessions/telemetry.jsonl` and handled by the report scripts.

**Telemetry record fields** (written to `~/.claude/native-sessions/telemetry.jsonl`):

| Field | Description |
|-------|-------------|
| `session_id` | `native-<UUID>` |
| `command` | always `"native"` |
| `started_at` | ISO8601 timestamp from `.lck` creation |
| `ended_at` | ISO8601 timestamp at finalization |
| `duration_s` | wall-clock seconds |
| `cost_usd_estimate` | parent + all subagent costs (from cost-source cascade); `0.0` for non-Anthropic (zero-rate) models |
| `cost_source` | `sohoai_api` / `litellm` / `pricing_yaml` / `none` |
| `model` | parent session model name (present when transcript was parsed — both Anthropic and non-Anthropic) |
| `total_tokens` | parent session token count (present when transcript was parsed; excludes subagent tokens) |

**Non-Anthropic models.** Sessions using SoHoAI proxy models not in `pricing.yaml` (e.g. `claude-code-qwen3-coder-next`, `claude-code-kimi-k2.6`) are recorded with `cost_usd_estimate: 0.0` and `cost_source: "pricing_yaml"` — the transcript was successfully parsed and the model identified, but no pricing rate is available. `session-report.py` renders these as `$0.0000` to distinguish them from sessions where cost attribution failed entirely (`cost_source: "none"`, displayed as `-`). For past records already in `telemetry.jsonl` with a missing `model` field (written before the 2026-05-11 finalize-script fix), `session-report.py` retroactively re-reads the JSONL transcript at display time to fill in the model name.

**Reporting.** `native-session-report.py` reads from two sources and merges them (deduplicating by `session_id`, telemetry takes precedence, sorted newest-first):
1. `~/.claude/native-sessions/telemetry.jsonl` — primary; contains all sessions finalized since 2026-05-07.
2. `~/.claude/usage-data/session-meta/*.json` — legacy; populated by CC < 2.1 (April 2026 and earlier); no longer updated by CC 2.1.132.

For sessions with a `native-<UUID>` session ID, the report also looks up the transcript JSONL to obtain per-type token breakdown and project name. For old-format `native-<timestamp>-<PID>` sessions, `total_tokens` from the telemetry record is used directly and project name shows as `native`. `session-report.py` (unified report) applies the same project-name lookup for native sessions, using `*.project-name` sidecar files and NFS path unmangling. `native-session-report.py` defaults to 20 sessions when no date filter is given; when `--since` or `--month` is active and `--last` is not explicitly set, no cap is applied (all matching sessions are shown).

**Requirement.** `BASH_ENV=/home/florian/.claude/scripts/bash-session-init.sh` must be set in `settings.json` env. This is **not** managed by `deploy.sh` — it must be set manually or persisted in `settings.json`. Without it, `bash-session-init.sh` is never sourced and no `.lck` is written; native sessions appear as `cost_source: "none"` with zero cost.

#### Inspecting per-session data

```bash
# T1 live events for an orchestra session (timing and stage identity; usage=null)
cat ~/.claude/orchestra/sessions/<session-id>/telemetry-events.jsonl

# T2 authoritative per-session record
cat ~/.claude/orchestra/sessions/<session-id>/telemetry.json | jq .

# Verify T1 and T2 captured correctly after a /duo or /brain run
./scripts/smoke-test.sh

# Check the global orchestra trend log
tail -20 ~/.claude/orchestra/telemetry.jsonl | jq .

# Check native session records
tail -10 ~/.claude/native-sessions/telemetry.jsonl | jq .
```

#### Summary reports

```bash
# Tabular summary of recent orchestra sessions
~/.claude/scripts/telemetry-report.sh --last 10

# Per-tier breakdown + cumulative totals across recent sessions
~/.claude/scripts/telemetry-report.sh --last 10 --tier

# Native CC sessions only — merges native-sessions/telemetry.jsonl (primary, post-2026-05-07)
# and legacy usage-data/session-meta/ (pre-2026-05-07); newest sessions at top
~/.claude/scripts/native-session-report.sh --last 10
~/.claude/scripts/native-session-report.sh --last 10 --tier
~/.claude/scripts/native-session-report.sh --since 2026-05-01

# Unified report: native + orchestra sessions in one table (most useful day-to-day)
~/.claude/scripts/session-report.sh --last 10
~/.claude/scripts/session-report.sh --source orchestra
~/.claude/scripts/session-report.sh --source native
~/.claude/scripts/session-report.sh --since 2026-05-01
~/.claude/scripts/session-report.sh --month 2026-05
```

---

### Approach 2 — SoHoAI proxy (LiteLLM)

**Prerequisite:** API calls must be routed through the [SoHoAI](https://sohoai.org) LiteLLM proxy (`ANTHROPIC_BASE_URL` set to the SoHoAI endpoint). Without this, the SoHoAI API query returns nothing and the system falls back to Approach 1 cost calculation transparently.

#### How it works

SoHoAI tracks cost per API call server-side, attributed by a session header injected into every outbound request. Each `/brain` and `/duo` command writes `X-Orchestra-Session-ID: <session-id>` to `ANTHROPIC_CUSTOM_HEADERS` in `~/.claude/settings.local.json` at session setup, and removes it at cleanup (atomic `tmp + mv -f` to prevent corruption). The header value is the session-dir basename (e.g. `20260507T101953Z-1971495`). For native sessions, `otel-headers-helper.sh` is configured to inject a `native-<UUID>` header, but is not called by CC 2.1.132 — native session cost attribution falls back to T2 (`pricing_yaml`).

At T2 cleanup, `telemetry-summarize.py` queries:

```
GET {ANTHROPIC_BASE_URL}/v1/usage/stats?session_id=<ID>&since=<ISO8601>&until=<ISO8601>
```

with a ±60s buffer around the session time window. If SoHoAI returns a non-zero `totals.cost_usd`, that value is used as the **subagent cost** and `cost_source` is set to `"sohoai_api+t2_parent"`. The parent Brain's cost (not visible to SoHoAI — see below) is computed from the T2 JSONL token counts using `pricing.yaml` and added to the SoHoAI subagent figure. Both components are stored in `telemetry.json` as `subagent_cost_usd` and `parent_cost_usd`; `cost_usd_estimate` is their sum. If pricing.yaml is unavailable the parent component is zero and `cost_source` falls back to `"sohoai_api"`. Otherwise the system falls back to litellm or pricing.yaml (see §Cost-source cascade).

For native sessions, `native-session-finalize.py` performs the same SoHoAI query at finalization time. In practice (CC 2.1.132), SoHoAI returns zero for native sessions (no header injected), so cost attribution falls back to `pricing_yaml`. The result is written to `~/.claude/native-sessions/telemetry.jsonl`.

**Why SoHoAI misses the parent Brain cost.** `ANTHROPIC_CUSTOM_HEADERS` (which carries `X-Orchestra-Session-ID`) is written to `settings.local.json` by the session setup block. The parent Brain process reads settings at startup — before the setup block executes — so the parent's own API calls go to SoHoAI *without* the session header. Subagents are spawned after the header is written and inherit it correctly. The T2 parent cost augmentation (above) compensates for this gap.

#### Inspecting per-session data

```bash
# Check which cost source was used for a specific orchestra session
cat ~/.claude/orchestra/sessions/<session-id>/telemetry.json | jq '{cost_usd_estimate, cost_source}'

# Check cost source across all finalized native sessions
cat ~/.claude/native-sessions/telemetry.jsonl | jq '{session_id, cost_source}'

# Distribution of cost sources across orchestra sessions
grep -o '"cost_source":"[^"]*"' ~/.claude/orchestra/telemetry.jsonl | sort | uniq -c

# Confirm the active-sessions header is set (during an orchestra session)
cat ~/.claude/settings.local.json | jq .env.ANTHROPIC_CUSTOM_HEADERS
```

#### Summary reports

Both the unified and orchestra-specific reports show a `Source` column (`sohoai_api` | `litellm` | `pricing_yaml` | `none`) so you can see which cost path was used at a glance:

```bash
# Unified report with Source column
~/.claude/scripts/session-report.sh --last 10

# Orchestra-only report with Source column
~/.claude/scripts/telemetry-report.sh --last 10

# Filter to native sessions only (finalized via SoHoAI where available)
~/.claude/scripts/session-report.sh --source native --last 10

# Scope to a date range
~/.claude/scripts/session-report.sh --since 2026-05-01
~/.claude/scripts/session-report.sh --month 2026-05
```

---

### Cost-source cascade

T2 applies sources in priority order; first non-zero value wins:

| Priority | Source | `cost_source` value | Condition |
|---|---|---|---|
| 1 | SoHoAI API + T2 parent | `"sohoai_api+t2_parent"` | `ANTHROPIC_BASE_URL` set; SoHoAI returns non-zero; pricing.yaml provides parent rate |
| 1a | SoHoAI API only | `"sohoai_api"` | SoHoAI returns non-zero; pricing.yaml unavailable (parent cost = 0) |
| 2 | litellm | `"litellm"` | litellm installed; `completion_cost()` returns non-zero for session models |
| 3 | pricing.yaml | `"pricing_yaml"` | `config/pricing.yaml` present with model rates |
| — | none (0.0) | `"none"` | All three unavailable or return zero |

`pricing.yaml` carries a `last_updated` field. `telemetry-report.sh` warns if rates are > 90 days stale; bump manually after verifying against https://docs.anthropic.com/en/docs/about-claude/models/all-models.

**Caveats:**
- Per-session `telemetry.json` is the authoritative source (T2). The global `telemetry.jsonl` stores totals only.
- `CLAUDE_SESSION_ID` is not set in subprocess environments (all hook invocations show `session: "unknown"`). `CLAUDE_PROJECT_DIR` is set in hook subprocesses but not in Bash tool call subprocesses. All three places that compute a project path (`orchestra-hook.sh`, `duo.md`, `brain.md`) normalize with `realpath` to resolve symlinks to the physical NFS path.
- T2 transcript discovery uses `.transcript-path` (stored at session-dir creation) as primary, and a global `~/.claude/projects/*/` scan as secondary. No hardcoded path remains.

---

### Per-tier cost interpretation

**Typical tier proportions:**

| Session type | Brain | Planner (Sonnet) | Actor (Haiku) | Reviewer (Sonnet) |
|---|---|---|---|---|
| `/brain` — Sonnet Brain | ~66% | ~13% | ~8% | ~13% |
| `/brain` — Opus Brain | ~95% | ~2% | ~1% | ~2% |
| `/duo` | ~60% | — | ~40% | — |

Brain's tier dominance is what remains **after** prompt caching has already taken ~86% off Brain's bill — the proportions in the table are post-cache. Three multipliers stack to keep Brain on top: **model rate** (Opus cache-read ≈ 15× Haiku cache-read), **context size** (Brain re-sends the whole session every turn; subagents get a fresh, scoped prompt), and **turn count** (Brain runs every user message + every dispatch round-trip; subagents are one-shot). Caching only attacks the first multiplier. To shift the proportions further: trim context (`/compact`, smaller inlined artifacts) or downgrade the Brain model.

The `--tier` flag on `telemetry-report.sh` reads per-session `telemetry.json` files (located via the `session_dir` field in the global log) to produce a per-tier breakdown for each session, then a cumulative totals table across all sessions — the primary tool for answering "which tier is driving my costs overall?".

**Sample `--tier` output:**

```
  2026-04-30  brain   560s  outcome=pass  total=$1.30
    Tier         Model                  Tokens   %tok      Cost   %cost
    ----------------------------------------------------------------
    brain        claude-sonnet-4-6  1,322,163  68.5%  $0.8100   66.3%
    planner      claude-sonnet-4-6     92,598   4.8%  $0.1563   12.8%
    actor        claude-haiku-4-5     425,531  22.0%  $0.1007    8.2%
    reviewer     claude-sonnet-4-6     89,658   4.6%  $0.1549   12.7%
    ----------------------------------------------------------------
    TOTAL                           1,929,950          $1.2219

--- Cumulative totals (3 session(s)) ---
  Tier         Model                  Tokens   %tok       Cost   %cost
  --------------------------------------------------------------------
  brain        claude-sonnet-4-6  2,009,402  69.3%   $1.2079   69.9%
  planner      claude-sonnet-4-6     92,598   3.2%   $0.1563    9.0%
  actor        claude-haiku-4-5     709,827  24.5%   $0.2081   12.0%
  reviewer     claude-sonnet-4-6     89,658   3.1%   $0.1549    9.0%
  --------------------------------------------------------------------
  TOTAL                           2,901,485           $1.7271
```

**Decision gates** (see `TODO.md §0` for thresholds and sample-size requirements):

1. **Researcher agent** — implement only if `Explore` dispatches account for > 15% of session cost.
2. **Planner model** — downgrade to Haiku only if `planner_replans` rate is low and Planner cost fraction is measurable.
3. **1-hour TTL caching** — activate per-tier when TTL-miss rate exceeds 33%.
4. **Reviewer skip** — only if FIX-verdict rate drops below 10% over ≥ 50 sessions (quality risk).
5. **Opus vs Sonnet for Brain** — compare `regret_flag` rate at different model tiers once sufficient data exists.

---

## Multi-model routing (SoHoAI graduated rollout)

### Rationale: from marginal cost to flat-rate pricing

Prior to May 2026, multi-model routing in the orchestra was rejected based on a per-token marginal cost model: switching from Sonnet to a cheaper tier would save money linearly. The analysis assumed all cost differences flowed to the operator. Under that assumption, tiering complexity was not justified.

Ollama Cloud Pro changed the equation: it operates on a **flat-rate subscription model** rather than per-token billing. This means the marginal cost of a Planner replan or an Actor redo is now zero (within the subscription cap), while the **quality risk** of using an untested model remains real. The decision matrix inverted: we now optimize for **quality and capability per subscription dollar**, not token efficiency.

Reference: [Design history & amendments](design-history.md) §Amendment 2026-05-10 — this section documents the decision; see `design-history.md` for the historical context.

### Model assignments and tier annotations

| Role | Model | Trigger |
|---|---|---|
| Planner (normal) | `claude-code-deepseek-v4-pro` | inputs ≤ 30 KB |
| Planner (long-context fallback) | Sonnet 4.6 | inputs > 30 KB; preserves Anthropic cache discount |
| Actor (default) | `claude-code-qwen3-coder-next` | all steps unless marked heavy |
| Actor (heavy) | `claude-code-kimi-k2.6` | `[tier: heavy]` annotation in PLAN.md step |
| Reviewer | Sonnet 4.6 | all reviews (unchanged; calibration priority) |

**Brain** remains Opus 4.7 for `/brain` and Sonnet 4.6 for `/duo` (no change).

### Step-level tier annotations

Plan steps may be tagged with optional `[tier: …]` annotations to override tier defaults:

- `[tier: default]` — use default tier (Qwen3 for Actor, DeepSeek for Planner). Usually omitted.
- `[tier: heavy]` — use heavy tier (Kimi K2.6 for Actor; Sonnet stays for Planner). Used for complex multi-file refactors, architectural changes, or security-sensitive code.

Format: annotation appears on the same line as the step heading (e.g., `### 5. Refactor X [tier: heavy]`). Brain's PLAN parser confirms the annotation exists before dispatching the heavy-tier subagent; if malformed or missing, the step runs at default tier.

### Planner long-context fallback

When RESEARCH + constraints + prior artifacts exceed ~30 KB, Brain runs Sonnet 4.6 via the `planner-long` agent instead of `planner`. This preserves Anthropic's prompt cache discount on large inputs (30× savings on repetitive prefix tokens) while staying in the flat-rate economy via `planner-long` as a documented SoHoAI alias. The 30 KB threshold is approximate; Brain is instructed to `wc -c` the combined input and pick the tier accordingly.

See TODO.md §10e for the deferred automation of this check.

### Alias stability contract

SoHoAI exposes agents as aliases: `claude-code-deepseek-v4-pro`, `claude-code-qwen3-coder-next`, `claude-code-kimi-k2.6`, etc. These are **stable across deployments** within the SoHoAI domain (as of 2026-05-10, per handoff §1). If the alias routing changes (e.g., DeepSeek → Claude 3.7), SoHoAI commits to rotating the alias URL, not swapping backends silently. Updates will be documented in the design-history.md amendment chain.

Without this contract, cost + quality tracking would drift silently between deployments.

### Reviewer remains Sonnet 4.6

Reviewer stays Sonnet 4.6 (no multi-model routing). Rationale:
- Reviewer is a calibration touchstone — if it starts rejecting code that Sonnet previously accepted, review-loop iteration counts will spike, signaling a model regression.
- Reviewer is called ≤ 3 times per step (review loop cap); its cost is < 15% of typical sessions.
- Code review is a high-stakes task where Sonnet's consistency is proven; evaluation of GLM-5.1 as a second-pass cross-check is deferred (see TODO.md §10b).

### Cross-reference

- Agents table (this document, §How the workflow works): file paths and role descriptions.
- design-history.md §Amendment 2026-05-10: historical context, operator caveats, deferred follow-ups.
- TODO.md §10b–10f: deferred items (GLM-5.1 second-pass, 429 fallback, PLAN schema validator, 30 KB threshold automation, max_tokens knob).
- Handoff §1: SoHoAI alias stability contract.
- Handoff §3: max_tokens ≥ 500 requirement for reasoning models.

---

## See also

- [Design history & amendments](design-history.md) — implementation record, experimental detours, v1 validation, historical amendments
- [Resources & references](resources.md) — consulted sources, disregarded third-party claims
- [TODO & deferred items](TODO.md) — v2 stubs, optimization opportunities, open questions
