---
title: "Claude Orchestra — three-tier Brain/Planner/Actor pattern over Claude Code"
created_at: 20260424-000000
created_by: Claude Code (Claude Opus 4.7, 1M context)
updated_by: Claude Code (Claude Sonnet 4.6)
updated_at: 2026-05-04--21-30
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

### /duo — lightweight (Sonnet plans, Haiku acts)

Start a Sonnet 4.6 session, enter plan mode, chat to refine scope, type `/duo`. Sonnet plans, Haiku executes all steps in one delegation. No Reviewer. Example: "add a docstring to rag_engine/search.py::search_rag" — low risk, no review needed.

Workflow: (1) `claude --model claude-sonnet-4-6`. (2) `Shift+Tab` to enter plan mode. (3) Refine scope interactively. (4) `/duo`. (5) On approval, `Shift+Tab` to bypassPermissions, Actor runs uninterrupted.

### /brain — full pipeline (Opus orchestrates, cap-3 review loop)

Enter plan mode, type `/brain <task>`. Opus runs Phase 0 (RESEARCH, inline — interrogates you), then Phase 1 (PLAN via Planner), Phase 2 (IMPLEMENT via Actor, one step at a time), Phase 3 (REVIEW via Reviewer, loop up to 3 times). Example: "refactor the SoHoAI LiteLLM routing to support a new provider" — high-risk, multi-step, needs review loop.

When NOT to use /brain: simple tasks with ≤5 steps, low blast radius. Use /duo instead.

## How the workflow works

### Agents

| Agent | Model | File | Tools | Role |
|---|---|---|---|---|
| **Brain** | Opus 4.7 (or Sonnet for /duo) | — (main session) | all | Orchestrates; calls `ExitPlanMode` at plan approval (G2) |
| **Planner** | Sonnet 4.6 | `~/.claude/agents/planner.md` | Read, Grep, Glob, WebFetch, TodoWrite (read-only) | Decomposes task into numbered plan; Brain persists to PLAN.md |
| **Actor** | Haiku 4.5 | `~/.claude/agents/actor.md` | Read, Edit, Write, Bash, Grep, Glob (+ denies on rm -rf, git push) | Executes one step per invocation; self-persists TASKS.json via atomic-rename |
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

Four hook types in `~/.claude/settings.json`, dispatching to `~/.claude/scripts/orchestra-hook.sh`:

1. **PreToolUse(Agent)** — `start` mode. Logs subagent invocation to invocations.log.
2. **SubagentStop** — `end` mode. Logs subagent completion.
3. **PreCompact** — `compact` mode. Saves `brain-state.md` (plan/task/decision snapshot for resumption post-`/clear`).
4. (No tool-call hooks; subagent tool dispatch is opaque by design.)

### Status line

The Claude Code status line is extended by `status-line/orchestra-block.sh`, injected into `~/.claude/scripts/status-line.sh` at deploy time via the `# ORCHESTRA_BLOCK_START` / `# ORCHESTRA_BLOCK_END` sentinels.

#### What it displays

The block renders one of the following badge formats, in descending priority:

| Condition | Badge |
|---|---|
| `/duo` session active (one) | `♪ orchestra -> plan <title>  [▶ stage]  [~$X.YZ]` |
| `/duo` sessions active (many) | `♪ orchestra -> plan #N` |
| `/brain` session active | `♪ orchestra -> brain <title>  [▶ stage]  [~$X.YZ]` |
| Subagent running (no /brain or /duo context) | `♪ orchestra  ▶ stage` |
| No orchestra activity | *(nothing — orchestra block is silent)* |

Plus a context-overflow warning appended to any badge: `⚠ >200K` when the parent's `tokens_used` exceeds 180 000 (truncation risk threshold).

`[▶ stage]` shows the current active subagent stage (`plan`, `implement`, `review`, `research`). It appears while the subagent is running and disappears once it completes.

`[~$X.YZ]` is the live running cost from `telemetry-events.jsonl` (T1 approximation; finalised by T2 at session end).

#### When it updates

The status line script is called by Claude Code on each render tick — after every model turn and when tool calls are shown in the UI. **The active-subagent indicator (`▶ stage`) appears in real-time**: the `PreToolUse(Agent)` hook writes the `start` event to `invocations.log` *before* the Task tool executes, so the indicator is already present by the time the subagent begins running.

#### Data sources

| Signal | Source | Written by |
|---|---|---|
| `/duo` title and inflight state | `${SESSION_DIR}/.duo-inflight` | `/duo` command setup |
| `/brain` title and mode | `.claude/orchestra/state.env` (`ORCHESTRA_MODE=brain`, `ORCHESTRA_TITLE=…`) | `/brain` command setup |
| Active subagent stage | `.claude/orchestra/invocations.log` (last `start` event with no matching `end`) | `orchestra-hook.sh start` (PreToolUse) |
| Live cost | `tokens_used` from Claude Code status-line input JSON × $9/M Sonnet blend | Claude Code (always available) |

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
  brain.md, duo.md
scripts/
  orchestra-hook.sh
orchestra/
  config.yaml
  invocations.log (append-only)
```

**Per-project (.claude/orchestra/):**
```
sessions/
  <UTC-ts>-<PID>/
    PLAN.md, TASKS.json, review-comments.md
    .duo-inflight          (present during /duo planning phase only)
    .outcome               (pass | block | partial | abandoned)
    telemetry-events.jsonl (T1 live hook stream)
    telemetry.json         (T2 final record, written at cleanup)
    logs/
      <stage>-<UTC-ts>-<HOST>-<PID>.log
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
| Logs growing unbounded | No rotation policy | v1 does not rotate. Manually `rm` or add logrotate. |
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

### Per-session telemetry

#### Why it exists

Multi-tier orchestration has non-obvious cost structure. Brain (Opus or Sonnet) dominates by token volume — it re-sends its full context every turn (cached after the first hit, but still billed at the cache-read rate of the most expensive model in the system) and receives all subagent returns. Planner and Reviewer (Sonnet) are single-call-per-phase. Actor (Haiku) is cheap per token but may iterate. Without measurement, cost/quality trade-offs (which tier to change? which phase to skip?) are guesses. Telemetry makes them data-driven.

The original motivation was a specific question: does the built-in `Explore` subagent (dispatched during `/duo` Phase 0 and `/brain` Phase 0 research) justify a dedicated cheaper Researcher agent? Telemetry answered it: measure first, then decide. See `TODO.md §0` for the full decision-gate framework.

#### What is collected

Every `/brain` and `/duo` run is instrumented post-hoc by `scripts/telemetry-summarize.{sh,py}`, invoked from each command's cleanup block. The parser walks the parent's JSONL for parent tokens, then walks `<parent-uuid>/subagents/agent-*.jsonl` (each subagent's own transcript) attributed via the matching `agent-*.meta.json` sidecar (`{"agentType": "…"}`). It applies USD rates from `config/pricing.yaml` and writes:

- `${SESSION_DIR}/telemetry.json` — rich per-session record (parent + subagent tokens per tier, USD cost, iteration counts, outcome, blast_radius).
- `~/.claude/orchestra/telemetry.jsonl` — global append-only trend log (flat summary; one line per session).
- `${SESSION_DIR}/telemetry-events.jsonl` — live T1 hook event stream (timing-only; `usage=null` since hook payloads don't expose token counts); drives the real-time `~$X.YZ` status-line indicator.

On-demand report: `~/.claude/scripts/telemetry-report.sh --last N`. Per-session verification: `./scripts/smoke-test.sh`.

#### T1 + T2 hybrid

Two complementary layers:

- **T1 (hook-based, real-time)**: `orchestra-hook.sh start/end` appends one JSON event per subagent dispatch/completion to `telemetry-events.jsonl`. Captures timing and stage identity; `usage` is always `null` (hook payloads don't expose token counts). Drives the live `~$X.YZ` status-line badge via a cached last-known value — the cost persists through subagent execution even though the parent's reported `used_percentage` drops to 0 while a subagent runs.

- **T2 (transcript parsing, authoritative)**: runs once at cleanup. Reads the actual JSONL transcripts for real token counts and model attribution. Normalises versioned model IDs (strips `-YYYYMMDD` suffix for pricing lookup) and skips `<synthetic>` messages (written by `/compact`). T2 supersedes T1 for all cost figures. Transcript discovery priority: (1) `.transcript-path` in the session dir — full JSONL path written at session-dir creation time (setup block) and reinforced by the PreToolUse hook on first subagent dispatch (where `CLAUDE_PROJECT_DIR` is reliably set); (2) global scan of all `~/.claude/projects/*/` subdirectories — exact UUID match when a UUID is known, most-recently-modified JSONL otherwise. This ensures telemetry works correctly when `/duo` or `/brain` is invoked from any project on any machine, regardless of path form (NFS mount path vs local symlink path).

Safety net: the Claude Code `Stop` hook runs the T2 summariser on any unfinalised session dirs at session end.

#### Monitoring costs per tier

Two commands cover all reporting needs:

```bash
# Session totals — quick tabular summary of recent sessions
~/.claude/scripts/telemetry-report.sh --last 10

# Per-tier breakdown + cumulative totals (run from project dir)
~/.claude/scripts/telemetry-report.sh --last 20 --tier
```

**`--tier` rationale:** The global `telemetry.jsonl` stores only session totals — sufficient for trend queries but opaque about *which tier* drove a cost spike. Per-tier attribution lives in the richer per-session `telemetry.json` files under `${PROJECT}/.claude/orchestra/sessions/`. `--tier` bridges the two: it reads the global log to enumerate sessions, looks up each session's per-tier breakdown, prints a per-session table, then appends a **cumulative totals table** across all sessions — the primary tool for answering "which tier is driving my costs overall?"

**`--tier` requirements:** must run from the project directory (or with `CLAUDE_PROJECT_DIR` set). Sessions whose dirs have been cleaned up (30-day retention) appear with log totals only and are excluded from the cumulative.

**Sample `--tier` output:**

```
  2026-04-30  brain   560s  outcome=pass  total=$1.30
    Tier         Model                  Tokens   %tok      Cost   %cost
    brain        claude-sonnet-4-6  1,322,163  68.5%  $0.8100   66.3%
    planner      claude-sonnet-4-6     92,598   4.8%  $0.1563   12.8%
    actor        claude-haiku-4-5     425,531  22.0%  $0.1007    8.2%
    reviewer     claude-sonnet-4-6     89,658   4.6%  $0.1549   12.7%
    TOTAL                           1,929,950          $1.2219

--- Cumulative totals (3 session(s)) ---
  brain        claude-sonnet-4-6  2,009,402  69.3%  $1.2079   69.9%
  planner      claude-sonnet-4-5     92,598   3.2%  $0.1563    9.0%
  actor        claude-haiku-4-5     709,827  24.5%  $0.2081   12.0%
  reviewer     claude-sonnet-4-5     89,658   3.1%  $0.1549    9.0%
  TOTAL                           2,901,485          $1.7271
```

**Typical tier proportions:**

| Session type | Brain | Planner (Sonnet) | Actor (Haiku) | Reviewer (Sonnet) |
|---|---|---|---|---|
| `/brain` — Sonnet Brain | ~66% | ~13% | ~8% | ~13% |
| `/brain` — Opus Brain | ~95% | ~2% | ~1% | ~2% |
| `/duo` | ~60% | — | ~40% | — |

**Key insight:** Brain's tier dominance (95% Opus / 66% Sonnet) is what's left **after** prompt caching has already taken ~86% off Brain's bill — the proportions in the table are post-cache. Without caching, Brain's line would be roughly 10× larger and the session-total ratio more lopsided still. Three multipliers stack to keep Brain on top: **model rate** (Opus cache-read $1.50/MTok ≈ 15× Haiku cache-read $0.10/MTok), **context size** (Brain re-sends the whole session every turn; subagents get a fresh, scoped prompt), and **turn count** (Brain runs every user message + every dispatch round-trip; subagents are one-shot). Caching only attacks the first multiplier — the other two are structural to Brain's role as orchestrator. To shift the proportions further you must trim context (`/compact`, smaller inlined artifacts) or downgrade the Brain model — caching is already doing all it can.

**Caveats:**
- Per-session `telemetry.json` is the authoritative source (T2). The global `telemetry.jsonl` stores totals only. Re-running T2 on sessions completed > ~30 minutes ago produces unreliable results — the time window expands to "now" and captures unrelated transcript activity.
- `CLAUDE_SESSION_ID` is not set by Claude Code in subprocess environments (all hook invocations show `session: "unknown"`). `CLAUDE_PROJECT_DIR` is set in hook subprocesses but **not** in Bash tool call subprocesses. All three places that compute a project path (`orchestra-hook.sh`, `duo.md`, `brain.md`) normalize with `realpath` to resolve symlinks to the physical NFS path before use. T2 transcript discovery uses `.transcript-path` (primary) and a global `~/.claude/projects/*/` scan (secondary); no hardcoded path remains.
- `pricing.yaml` carries a `last_updated` field; `telemetry-report.sh` warns when rates are > 90 days stale.

#### What the data is intended for

The global log drives five decision gates (see `TODO.md §0` for thresholds and sample-size requirements):

1. **Researcher agent** — implement only if `Explore` dispatches are frequent and account for > 15% of session cost. Currently too few sessions to decide.
2. **Planner model** — downgrade to Haiku only if `planner_replans` rate is low and Planner cost fraction is measurable.
3. **1-hour TTL caching** — activate per-tier when TTL-miss rate exceeds 33% (requires measuring inter-call gaps).
4. **Reviewer skip** — only if FIX-verdict rate drops below 10% over ≥ 50 sessions (quality risk).
5. **Opus vs Sonnet for Brain** — compare `regret_flag` rate at different model tiers once sufficient data exists.

Pricing maintenance: `pricing.yaml` carries a `last_updated` field. `telemetry-report.sh` warns if rates are > 90 days stale; bump manually after verifying against https://docs.anthropic.com/en/docs/about-claude/models/all-models.

## See also

- [Design history & amendments](design-history.md) — implementation record, experimental detours, v1 validation, historical amendments
- [Resources & references](resources.md) — consulted sources, disregarded third-party claims
- [TODO & deferred items](TODO.md) — v2 stubs, optimization opportunities, open questions
