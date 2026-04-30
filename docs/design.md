---
title: "Claude Orchestra — three-tier Brain/Planner/Actor pattern over Claude Code"
date: 2026-04-24
created_by: Claude Code (Claude Opus 4.7, 1M context)
updated_by: Claude Code (Claude Opus 4.7)
updated_on: 2026-04-30
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

Talk to Brain normally. Brain delegates to Planner/Actor/Reviewer as needed. No forced pipeline. Example: "explain the HomeAI routing architecture" — Brain reads files and answers directly.

### /duo — lightweight (Sonnet plans, Haiku acts)

Start a Sonnet 4.6 session, enter plan mode, chat to refine scope, type `/duo`. Sonnet plans, Haiku executes all steps in one delegation. No Reviewer. Example: "add a docstring to rag_engine/search.py::search_rag" — low risk, no review needed.

Workflow: (1) `claude --model claude-sonnet-4-5`. (2) `Shift+Tab` to enter plan mode. (3) Refine scope interactively. (4) `/duo`. (5) On approval, `Shift+Tab` to bypassPermissions, Actor runs uninterrupted.

### /brain — full pipeline (Opus orchestrates, cap-3 review loop)

Enter plan mode, type `/brain <task>`. Opus runs Phase 0 (RESEARCH, inline — interrogates you), then Phase 1 (PLAN via Planner), Phase 2 (IMPLEMENT via Actor, one step at a time), Phase 3 (REVIEW via Reviewer, loop up to 3 times). Example: "refactor the HomeAI LiteLLM routing to support a new provider" — high-risk, multi-step, needs review loop.

When NOT to use /brain: simple tasks with ≤5 steps, low blast radius. Use /duo instead.

## How the workflow works

### Agents

| Agent | Model | File | Tools | Role |
|---|---|---|---|---|
| **Brain** | Opus 4.7 (or Sonnet for /duo) | — (main session) | all | Orchestrates; calls `ExitPlanMode` at plan approval (G2) |
| **Planner** | Sonnet 4.6 | `~/.claude/agents/planner.md` | Read, Grep, Glob, WebFetch, TodoWrite (read-only) | Decomposes task into numbered plan; Brain persists to PLAN.md |
| **Actor** | Haiku 4.5 | `~/.claude/agents/actor.md` | Read, Edit, Write, Bash, Grep, Glob (+ denies on rm -rf, git push) | Executes one step per invocation; self-persists TASKS.json via atomic-rename |
| **Reviewer** | Sonnet 4.6 | `~/.claude/agents/reviewer.md` | Read, Grep, Glob, TodoWrite (read-only) | Reviews diff against PLAN.md; returns PASS / FIX / BLOCK |

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

### tmux vs VSCode

Hooks are environment-aware:

- **In tmux** (interactive terminal): hook detects `$TMUX`, spawns stage-named window (`plan`, `implement`, `review`, …), tails per-invocation logfile, auto-closes 120 s after completion.
- **In VSCode** (no tmux): hook writes to logfile; user can `tail -f ~/.claude/orchestra/live.log` in VSCode terminal.
- **Disable tmux spawning**: set `CLAUDE_ORCHESTRA_DISABLE_TMUX=1` in shell before launching Claude Code.

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
    logs/
      <stage>-<UTC-ts>-<HOST>-<PID>.log
live.log -> (symlink to last run's log)
state.env (mode badge, append-only)
```

### Cost model

Mixed-tier pricing; orchestration overhead is paid by Brain (Opus is ~7–10× Haiku):

- **Brain** (Opus 4.7): most expensive; receives every subagent's return. Mitigated by prompt caching + `PreCompact` hook saving state.
- **Planner** (Sonnet): called once per plan.
- **Actor** (Haiku): called once per step (cheap).
- **Reviewer** (Sonnet): called once per review (up to 3 per step).

Rule of thumb: use `/brain` for tasks where the review loop actually earns the Brain overhead (architecture, multi-file refactors). Use `/duo` for simple, low-risk tasks.

### Disabling and troubleshooting

**Per-project disable**: set `CLAUDE_ORCHESTRA_DISABLE_TMUX=1` in shell. (No per-project opt-out marker; orchestra is globally on when installed.)

**Global disable**: `mv ~/.claude/scripts/orchestra-hook.sh{,.bak}` (intentionally loud; next `claude` invocation will fail visibly).

**Full uninstall**: `rm -rf ~/.claude/agents/{planner,actor,reviewer}.md ~/.claude/commands/{brain,duo}.md ~/.claude/scripts/orchestra-hook.sh ~/.claude/orchestra/`, then edit `~/.claude/settings.json` to remove hook entries.

Quick-ref troubleshooting:

| Symptom | Likely cause | Check |
|---|---|---|
| No tmux window spawns in tmux | `$TMUX` unset or hook not executable | `echo $TMUX`; `ls -la ~/.claude/scripts/orchestra-hook.sh` |
| `PLAN.md` garbled | Atomic-rename not used — direct write instead | Inspect for `.tmp` sibling; check Planner prompt |
| `/brain` command unrecognised | `~/.claude/commands/brain.md` missing or malformed | `/help` lists commands; inspect file frontmatter |
| Logs growing unbounded | No rotation policy | v1 does not rotate. Manually `rm` or add logrotate. |

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

Every `/brain` and `/duo` run is instrumented post-hoc by `scripts/telemetry-summarize.{sh,py}`, invoked from each command's cleanup block. The parser walks the parent's JSONL for parent tokens, then walks `<parent-uuid>/subagents/agent-*.jsonl` (each subagent's own transcript) attributed via the matching `agent-*.meta.json` sidecar (`{"agentType": "…"}`). It applies USD rates from `config/pricing.yaml` and writes:

- `${SESSION_DIR}/telemetry.json` — rich per-session record (parent + subagents tokens, cost, iterations, blast_radius, outcome).
- `~/.claude/orchestra/telemetry.jsonl` — global append-only trend log (flat summary).
- `${SESSION_DIR}/telemetry-events.jsonl` — live event stream emitted by the T1 hook (`orchestra-hook.sh start|end` modes); used for the status-line `~$X.YZ` running-cost indicator and as a T1↔T2 cross-check.

Pricing maintenance: `pricing.yaml` carries a `last_updated` field. `scripts/telemetry-report.sh` warns if rates are >90 days stale; bump manually after verifying against https://docs.anthropic.com/en/docs/about-claude/models/all-models.

Safety net: the Claude Code `Stop` hook (`orchestra-hook.sh stop`) runs the summariser on any unfinalised session_dirs at session end, covering the case where the operator quits without a clean cleanup.

## See also

- [Design history & amendments](design-history.md) — implementation record, experimental detours, v1 validation, historical amendments
- [Resources & references](resources.md) — consulted sources, disregarded third-party claims
- [TODO & deferred items](TODO.md) — v2 stubs, optimization opportunities, open questions
