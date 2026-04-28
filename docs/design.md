---
title: "Claude Orchestra — three-tier Brain/Planner/Actor pattern over Claude Code"
date: 2026-04-24
created_by: Claude Code (Claude Opus 4.7, 1M context)
updated_by: Claude Code (Claude Opus 4.7, 1M context)
updated_on: 2026-04-26
context: >
  Consolidated reference document for the "Claude Orchestra" design — a
  three-tier orchestration pattern layered on top of Claude Code, inspired by
  Cline VSCode plugin's Plan/Act dual-model workflow and extended to three
  model tiers: Brain (Opus 4.7) / Planner (Sonnet 4.6) / Actor (Haiku 4.5),
  with a Reviewer (Sonnet 4.6) added to support an auto-loop review stage.
  The design was worked out across a single extended conversation on
  2026-04-24, with working notes captured in
  ~/Gin-AI/chats/Claude-code-tmux-pipeline--TODO.md. This document is the
  stable reference; the TODO file remains as the change-log / design-history
  trail. Target environment: Debian Linux machines with a shared NFS mount of
  ~/Gin-AI/ providing a common ~/.claude/ directory across hosts. Intended
  to work interchangeably between terminal-hosted Claude Code (inside tmux)
  and the VSCode Claude Code extension.
---

# Claude Orchestra

A three-tier orchestration layer over Claude Code: **Brain (Opus 4.7 / Sonnet 4.6)** / **Planner (Sonnet 4.6)** / **Actor (Haiku 4.5)** / **Reviewer (Sonnet 4.6)**, using Claude Code's native subagent primitive (`Task` tool). Designed to be installed once at `~/.claude/` and usable from any project on any machine that mounts the NFS home.

> ## ⚠ Status banner (2026-04-28)
>
> Between 2026-04-26 and 2026-04-28 the orchestra ran on a **headless `claude -p` execution model** (Option A, per-tier subprocesses, multi-run registry, separate Phase 0 dialogue session). That detour has been **reverted on the `subagents` branch**. The current architecture is again the **canonical Claude Code subagent model** described in §§1–13 below.
>
> If you are reading the lower amendment sections dated 2026-04-26 (lines ~899–1334), treat those as **historical record** of an experiment, not active design. The authoritative explanation of the revert is in:
>
> - The closing **Amendment — 2026-04-28** of this document (search "Amendment — 2026-04-28").
> - The standalone **`docs/architecture/2026-04-28-headless-revert.md`** that captures the research note from run `subagents-vs-headless-revisited-20260428`.
>
> Top-line summary of what changed back:
>
> - Single Claude Code session orchestrates everything inline (Brain). No `claude -p` subprocesses. No tmux windows for stages. No multi-run registry.
> - Phase 0 RESEARCH happens inside Brain (it interrogates the operator directly), not in a separate Opus session. The `agents/researcher.md` file is deleted.
> - Subagents are dispatched via the canonical `Task` tool with `subagent_type: planner | actor | reviewer`.
> - Per-invocation artifact subdirectories (`.claude/orchestra/sessions/<UTC-timestamp>-<PID>/`) replace the flat `.claude/orchestra/PLAN.md` etc.
> - Lazy 30-day cleanup of session subdirs at every `/brain` and `/duo` start.
> - Permission flow: parent in plan mode → `ExitPlanMode` after plan approval → standard Claude Code "auto-edit / manually approve / cancel" UX.
> - Deleted: `commands/{brain-resume,brain-abandon,brain-status,orchestra-mode}.md`, `agents/researcher.md`, `scripts/{start-research,runs-registry,run-tier,format-stream}.sh`, `.vscode/tasks.json`. ~890 lines of headless plumbing gone.

## 1. Premise

The goal: a Cline-style Plan/Act workflow that goes one step further by routing reasoning, implementation, and review across three Claude model tiers, with enough structure to support fully autonomous loops later, and enough visibility to watch each tier work when desired.

Stated constraints:

- **Option B** (native sub-agents via Claude Code's Agent tool) rather than Option A (separate `claude --model …` processes) or Option C (tmux + Agent SDK). Picked for simplicity, cost, and canonical alignment.
- Visibility via **tmux windows** that spawn and auto-close automatically.
- Must work **interchangeably between tmux terminal and the VSCode Claude Code extension** on the same machine.
- **Global install** at `~/.claude/` so the orchestra is available from any project.
- Shared across Debian hosts via an **NFS-mounted** home directory (`~/.claude → ~/Gin-AI/.claude`).

## 2. Resources consulted

| Source | Location | Role in the design |
|---|---|---|
| Longform Guide — *"Everything Claude Code"* by affaan-m | `https://github.com/affaan-m/everything-claude-code/blob/main/the-longform-guide.md` | Source of the Sequential Phase Architecture (RESEARCH → PLAN → IMPLEMENT → REVIEW → VERIFY), model-tier assignments (Opus/Sonnet/Haiku), single-input/output-per-agent discipline, and "minimum viable parallelization" guidance. Community resource — not Anthropic canon. |
| Gemini discussion | `/var/tmp/gemini-chat.md` (local copy — original share URL blocked by consent redirect) | Confirmed that `.claude/agents/*.md` with `model:` frontmatter is the real primitive; validated cascade method (multiple `claude --model …` processes); validated handover-via-file pattern. Parts claiming "Agent Teams" / `teammateMode` / auto-spawning panes are explicitly disregarded (not real Claude Code features). |
| Claude Code usage report | `/mnt/nfs/Florian/Gin-AI/.claude/usage-data/report.html` (680 messages, 72 sessions, 2026-03-25 → 2026-04-24) | Provided usage context; specifically recommended trying "parallel multi-agent benchmark sweeps with a coordinator aggregating a decision matrix" — direct motivation for this work. |
| HomeAI project instructions | `/mnt/nfs/Florian/Gin-AI/projects/HomeAI/CLAUDE.md` | NFS-safety conventions (passive files OK on NFS, RocksDB/SQLite NOT OK), Python venv location, documentation metadata convention. |
| Global Claude Code rules | `~/.claude/CLAUDE.md` | "Never commit unless asked" — bounded the autonomy design. |
| Claude Code native primitives (documented) | — | Subagents (`.claude/agents/*.md`), hooks (`PreToolUse`, `SubagentStop`, `PreCompact`), permission modes (`default` / `acceptEdits` / `plan` / `bypassPermissions`), slash commands, `ExitPlanMode` tool. |

## 3. The design in one breath

Single main Claude Code session on **Opus 4.7** is the Brain. When Brain needs a plan, it invokes `planner` (Sonnet 4.6, read-only) via the Agent tool. When it needs code changes, `actor` (Haiku 4.5, write+exec). When it needs a review, `reviewer` (Sonnet 4.6, read-only + analysis). Agents are defined once at `~/.claude/agents/*.md`, shared across all machines via NFS. Per-project state (`PLAN.md`, `TASKS.json`, logs) lives at `${CLAUDE_PROJECT_DIR}/.claude/orchestra/`. A single hook script branches on `$TMUX` — tmux windows if present, logfile only otherwise. Approval gates use canonical Claude Code primitives: `ExitPlanMode` for plan approval (Brain-only, NOT Planner), permission modes for tool approvals.

## 4. Architecture

### 4.1 Agents

| Agent | Model | File | Tools | Role |
|---|---|---|---|---|
| **Brain** | Opus 4.7 (`claude-opus-4-7`) | — (this is the main Claude Code session, not a subagent) | all | Orchestrates; delegates to subagents; calls `ExitPlanMode`; runs CROSS-CHECK in v2 |
| **Planner** | Sonnet 4.6 (`claude-sonnet-4-5`) | `~/.claude/agents/planner.md` | `Read`, `Grep`, `Glob`, `WebFetch`, `TodoWrite` — read-only, **excludes** `ExitPlanMode` | Decomposes Brain's intent into a numbered plan; writes `PLAN.md` via atomic-rename; returns plan text to Brain |
| **Actor** | Haiku 4.5 (`claude-haiku-4-5-20251001`) | `~/.claude/agents/actor.md` | `Read`, `Edit`, `Write`, `Bash`, `Grep`, `Glob` — with denies on `Bash(rm -rf …)`, `Bash(git push …)`, writes outside `${CLAUDE_PROJECT_DIR}` | Executes one scoped step from the plan; updates `TASKS.json` via atomic-rename |
| **Reviewer** | Sonnet 4.6 (`claude-sonnet-4-5`) | `~/.claude/agents/reviewer.md` | `Read`, `Grep`, `Glob`, `TodoWrite` — read-only | Reviews Actor's output; writes `review-comments.md` via atomic-rename |

Model identifiers are **pinned to snapshots** (not short aliases like `sonnet` / `haiku`) for reproducibility; they won't silently upgrade.

### 4.2 Sequential Phase Architecture and gates

The Longform Guide's pipeline, with gate policy:

| Gate | Between | v1 policy | Mechanism |
|---|---|---|---|
| G1 | RESEARCH → PLAN | skip (default); configurable to `notify` | — |
| **G2** | **PLAN → IMPLEMENT** | **approve** (required) | **`ExitPlanMode` called by Brain** — NOT by Planner |
| G3 | IMPLEMENT internal | follow Claude Code permission mode | `settings.json` `permissions.{allow,deny,ask}` |
| G4 | IMPLEMENT → REVIEW | skip (auto-dispatch Reviewer) | — |
| **G5** | **REVIEW → VERIFY/LOOP** | **auto-loop, cap 3 iterations** | Brain counts; surfaces after cap or structural issue |
| G6 | VERIFY → DONE | notify (Brain prints summary) | — |
| G7 | DONE → COMMIT/PR | **explicit user request only** | Respects global "never commit unless asked" rule |

RESEARCH stage is served by Brain itself or by the built-in `Explore` subagent — no dedicated Researcher agent file in v1.

### 4.3 Two autonomy axes and three presets

Autonomy lives on two independent axes:

| Axis | Controls | Primitive |
|---|---|---|
| **X — Tool-level prompts** | Does Claude Code prompt on each Edit/Write/Bash? | Claude Code permission modes: `default` / `acceptEdits` / `plan` / `bypassPermissions` |
| **Y — Stage-level gates** | Does the orchestra pause between PLAN/IMPLEMENT/REVIEW/VERIFY/COMMIT? | Orchestra `gates.*` + `commit.policy` in config.yaml |

Combined presets use canonical Claude Code permission-mode names:

| Preset | Axis X | G2 plan | G5 review loop | G7 commit | Status |
|---|---|---|---|---|---|
| `default` | `default` (ask on every tool) | approve via `ExitPlanMode` | auto_loop cap 3 | explicit | **v1 default** |
| `acceptEdits` | `acceptEdits` (edits auto, Bash asks) | approve via `ExitPlanMode` | auto_loop cap 3 | explicit | **v1** |
| `auto` | `bypassPermissions` (nothing asks) | notify only (no gate) | auto_loop cap 5 + CROSS-CHECK loop | auto-commit on isolated branch | **v2 — stubbed in v1** |

Switching presets:

- **Axis X**: `Shift+Tab` cycle, `/permissions` slash command, or `--permission-mode X` at launch. Claude Code canon; portable across tmux and VSCode.
- **Axis Y**: `/orchestra-mode <preset>` slash command (see §10 for v1 stub behaviour).

### 4.4 Extended pipeline under `auto` (v2 only)

```
  ┌────────┐   ┌─────────┐   ┌────────┐   ┌──────────────────────┐   ┌──────────┐
  │  PLAN  │→──│IMPLEMENT│→──│ REVIEW │→──│ CROSS-CHECK vs PLAN  │→──│ FINALIZE │
  └────────┘   └─────────┘   └────────┘   │ (Brain: PLAN.md vs   │   │  commit  │
      ▲           ▲              │        │  TASKS.json vs       │   │  + docs  │
      │           │              │        │  actual repo state + │   └──────────┘
      │           │              │        │  test-gate result)   │
      │           │              ▼        └──────────────────────┘
      │           │        issues found         │
      │           │              │              ▼
      │           │              │         incomplete
      │           └──────────────┴──────────────┤
      │                  bounded iterations     │
      └─────────────── replan if needed ────────┘
```

REVIEW asks "is the code good" (Reviewer). CROSS-CHECK asks "does the code fulfil PLAN.md" (Brain, read-only audit). Both must pass for FINALIZE.

### 4.5 Hooks

| Event | Hook type | Action |
|---|---|---|
| Subagent about to start | `PreToolUse` (matcher: `Agent`) | Spawn tmux window (if `$TMUX`); write `live-stage.env` + update `live.log` symlink; append to `invocations.log` |
| Edit/Write/Bash inside any session | `PreToolUse` (matchers: `Edit`, `Write`, `Bash`) | If `live-stage.env` exists: append `[HH:MM:SS] TOOL param` line to active logfile; else no-op |
| Subagent ended | **`SubagentStop`** | Mark window `✓`; schedule 120 s `kill-window`; delete `live-stage.env`; append to `invocations.log` |
| Before context compaction | `PreCompact` | Save Brain state to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/brain-state.md` |

`SubagentStop` is deliberately used instead of `PostToolUse(Agent)` — it's Claude Code's purpose-built hook for the subagent-ended event and is more future-proof.

The `Edit/Write/Bash` hook fires globally for all Claude Code sessions on this user. The `live-stage.env` gate makes it a no-op outside orchestra subagent runs — cost: one file-existence check per Edit/Write/Bash call.

### 4.6 Invocation

- **Regular conversation**: talk to Brain normally. Brain auto-delegates to Planner/Actor/Reviewer (or built-in `Explore`/`Plan`) via the Agent tool as needed. No forced pipeline. This is the canonical Claude Code pattern.
- **`/brain` slash command**: heavyweight opt-in for tasks that benefit from the full pipeline. Enters plan mode, delegates to Planner → Brain calls `ExitPlanMode` → on approve dispatches Actor → Reviewer → loops up to cap 3 → halts with summary.
- **No `/plan`, `/act`, `/review` stage commands** in v1. They would duplicate Brain's natural delegation responsibility and bias toward a rigid pipeline; deliberately omitted.

## 5. Interchangeability: tmux terminal ↔ VSCode Claude Code extension

The agent mechanics are **identical** in both environments. Only the visibility skin differs.

### 5.1 What's identical

- `~/.claude/agents/*.md` subagent definitions
- `~/.claude/settings.json` hook entries
- `~/.claude/scripts/orchestra-hook.sh` script (the hook itself runs in both)
- `~/.claude/commands/brain.md`, `orchestra-mode.md` slash commands
- `~/.claude/orchestra/config.yaml` global config
- Per-project state at `${CLAUDE_PROJECT_DIR}/.claude/orchestra/`: `PLAN.md`, `TASKS.json`, `review-comments.md`, `invocations.log`, per-invocation stage logs
- G2 approval via `ExitPlanMode` (surfaced in Claude Code UI, not tmux)
- G3 tool-level approvals (governed by Claude Code permission mode)
- Axis X switching via `Shift+Tab` / `/permissions` / `--permission-mode`

### 5.2 What differs

The hook script detects `$TMUX` and branches:

| Environment | `$TMUX` set | Behaviour on subagent spawn | Behaviour on subagent end |
|---|---|---|---|
| Plain terminal inside tmux session | ✅ | Spawn window running `tail -f <logfile>`; write `live-stage.env`; update `live.log` symlink | Mark window `✓`, schedule 120 s `kill-window`, delete `live-stage.env`, append to logs |
| VSCode Claude Code extension panel | ❌ | No window spawned; write `live-stage.env`; update `live.log` symlink | Delete `live-stage.env`; append to logs |
| VSCode integrated terminal (no inner tmux) | ❌ | Same as VSCode extension panel | Same |
| Plain terminal without tmux | ❌ | Same as VSCode extension panel | Same |

In all environments, `Edit/Write/Bash` PreToolUse hooks append live tool-call lines to the active logfile while a subagent runs. In tmux these appear in the auto-spawned window; in VSCode the user tails `live.log` manually.

### 5.3 Gaps and workarounds

**Gap 1 — No live per-stage window in VSCode.** *(partially resolved 2026-04-25)*
In tmux you see a dedicated window per active subagent with live tool-call lines. In VSCode no window spawns, but the logfile still receives live lines — open one terminal split and keep it:

```bash
tail -f ${CLAUDE_PROJECT_DIR}/.claude/orchestra/live.log
```

`live.log` is a symlink updated on each subagent dispatch; it follows the entire pipeline across stages without needing to be restarted. This replaces the earlier workaround of tailing `invocations.log | jq .` (which only showed start/end events, not per-tool-call lines).

**Gap 2 — Per-stage logs are separate files.** *(resolved 2026-04-25)*
`live.log` symlink always points at the most-recently-started stage log. Single `tail -f live.log` in VSCode covers all stages sequentially.

**Gap 3 — Nested subagent tool calls invisible.** *(resolved 2026-04-25)*
`PreToolUse` hooks for `Edit`, `Write`, `Bash` now fire and append `[HH:MM:SS] TOOL param` lines to the active logfile in real time. In tmux these appear in the auto-spawned stage window; in VSCode they appear in a `tail -f live.log` split. The `live-stage.env` file gates the hook to no-op outside orchestra subagent runs.

*Verification caveat:* whether `PreToolUse` fires for tool calls made *inside* a subagent (vs. only in the parent session) is confirmed by smoke test for the parent-session path, but not yet verified in a live subagent run. If hooks don't fire inside subagents, Tier 2 fallback applies: instruct agents to self-report via `Bash` after each step. See Amendment 2026-04-25.

**Gap 4 — `ExitPlanMode` UI is Claude-Code-native in both environments; nothing to do.**
The plan approval prompt surfaces in the Claude Code UI (tmux panel or VSCode panel). No environment-specific handling needed.

**Gap 5 — Switching between tmux and VSCode mid-task.**
Start a `/brain` invocation in tmux, `/clear`, resume in VSCode: the per-project state files (`PLAN.md`, `TASKS.json`, logs) are all on NFS and visible to both. However Brain's in-memory conversation context is per-session. The PreCompact hook saving `brain-state.md` (v1) plus a future `/brain-resume` (v2) is what makes a clean cross-environment resume possible; without `/brain-resume`, resuming across a `/clear` requires a manual "read `PLAN.md` and continue" prompt to Brain.

## 6. NFS / cross-machine concurrency

`~/Gin-AI/` (and therefore `~/.claude/`) is NFS-mounted and shared across Debian machines. This collapses most of the cross-machine deployment problem — install once at `~/.claude/`, visible on every host.

### 6.1 What is shared via NFS

- Global orchestra infrastructure: `~/.claude/agents/*.md`, `~/.claude/scripts/*`, `~/.claude/commands/*`, `~/.claude/settings.json`, `~/.claude/orchestra/config.yaml`
- Per-project state (since projects like HomeAI also live on NFS): `${CLAUDE_PROJECT_DIR}/.claude/orchestra/PLAN.md`, `TASKS.json`, `review-comments.md`, `invocations.log`, per-invocation stage logs, `brain-state.md`
- ~~`.enabled` opt-in marker~~ — removed 2026-04-25; orchestra is globally on

### 6.2 Race conditions if `claude` runs simultaneously on two hosts in the same project

The operational assumption is **one machine per project at a time**. Given that, the realistic race profile:

| Shared resource | If concurrent | Severity |
|---|---|---|
| `invocations.log` (NFS append) | Both hooks append; lines may interleave but do not corrupt for line-sized writes. Each line carries `${HOSTNAME}:${PID}:${CLAUDE_SESSION_ID}:${TIMESTAMP}` and can be demuxed post-hoc. | **Low** |
| Per-invocation stage logs (`plan-<ts>-<HOST>-<PID>.log`) | Unique filenames by construction. No collision. | **None** |
| `PLAN.md`, `TASKS.json`, `review-comments.md` | Atomic-rename pattern prevents partial writes, but two concurrent Planners/Reviewers finishing near-simultaneously will last-writer-win. Silent loss. | **Medium** |
| Project source files being edited by two Actors | NFS working tree, no git coordination between hosts. Overlapping edits will corrupt each other; the git index will show garbage; potentially lost work. | **High — the real hazard** |
| Tmux windows | Per-machine; no cross-host conflict. Window names are clean (no hostname) — if both hosts show an `implement` window, that's fine; they are in different tmux sessions. | **None** |
| `ExitPlanMode` UI | Per-session; each host approves its own plan independently. | **None** |

### 6.3 Mitigations applied

- **Hostname + PID + session + timestamp stamping** on every log line and on per-invocation stage logfile names. Gives a full forensic trail after the fact.
- **Atomic-rename pattern** (`write .tmp → fsync → rename`) for `PLAN.md`, `TASKS.json`, `review-comments.md`, and `brain-state.md`. `rename` is atomic on POSIX + NFS. Encoded in Planner/Actor/Reviewer system prompts.
- **Crash safety by construction** — because we use stamping rather than a lock sentinel, a hook crash leaves only orphaned (uniquely-named) logfiles; there is no zombie lock to clean up. Stamping is crash-safe; a lock sentinel would only be crash-safe via TTL.
- **No push, no PR** in any v1 mode. Destructive git actions remain explicit user actions.

### 6.4 Mitigations deferred

- **Lock sentinel** (`.orchestra.lock` in the project state dir). Would prevent the Medium-severity silent state clobber on `PLAN.md` / `TASKS.json` if two sessions run concurrently in the same project. Deferred because the user confirmed simultaneous-multi-host-per-project use is rare, and the stamping approach is simpler + crash-safe. The lock sentinel can be added additively later — no rework of v1 — if concurrent clobbers ever appear in practice.

## 7. Tmux window naming

Windows (not panes). Names match the Sequential Phase Architecture stage the subagent serves, not the agent's own name.

| Subagent | Window base name | Stage |
|---|---|---|
| Planner | `plan` | PLAN |
| Actor | `implement` | IMPLEMENT |
| Reviewer | `review` | REVIEW |
| built-in `Explore` (if used for G1) | `research` | RESEARCH |
| (v2) Brain CROSS-CHECK | `cross-check` | CROSS-CHECK |
| (v2) Brain FINALIZE | `finalize` | FINALIZE |

Rules:

- First instance: bare base name (`implement`).
- Subsequent / concurrent: underscore-counter suffix (`implement_1`, `implement_2`, …).
- Multi-word stages use dashes in the base name (`cross-check`); only the suffix uses underscores (`cross-check_1`).
- Brain itself has no window; it runs in the tmux session's invoking window.
- Window title flips to `<name> ✓` on `SubagentStop`, then `tmux kill-window` is scheduled 120 s later.
- Hostname is NOT in window names; tmux sessions are per-machine anyway, and cross-host disambiguation lives in log filenames and log-line stamps.

## 8. File inventory after install

### Global (on NFS, shared across all Debian hosts via ~/Gin-AI/.claude)

```
~/.claude/
├── agents/
│   ├── planner.md
│   ├── actor.md
│   └── reviewer.md
├── commands/
│   ├── brain.md
│   ├── duo.md
│   └── orchestra-mode.md
├── scripts/
│   └── orchestra-hook.sh
├── orchestra/
│   └── config.yaml
├── settings.json       # hook entries appended; existing contents preserved
└── CLAUDE.md           # unchanged
```

### Per-project (created on first Agent invocation by the hook)

```
${CLAUDE_PROJECT_DIR}/
└── .claude/
    └── orchestra/
        ├── state.env                             # runtime state (mode, counters)
        ├── PLAN.md                               # atomic-rename
        ├── TASKS.json                            # atomic-rename
        ├── review-comments.md                    # atomic-rename
        ├── brain-state.md                        # written by PreCompact hook
        ├── invocations.log                       # append-only, stamped
        ├── live-stage.env                        # overwrite; present only while a subagent runs
        ├── live.log -> logs/<stage>-…            # symlink; updated on each subagent start
        └── logs/
            └── <stage>-<UTC-ts>-<HOST>-<PID>.log # per-invocation stage logs (with live tool lines)
```

`.claude/orchestra/` is globally gitignored via `~/.gitignore_global` (configured
2026-04-25) — no per-project `.gitignore` entry needed.

## 9. Locked decisions

All v1 decisions as of 2026-04-24:

| # | Item | Decision |
|---|---|---|
| Architecture | Option A/B/C | ~~Option B (native sub-agents)~~ → **Option A** — per-tier `claude -p` subprocess in dedicated tmux windows. Migrated 2026-04-26. See Amendment. |
| Scope | Global vs project-scoped | **Global** at `~/.claude/` |
| Visibility | Tmux vs logfile only | **Conditional** — `$TMUX`-detecting hook script |
| Window vs pane | — | **Window**, not pane |
| Window naming | — | **Stage names** (`plan`, `implement`, `review`, …); underscore counter suffix (`_1`, `_2`, …); dashes for multi-word stages (`cross-check`) |
| Window termination | — | **Auto-close 120 s** after `SubagentStop` |
| Granularity | — | ~~Bracketed~~ → ~~Live (PreToolUse hooks)~~ → **Full live feed** (thinking, prose, tool calls with args, tool results — via `claude -p --output-format stream-json` per tier). Amended 2026-04-26. |
| G2 mechanism | — | **`ExitPlanMode` called by Brain** (not Planner); sentinel-file fallback for headless |
| G5 mechanism | — | **auto-loop, cap 3 iterations** |
| End-of-subagent hook | — | **`SubagentStop`** (canonical, not `PostToolUse(Agent)`) |
| Planner `tools:` | — | `Read, Grep, Glob, WebFetch, TodoWrite` — **excludes `ExitPlanMode`** |
| Actor `tools:` | — | `Read, Edit, Write, Bash, Grep, Glob` + denies on `Bash(rm -rf …)`, `Bash(git push …)`, writes outside project |
| Reviewer `tools:` | — | `Read, Grep, Glob, TodoWrite` — read-only |
| Handover channel | — | **Both** — in-message return AND atomic-rename state file |
| Invocation style | — | **`/brain`** slash command only, as a heavyweight opt-in; natural conversation delegation otherwise |
| Model pinning | — | **Pinned snapshots** — `claude-sonnet-4-5`, `claude-haiku-4-5-20251001` |
| Brain cost posture | — | **Opus 4.7 + prompt caching + `PreCompact` hook** → `brain-state.md` |
| `.enabled` opt-in marker | — | ~~**Yes** — hook no-ops in projects without it.~~ **Removed 2026-04-25** — orchestra is globally on; no per-project marker needed. See Amendment section. |
| State directory name | — | Keep `.claude/orchestra/` (co-located with Claude Code config) |
| Config file location | — | Keep `~/.claude/orchestra/config.yaml` with optional per-project override |
| NFS concurrency | — | **Hostname + PID + session + timestamp stamping**; atomic-rename for state files; **no lock sentinel** in v1 |
| v1 autonomy presets | — | `default`, `acceptEdits` — fully wired |
| v2 autonomy preset | — | `auto` — **stub only in v1** |

## 10. Deferred to v2 — stubs and future intent

### 10.1 `/orchestra-mode` — v1 stub

`~/.claude/commands/orchestra-mode.md` in v1:

- Accepts arg `default` | `acceptEdits` | `auto`.
- For `default` and `acceptEdits`: writes the preset name to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env` (simple `key=value` file) and echoes a confirmation. Does **not** change Claude Code's permission mode in v1 — that remains user-driven via `Shift+Tab` / `/permissions`. Keeps the stub harmless.
- For `auto`: prints "not yet implemented in v1 — see §10.2 for v2 intent" and exits without changing any state.

### 10.2 `/orchestra-mode auto` — v2 intent

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

### 10.3 Other deferred items

- **Option A showcase** (separate `claude --model …` processes per tier in dedicated tmux windows) — build only if v1's in-process subagent pattern proves insufficient for some specific task.
- **Dedicated Researcher subagent** (`~/.claude/agents/researcher.md`) — only if Brain + built-in `Explore` prove inadequate for the G1 RESEARCH stage.
- **Lock sentinel** for cross-machine concurrent project sessions — only if real clobbers appear in practice. Additive; no v1 rework needed.
- **Non-NFS machine deployment helper** (`make install-orchestra` or similar to `rsync ~/.claude/` to a non-NFS host) — only when a Debian box outside the NFS mount shows up.
- **Review-loop escalation verbs** after cap-3 surface (`/fix`, `/accept-with-comments`, `/reject`) — v1 just lets Brain surface a text summary and the user decides in natural conversation.
- **`PreCompact` payload schema refinement** — v1 writes Brain's current `PLAN.md` reference, open `TASKS.json` items, last-N decisions, and active gate state to `brain-state.md`. Format evolves during v1 use.

## 11. Deviations from canonical / community best practices

### 11.1 Aligned with canonical Claude Code

| Aspect | Canonical primitive used |
|---|---|
| Subagent definitions | `.claude/agents/*.md` with `name`, `description`, `model`, `tools` frontmatter |
| Model overrides | `model:` in agent frontmatter (no reliance on the unverified `CLAUDE_CODE_SUBAGENT_MODEL` env var Gemini mentioned) |
| Hooks | `PreToolUse`, `SubagentStop`, `PreCompact` — all documented hook types |
| End-of-subagent trigger | `SubagentStop` (the purpose-built hook) rather than `PostToolUse(Agent)` |
| Plan approval | `ExitPlanMode`, called by Brain (mirrors the built-in `Plan` subagent which also excludes `ExitPlanMode` from its tool set) |
| Permission modes | `default` / `acceptEdits` / `plan` / `bypassPermissions` unchanged |
| Slash commands | `.claude/commands/*.md` |
| Tool deny rules | `permissions.deny` patterns in `settings.json` |
| Preset naming | `default` / `acceptEdits` / `auto` — matches Claude Code permission mode names wherever possible |
| Natural delegation | Brain delegates via Agent tool in conversation without a forced pipeline — the canonical behaviour |

### 11.2 Deliberate deviations — rationale

| Deviation | Rationale |
|---|---|
| **Custom state dir `.claude/orchestra/`** | Claude Code has no documented convention for runtime state. Co-locating with other Claude Code config under `.claude/` is pragmatic. The canonical-stricter alternative (sibling `.orchestra/`) offers no real benefit. |
| **Custom `~/.claude/orchestra/config.yaml`** | Enables per-project override of gate policy and mode presets. The stricter alternative (extending `~/.claude/settings.json` with an `orchestra:` key) would be more idiomatic but less flexible for per-project overrides. |
| **`.enabled` opt-in marker** | ~~Was bespoke per-project gate; removed 2026-04-25.~~ Orchestra is now globally on everywhere the config is installed (`~/.claude/orchestra/config.yaml` present). Status-line uses the config-file as the global enable signal. The `.claude/orchestra/` state dir is auto-created on first Agent invocation in any project; globally gitignored via `~/.gitignore_global`. |
| **Sequential Phase Architecture as a formal pipeline** | The 5-stage pipeline (RESEARCH → PLAN → IMPLEMENT → REVIEW → VERIFY) is from the Longform Guide — a **community resource, not Anthropic documentation**. Mitigation: the pipeline is **opt-in via `/brain` only**. Default Brain behaviour remains canonical (auto-delegate as needed, no forced pipeline). So the community pattern is a named option, not the default. |
| **Tmux window spawning from hooks** | Unconventional shell usage; Claude Code's documented hook examples focus on Bash/Edit/Write tools rather than display-side effects. Not forbidden; it simply hasn't been a common pattern in the community. Acceptable given `$TMUX` detection keeps it env-conditional. |
| **Atomic-rename pattern in subagent system prompts** | POSIX standard, not Claude-specific. Documented in prompt text rather than enforced at a tool level. A canonical-stricter alternative would be a `PreToolUse` guard on `Write` that rejects direct writes to state files when a sibling `.tmp` exists; explicitly **not** done — trusting the prompt instruction keeps the hook simple. |
| **`/orchestra-mode` slash command** | Custom command for a custom concept (orchestra-level autonomy presets). There is no canonical primitive for this. |
| **`auto` preset includes auto-commit on a branch** | A deliberate, bounded relaxation of the global "never commit unless asked" rule — scoped to an isolated branch, never pushes, never opens a PR, and explicitly opt-in via `/orchestra-mode auto`. Intended to make overnight / unattended runs useful while preserving user control over anything externally visible. |

### 11.3 Gemini-sourced material explicitly disregarded

These were claimed as Claude Code features but are not real; the design does **not** depend on them:

- "Agent Teams" feature.
- `teammateMode` setting or `CLAUDE_CODE_TEAMMATE_MODE` env var.
- Automatic tmux pane spawning per spawned teammate.
- `SessionStart` hook that moves a subagent pane to a new window.
- "PrimeLine tools" / a bundled `spawn-worker.sh` ecosystem script.
- `CLAUDE_CODE_SUBAGENT_MODEL` env var as a global default for subagent models.

## 12. Other items of importance

### 12.1 Cost model

Mixed-tier pricing. Rough per-operation cost shape (order-of-magnitude, not invoice-accurate):

- **Brain (Opus 4.7)** — most expensive per token. Receives every subagent's return value, so long-running pipelines inflate Brain's context. Mitigations: prompt caching, `PreCompact` hook saving state to `brain-state.md` so compaction + `/clear` is safe.
- **Planner (Sonnet 4.6)** — mid-tier. Called once per plan cycle.
- **Reviewer (Sonnet 4.6)** — mid-tier. Called once per review (up to cap 3 per task).
- **Actor (Haiku 4.5)** — cheapest. Called once per implementation step (up to cap 3 per task in v1 review loop; more in v2 under `auto` with CROSS-CHECK).

Rule of thumb: aggressive use of `/brain` on small tasks is not cost-effective because the Brain-side orchestration tokens dominate. Use `/brain` for tasks where the pipeline's structure actually earns the overhead (architecture work, multi-file refactors, anything with G2 approval value).

### 12.2 Interaction with `/clear` and `/compact`

- `/clear` — wipes Brain's in-memory conversation. State files on disk (`PLAN.md`, `TASKS.json`, `review-comments.md`, `brain-state.md`, logs) **survive**. In v1, picking up after `/clear` requires a manual re-read instruction to Brain ("read `.claude/orchestra/PLAN.md` and continue"). In v2, `/brain-resume` automates this.
- `/compact` — triggers `PreCompact` hook, which saves `brain-state.md`. Brain's in-memory context is compacted; state files remain intact. Resumption is smoother than `/clear` because some conversation context is preserved.

### 12.3 How to temporarily disable the orchestra

- **Per-project**: ~~delete `.enabled` marker~~ — **gate removed 2026-04-25** (orchestra is globally on). To suppress tmux windows for a session, set `CLAUDE_ORCHESTRA_DISABLE_TMUX=1`. A per-project opt-out marker is not currently implemented.
- **Per-session**: unset the hook in the running session (edit `~/.claude/settings.json` to comment out the `PreToolUse`/`SubagentStop`/`PreCompact` entries, restart `claude`). Heavyweight; use only when debugging.
- **Globally**: rename `~/.claude/scripts/orchestra-hook.sh` to `.bak`. Next `claude` invocation's hook will fail loudly (intentional — visible disable rather than silent) until you rename it back.

### 12.4 Troubleshooting quick reference

| Symptom | Likely cause | Check |
|---|---|---|
| No tmux window spawns in tmux session | `$TMUX` unset (tmux server not running for this shell), or hook script not executable | `echo $TMUX`; `ls -la ~/.claude/scripts/orchestra-hook.sh` |
| Window spawns but never closes | `SubagentStop` hook failed or 120 s kill-window scheduling failed | Tail `invocations.log`; look for error lines stamped with your hostname/PID |
| `PLAN.md` is garbled | Atomic-rename pattern not used — subagent wrote directly instead of via `.tmp` + `rename` | Inspect for a `.tmp` sibling; update Planner prompt |
| `ExitPlanMode` never fires | Brain not in plan mode when delegating to Planner | Check Claude Code permission mode indicator; enter plan mode via `Shift+Tab` or `--permission-mode plan` |
| `/brain` command unrecognised | `~/.claude/commands/brain.md` missing or malformed frontmatter | `/help` lists known commands; inspect the file |
| Hook fires in projects where not wanted | Orchestra is now globally on (gate removed 2026-04-25) | Set `CLAUDE_ORCHESTRA_DISABLE_TMUX=1` to suppress tmux windows, or rename hook script to `.bak` for a full temporary disable |
| Logs growing unbounded | No rotation policy | v1 does not include log rotation. Periodically `rm ~/Gin-AI/projects/*/.claude/orchestra/*.log` or add logrotate config. |

### 12.5 What to do when `ExitPlanMode` is rejected

Reject semantics at G2:

- Brain stays in plan mode; does NOT dispatch Actor.
- Brain receives the rejection as a message and can redirect — e.g., ask Planner to revise based on user feedback, or abandon.
- `PLAN.md` on disk remains from the rejected version; next Planner invocation will overwrite via atomic-rename. If you want to keep rejected plans for audit, rename `PLAN.md` to `PLAN-rejected-<UTC-ts>.md` manually before asking Brain to retry.

### 12.6 Relationship to HomeAI

HomeAI is one of many projects the orchestra works with. ~~Opt in by creating `.enabled`.~~ As of 2026-04-25 orchestra is globally on; the state dir auto-creates on first Agent invocation. `.claude/orchestra/` is globally gitignored via `~/.gitignore_global` — no per-project `.gitignore` entry needed. HomeAI's own routing (LiteLLM, llama-server, Sonnet-via-Anthropic) is independent of Claude Orchestra — the orchestra operates on the Claude Code meta-layer (what model Claude Code uses to help you work on HomeAI), while HomeAI's routing decides what model HomeAI's runtime uses to serve its users. No conflict.

### 12.7 Lightweight duo pipeline (`/duo`)

A second, simpler invocation pattern added post-v1. One new file
(`~/.claude/commands/duo.md`), reuses `~/.claude/agents/actor.md` unchanged.

**Design**: Sonnet 4.6 as the main session IS the Plan tier — user interacts
with it directly across as many turns as needed before approving. No Planner
subagent, no Opus Brain. On approval, Actor (Haiku 4.5) receives the entire
plan in a single delegation and executes all steps uninterrupted. No Reviewer,
no review loop.

**Workflow**:
1. Start a Sonnet 4.6 session (`claude --model claude-sonnet-4-5`).
2. Enter plan mode (`Shift+Tab`).
3. Chat interactively — read files, refine scope, agree the plan.
4. Type `/duo` (or `/duo <task>`) to trigger Phase 2.
5. Sonnet writes PLAN.md and calls `ExitPlanMode` for approval.
6. On approval: Sonnet tells you to switch to `bypassPermissions` mode
   (`Shift+Tab` again), then delegates to Actor.
7. Haiku runs all steps without permission prompts.

**Cost**: Sonnet once (planning session) + Haiku once (all steps). No Opus,
no Reviewer. Cheapest orchestrated pipeline available.

**Risk trade-off**: no automated review means errors in Actor's output won't
be caught mechanically. Appropriate for simple, low-blast-radius tasks only.
Anything with architectural impact or hard-to-reverse changes belongs in
`/brain` which has the cap-3 review loop.

| | `/duo` | `/brain` |
|---|---|---|
| Plan model | Sonnet 4.6 (in-session) | Opus 4.7 → Planner (Sonnet subagent) |
| Act model | Haiku 4.5 | Haiku 4.5 |
| Review | None | Reviewer (Sonnet) × up to cap-3 |
| G2 gate | ExitPlanMode | ExitPlanMode |
| Steps sent to Actor | All at once | One at a time |
| Fits in one file | ✅ | ❌ (8 files) |

**Interaction with the hook**: the `implement` tmux window still spawns when
Actor runs (same `PreToolUse(Agent)` → `SubagentStop` hooks; Actor's
`subagent_type="actor"` maps to stage `implement`). Orchestra state files
are written to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/` automatically.

**When NOT to use `/duo`**: more than ~10 steps; multi-file refactors;
architecture-level changes; anything where you'd want a Reviewer. Use `/brain`.

### 12.8 What this document is not

- ~~Not an implementation — no files under `~/.claude/agents/` have been written yet as of the date above.~~ **Superseded 2026-04-24 21:10 CEST by the Implementation v1 section below.** The TODO companion doc (`Claude-code-tmux-pipeline--TODO.md`) contains the change-log / design-history; this document is the stable reference.
- Not an Anthropic-sanctioned pattern — several pieces (the Sequential Phase Architecture, the three-tier model-tier split, the "auto" preset with CROSS-CHECK) come from community sources and are layered on top of canonical Claude Code primitives.
- Not multi-user — the design assumes one user (Florian) across multiple hosts. Multi-user orchestration is out of scope.

---

## 13. Known limitations — why a full live feed is not possible

The live action feed added in 2026-04-25 (§4.5, §5.3 Gap 3) shows `Edit`, `Write`, and `Bash`
calls in real time inside the stage tmux windows. This is useful, but it is not the same as
the live feed a user sees when working interactively with Claude Code in the main session.

### 13.1 What a "full" live feed would show

When Claude Code runs interactively (Brain in window 1), the user sees:

1. **Thinking blocks** — the model's extended reasoning (`<thinking>…</thinking>`) streamed
   before the first tool call.
2. **Tool calls** — each tool use (Read, Edit, Write, Bash, …) with its arguments, shown as
   it is dispatched.
3. **Tool results** — the output returned from each tool, shown inline.
4. **Prose between tool calls** — any text the model emits between tool invocations.
5. **The final response** — the model's concluding message.

The stage windows currently show only item 2, partially (Edit/Write/Bash only; Read excluded
by design) — and only if `PreToolUse` hooks fire inside subagents (an assumption still pending
live confirmation).

### 13.2 Why the rest cannot be captured

**Hook system scope.** Claude Code's hook system exposes exactly four event types:
`PreToolUse`, `PostToolUse`, `SubagentStop`, and `PreCompact`. All four fire at tool-call
boundaries or session lifecycle points. None fire at model-output boundaries. The hooks have
no access to the token stream.

**Thinking blocks are model output, not tool calls.** The `<thinking>` content is part of the
Claude API response before the first `tool_use` block. It never passes through a hook. There
is no `PreThinking`, `PostThinking`, or streaming-chunk hook. Claude Code itself receives
the thinking content over the API and renders it in the interactive session, but the hook
script — a shell command invoked at discrete tool-call moments — has no channel to intercept it.

**Prose between tool calls is also model output.** When the model emits text like "Now I will
edit the file…" before calling Edit, that prose is in the API response stream. Same blind spot:
no hook fires for it.

**Tool results flow through the Claude Code process, not through hooks.** `PostToolUse` does
fire after each tool, and in principle could be used to append results to the logfile. But
tool results can be large (full file contents from a `Read`, long `Bash` output) and logging
them verbatim would produce unusable noise. The current design logs only the *call*, not the
*result*, which is why the feed shows `[14:32:07] BASH git diff --stat HEAD` but not the diff
itself.

**Subagents run inside the Claude Code process.** Unlike a standalone agent that writes to a
log file, a Claude Code subagent executes as an internal Agent tool call. Its full conversational
content (thinking → tool calls → tool results → prose → final output) exists only inside the
Claude Code process's memory. The `SubagentStop` hook receives the subagent's final return
value as a string, but nothing in between — and that string is not passed to the hook payload
in any accessible form in v1.

### 13.3 What would be required to close the gap

A truly full live feed would require one of:

1. **A Claude Code streaming hook** — a new hook type that fires on each streamed token or
   on each model-output chunk (thinking block, prose segment, etc.). This would require an
   Anthropic-side change to Claude Code's hook architecture. Not available in v1 or v2 as
   currently documented; would need to be raised as a feature request.

2. **A dedicated subprocess per subagent** (Option A from the design history, §9) — spawn
   each tier as a separate `claude --model … --print` process whose stdout Claude Code can
   pipe to the tmux window directly. This was explicitly rejected in favour of Option B
   (native subagents) because it requires managing inter-process communication and loses the
   native `ExitPlanMode` / permission-mode integration. Revisit only if native subagent
   visibility proves insufficient for real workflows.

3. **Agent self-reporting** (Tier 2 fallback) — instruct Actor/Planner/Reviewer to emit a
   structured progress line via `Bash` (e.g., `echo "[step] …" >> $LOGFILE`) after each
   significant action. This captures actor *intent* but not *thinking*, and requires every
   subagent prompt to carry the logfile path. Viable workaround; invasive.

### 13.4 Practical implication

The current live feed is best understood as a **tool-dispatch log**, not a reasoning transcript.
It answers "what is the subagent doing right now?" (editing this file, running that command)
but not "why is it doing it?" (thinking blocks) or "what did it see?" (tool results).

For use cases where reasoning visibility matters — debugging a misbehaving plan, auditing an
unexpected edit — the post-hoc per-invocation logfile (the file `live.log` points at) contains
the full prompt sent to the subagent, which encodes the plan and context. The thinking itself
remains inaccessible without a Claude Code architecture change.

---

## Implementation v1 — 2026-04-24 21:10 CEST (19:10 UTC)

### Files created / modified

| Path | Size | Purpose |
|---|---|---|
| `~/.claude/agents/planner.md` | new | Sonnet 4.6 subagent — reads codebase, writes numbered plan to `PLAN.md` via atomic-rename. `tools:` = `Read, Grep, Glob, WebFetch, TodoWrite` + narrow exception for `Write`/`Bash` limited to the atomic-rename on `PLAN.md`. Excludes `ExitPlanMode` (canonical — Brain-only). |
| `~/.claude/agents/actor.md` | new | Haiku 4.5 subagent — executes one scoped step, updates `TASKS.json` via atomic-rename. `tools:` = `Read, Edit, Write, Bash, Grep, Glob, TodoWrite`. System prompt documents hard denies (`rm -rf`, `git push`, `git commit` in v1) and strict scope discipline. |
| `~/.claude/agents/reviewer.md` | new | Sonnet 4.6 subagent — reads `git diff`, compares to PLAN.md, writes `review-comments.md` via atomic-rename. `tools:` = `Read, Grep, Glob, Bash, TodoWrite` (+ `Write` narrowly for review file). Emits verdict PASS / FIX / BLOCK. |
| `~/.claude/scripts/orchestra-hook.sh` | new, +x | Single hook dispatcher with three modes: `start` (PreToolUse), `end` (SubagentStop), `compact` (PreCompact). Branches on `$TMUX`, env-var `CLAUDE_ORCHESTRA_DISABLE_TMUX` opts out of tmux spawning even inside a session. ~~Gates on `${CLAUDE_PROJECT_DIR}/.claude/orchestra/.enabled` marker~~ — per-project gate removed 2026-04-25; hook now fires unconditionally. Stamps every log line and per-invocation logfile name with `host:pid:session:ts`. |
| `~/.claude/commands/brain.md` | new | `/brain` slash command — heavyweight opt-in pipeline. Requires plan mode; delegates to Planner → calls `ExitPlanMode` → dispatches Actor → Reviewer → loops cap 3 → halts with summary. Explicitly does NOT commit in v1. |
| `~/.claude/commands/orchestra-mode.md` | new | `/orchestra-mode` slash command — v1 stub. `default` / `acceptEdits` write preset to `state.env`; `auto` prints "not yet implemented in v1" with pointer to §10.2 of this doc. |
| `~/.claude/orchestra/config.yaml` | new | Global default config. v1 keys fully wired (`gates`, `review_loop_max`, `commit.policy`). v2 keys present as stubs (`crosscheck_loop_max`, `commit_auto`, `test_gate`, `token_budget_usd`) — honored only under `orchestra_mode: auto`. |
| `~/.claude/settings.json` | modified | Hook entries: `PreToolUse(Agent)` → `start`; `PreToolUse(Edit)` → `tool`; `PreToolUse(Write)` → `tool`; `PreToolUse(Bash)` → `tool`; `SubagentStop` → `end`; `PreCompact` → `compact`. All via `orchestra-hook.sh`. Existing `PreToolUse(Bash)` → `venv-enforce.sh` preserved. `Edit`/`Write`/`Bash` → `tool` entries added 2026-04-25. |

Directories newly created: `~/.claude/agents/`, `~/.claude/commands/`, `~/.claude/orchestra/`.

### Shared across machines via NFS

`~/.claude` is a symlink to `/mnt/nfs/Florian/Gin-AI/.claude`, so every file above is instantly visible on all Debian hosts that mount `~/Gin-AI/`. No per-host install step.

### Validation performed

1. **Syntax check** — `bash -n ~/.claude/scripts/orchestra-hook.sh` → OK.
2. **settings.json validity** — `jq . ~/.claude/settings.json` → OK; `jq -r '.hooks | keys[]'` → `PreCompact`, `PreToolUse`, `SubagentStop`.
3. **Opt-in gate** *(historical — gate removed 2026-04-25; see Amendment)* — Ran `start` with no `.enabled` marker in a fresh temp project → hook exited 0, no files created. Confirmed marker-gate behaviour at original install.
4. **Full lifecycle test** *(at original install, with `.enabled` gate active)* — Created `/tmp/orchestra-test-enabled/.claude/orchestra/.enabled`, fired `start`/`end` for each of `planner`/`actor`/`reviewer`, then `compact`. Verified:
   - Three tmux windows spawned with correct stage names (`plan`, `implement`, `review`).
   - Each window tailed its per-invocation logfile.
   - On `end`, windows renamed to `✓` suffix and `kill-window` scheduled in 120 s.
   - `invocations.log` contains stamped JSON lines with `{host, pid, session, ts}` per event.
   - `state.env` correctly records `LAST_WINDOW_*` / `LAST_LOGFILE_*` per stage.
   - `brain-state.md` generated with atomic-rename on `compact`.
   - Per-stage logfiles named `<stage>-<UTC-ts>-<HOSTNAME>-<PID>.log` as specified.
5. **Window-counter regression** — First (buggy) run had the `wc -l || echo 0` pipefail interaction that produced `plan_0` for what should have been `plan`. Root cause: under `set -o pipefail`, the pipeline's non-zero exit from `grep` (no matches) triggered the `|| echo 0` fallback AFTER `wc -l` already emitted "0", concatenating both values inside command substitution. Fixed by switching to `grep -cE` (always emits a single count, including `0` on no matches), swallowing all pipeline errors in a subshell, and post-filtering the captured value with `${existing//[^0-9]/}`. Re-tested clean: first invocation gets bare `plan`; subsequent invocations in the same tmux session get `plan_1`, `plan_2` as spec requires.

### Not tested live (deferred to first real use)

- Actual invocation through the Agent tool in a real Claude Code session — the hook fires when `Agent(subagent_type="planner")` etc. runs for the first time. Expected to work; hook is defensive (all errors swallowed, always exits 0, never blocks Claude Code).
- `ExitPlanMode` end-to-end flow (requires plan mode + user approval UI).
- Multi-host concurrent invocation (user confirmed this case is rare; design uses stamping rather than locking).
- PreCompact firing at real 100K-token threshold — only manually triggered in tests.

### Interaction notes for next session

1. **Orchestra is now globally on** (2026-04-25 amendment). No `.enabled` marker needed; no per-project `.gitignore` entry needed (covered by `~/.gitignore_global`). The state dir `.claude/orchestra/` auto-creates on first Agent invocation in any project.
2. **Entering plan mode** — `/brain` expects to be in plan mode before delegating to Planner. Either `Shift+Tab` cycle to plan mode before typing `/brain`, or let `/brain` prompt the user to enter it. Plan mode is Claude Code-native, not orchestra-specific.
3. **If auto-close is too aggressive** — Edit `tmux.auto_close_seconds` in `~/.claude/orchestra/config.yaml`. (v1 hook currently hard-codes 120; that value should move into the script reading the config in v2.)
4. **If you want logfile-only visibility even in tmux** — Export `CLAUDE_ORCHESTRA_DISABLE_TMUX=1` in the shell before launching `claude`. Hook respects this opt-out.
5. **Observed deviation from strict canon** — `settings.json` permission tooling uses the format it already had in place; the orchestra hook does not inject new `permissions.deny` rules for Actor (rely on Actor's system-prompt discipline in v1). If real over-reach happens in practice, add explicit denies in a future pass.

### Known v1 limitations (not bugs — deferred features)

| Limitation | Reason | Future fix location |
|---|---|---|
| Parallel Actor fan-out may close the wrong tmux window on `end` | v1 tracks last-window per stage in `state.env`; no unique correlation between `start` and `end` events for concurrent invocations of the same stage | v2 could use a per-invocation sentinel file with a unique token passed through the prompt |
| `/orchestra-mode` does not actually flip Claude Code permission mode | Deliberate — keeps v1 stub harmless; Axis X flip is user-driven via `Shift+Tab` | v2 `/orchestra-mode` implementation |
| `brain-state.md` payload is minimal (just pointers to state files + last 20 log lines) | Placeholder in v1; full payload schema depends on what `/brain-resume` will need | v2 schema refinement |
| No log rotation — `invocations.log` and per-invocation logfiles grow unboundedly | Acceptable for v1 usage volumes; user can `rm` periodically or add logrotate | Optional user-side hygiene |
| Window counter is tmux-session-wide, not per-project | A `plan` window from one project blocks `plan` in another until it auto-closes | Acceptable; window names include stage, not project; 120 s auto-close limits overlap |
| Hook writes a stale state.env entry that persists indefinitely | Each `start` appends a new `LAST_WINDOW_<STAGE>=…` line; `state.env` grows | Low-impact; later lines shadow earlier when sourced; a `state.env.tmp`+rename rewrite could be added if the file grows uncomfortably large |

### Rollback procedure

If the orchestra misbehaves and you need to disable it quickly:

1. **Per-project disable** — ~~delete `.enabled` marker~~ **(gate removed 2026-04-25)**. To suppress orchestra in a specific project, set `CLAUDE_ORCHESTRA_DISABLE_TMUX=1` to suppress tmux windows, or temporarily rename the global hook script to `.bak` (affects all projects). A per-project opt-out marker is not currently implemented; add one if needed.
2. **Global disable** — `mv ~/.claude/scripts/orchestra-hook.sh{,.bak}`. Subsequent Claude Code sessions will see the hook fail loudly (intentional — not silent). Rename back to restore.
3. **Full uninstall** — `rm -rf ~/.claude/agents/{planner,actor,reviewer}.md ~/.claude/commands/{brain,orchestra-mode}.md ~/.claude/scripts/orchestra-hook.sh ~/.claude/orchestra/`, then edit `~/.claude/settings.json` to remove the three orchestra hook entries. Existing per-project `.claude/orchestra/` state dirs may be left for forensic reading or removed separately.

### Next steps (user-facing)

1. **Smoke test in HomeAI** — opt it in (step 1 of "Interaction notes"), then run a small `/brain` pipeline on a trivial task to verify the windows spawn and the gate fires. Good first task: "Add a docstring to `rag_engine/search.py::search_rag`" — small, reviewable, low-risk.
2. **Tune Actor deny rules** — once a few `/brain` runs expose any overreach patterns, add explicit `permissions.deny` entries in `~/.claude/settings.json` rather than relying solely on system-prompt discipline.
3. **Build v2 when appetite arrives** — `orchestra_mode: auto`, CROSS-CHECK, branch isolation, checkpoint commits, test gate, halt-and-resume. All documented in §10.2 of this file.

### Amendment — 2026-04-25: remove per-project `.enabled` opt-in gate

Orchestra is now globally on everywhere the install is present. No per-project `.claude/orchestra/.enabled` file is needed or checked.

**Changes made:**
- `orchestra-hook.sh` — removed `ENABLED_MARKER` variable and the early-exit gate (`if [ ! -f "$ENABLED_MARKER" ]; then exit 0; fi`). Hook now fires on every project unconditionally; state dir is auto-created on first invocation.
- `status-line.sh` — changed the orchestra-block condition from `[ -f "$cwd/.claude/orchestra/.enabled" ]` to `[ -f "$HOME/.claude/orchestra/config.yaml" ]`. The global config file is the enable signal; badge now shows in all projects whenever orchestra is installed.
- `brain.md` — removed prerequisite #2 (`.enabled` check + offer to create it); removed "if orchestra-enabled" conditionals around `state.env` writes; `mkdir -p` added to the state.env write command so the dir auto-creates on first `/brain` run.
- `duo.md` — same: removed all "if orchestra-enabled" conditional branches; `mkdir -p` added to Phase 1 `state.env` write.
- `~/.gitignore_global` — created with `.claude/orchestra/` entry; `git config --global core.excludesFile ~/.gitignore_global` set. Globally gitignored across all machines (shared via NFS home).

**Why removed:** the per-project `.enabled` file solved a noise problem (surprising behaviour in projects the user hadn't opted in), but the noise problem doesn't exist when orchestra is a deliberate global install on a personal machine. The gate added friction for every new project without meaningful safety value. `CLAUDE_ORCHESTRA_DISABLE_TMUX=1` remains available if tmux-window suppression is ever needed on a per-session basis.

**Note on `/duo`:** `/duo` was added by the user between sessions (2026-04-24 23:47) and already handled absent `.enabled` gracefully (warned but continued). The amendment makes its behaviour consistent with `/brain` — no warning, no conditional, always writes state files.

### Amendment — 2026-04-24 (end-of-day): auto-doc / memory + status-line visibility

Three post-install polish items added on the same day as v1 shipped. No new agents, no new stages, no settings changes, no hook changes.

**1. Planner considers doc impact in every plan.**
`~/.claude/agents/planner.md` — the "What your plan must contain" section now includes a new item 4 ("Doc impact") requiring every Planner-generated plan to explicitly consider whether the change affects any project doc (root-level `*.md`, `docs/`, files named in CLAUDE.md's inventory), and include explicit numbered step(s) for updating them when applicable. Default posture: if the code changes something a human reader of the docs would currently believe is true, the doc must be updated in the same plan. Out-of-scope deferrals go in the "Out of scope" section explicitly.

**2. `/brain` Phase 4 does doc-delta and memory-worthy-fact checks.**
`~/.claude/commands/brain.md` — Phase 4 (VERIFY / DONE) rewritten from 3 steps to 5:
- Consolidate state (read TASKS.json).
- Doc-delta check: run `git diff --stat HEAD`, ask whether any doc not in the plan is affected, dispatch Actor ONCE more if yes (one Actor invocation + one Reviewer pass, still bounded by cap-3 FIX-loop policy).
- Memory-worthy-fact check: Brain evaluates whether anything from the pipeline is persistence-worthy per the four memory types in the global CLAUDE.md (user / feedback / project / reference), and if yes updates `~/.claude/projects/<encoded-pwd>/memory/` directly. **Not delegated to Actor** — Actor is unaware of Claude-side auto-memory by design.
- Final summary (now includes doc updates and memory entries if any).
- Do not commit / push / open a PR (unchanged from v1).

**3. Status line shows orchestra state.**
`~/.claude/scripts/status-line.sh` — a new conditional block runs after the existing git-branch field. ~~Originally activated only when `.enabled` existed~~ — see Amendment 2026-04-25; now activates whenever the global orchestra config is present (`~/.claude/orchestra/config.yaml`). Three new fields:

| Field | Example | When shown |
|---|---|---|
| Preset badge | `♪ default` | Always when orchestra-enabled. Reads `ORCHESTRA_MODE=…` from `state.env`; falls back to `default`. |
| Active subagent | `▶ Haiku:implement` | A `start` event in `invocations.log` has no later matching `end`. Tier maps: `planner`/`reviewer` → Sonnet; `actor` → Haiku. |
| Overflow warning | `⚠ >200K` | Brain's `tokens_used > 180000` (10% safety margin under the shared 200K ceiling for all subagent tiers — Haiku Actor and Sonnet Planner/Reviewer alike). Actionable: signals "`/clear` or `/compact` before `/brain`". |

Idiomatic choices (matching the existing Gruvbox script's style):

- **Glyphs**: `♪ ▶ ⚠` are all monospace Unicode dingbats consistent with the existing `✦ ◆ ⎇ ↯ ■ □` set; no emoji (earlier drafts used `🎼` but emoji have variable width and can misalign monospace terminals). Alternatives documented inline as `DESIGN OPTIONS` comments in the script, mirroring the existing progress-bar comment pattern.
- **Colors**: three new Gruvbox-palette entries — `ORCHESTRA_COLOR` (bright_purple `#D3869B`, distinct from every other field), `ACTIVE_COLOR` (dark_yellow `#D79921`), `WARNING_COLOR` (bright_orange `#FE8019`). The earlier draft used Aqua for the orchestra badge which duplicated the filled-bar color — swapped to bright_purple to eliminate visual collision.
- **jq consolidation**: one `@tsv` pass parses the three start-line fields in a single jq invocation instead of three separate pipes.
- **Consistency with existing guards**: `[ "$tokens_used" -gt 180000 ]` uses no stderr redirect — matches the existing `[ "$tokens_used" -gt 0 ]` on line 83.

Script validated with `bash -n`; five test scenarios (non-orchestra / orchestra idle / Haiku Actor running / Brain over-threshold / Sonnet Planner running) render correctly.

### Amendment — 2026-04-25 (branched session `Claude-orchestra-light`): lightweight `/duo` pipeline + badge disambiguation

Two additions made in a branched conversation (`Claude-orchestra-light`) after the main v1 session closed. No new agents, no new hooks, no settings changes. One new slash-command file; two existing slash-command files lightly amended.

**1. New lightweight pipeline: `/duo` (Sonnet Plan → Haiku Act)**

File: `~/.claude/commands/duo.md` (new).

Rationale: the full `/brain` pipeline (Opus 4.7 Brain → Planner subagent → per-step Actor/Reviewer loops → Phase 4 doc/memory checks) is the right tool for multi-file refactors, architecture work, and anything where a review loop matters. For simple, well-scoped tasks — a targeted bug fix, adding one function, tweaking config — the overhead is disproportionate. `/duo` offers the same G2 plan-approval gate and Haiku execution with none of the review scaffolding.

Design:

| Aspect | `/duo` | `/brain` |
|---|---|---|
| Plan model | **Sonnet 4.6 (main session, interactive)** | Opus 4.7 → Planner subagent (Sonnet, one-shot) |
| Planning style | Multi-turn conversational — user and Sonnet negotiate scope, read files, refine approach before approving | Single Planner subagent call; Brain delegates autonomously |
| G2 gate | ExitPlanMode (same) | ExitPlanMode (same) |
| Execute | Haiku 4.5 Actor, **all steps in one delegation** | Haiku 4.5 Actor, one step at a time |
| Review | None | Reviewer (Sonnet) × up to cap-3 per step |
| Phase 4 | Minimal summary + memory check | Full doc-delta check + memory check |
| Cost | Sonnet session (planning) + one Haiku call | Opus session + Sonnet×N + Haiku×N + Sonnet (Reviewer) |
| New infrastructure | 1 file | 8 files (v1 initial install) |

Workflow:
1. Launch a Sonnet 4.6 session: `claude --model claude-sonnet-4-5`.
2. Enter plan mode (`Shift+Tab`).
3. Chat interactively with Sonnet — read files, refine scope — until the plan is agreed.
4. Type `/duo` (or `/duo <task description>`).
5. Sonnet writes `PLAN.md` (if orchestra-enabled) and calls `ExitPlanMode`.
6. On approval: tell the user to cycle to `bypassPermissions` (`Shift+Tab`), then delegate entire plan to Actor (Haiku) in one Agent call.
7. Actor executes all steps without permission prompts; reports a diff summary.
8. Sonnet produces final summary; restores `ORCHESTRA_MODE=default` in `state.env`.

Risk trade-off: no automated review means errors in Actor's output won't be caught mechanically. Appropriate for low-blast-radius tasks only. Anything with deep interdependencies or architectural impact belongs in `/brain`.

Reuses `~/.claude/agents/actor.md` unchanged. Hook infrastructure (PreToolUse Agent → `implement` tmux window) fires automatically. Orchestra state files (PLAN.md, TASKS.json, invocations.log) are written to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/` — created automatically on first invocation.

**2. Status-line badge disambiguation**

Problem: the status-line badge showed `♪ default` in all orchestra contexts — whether idle, whether `/brain` was running, or whether `/duo` was running. Not enough information.

Changes:

| State | Badge | How it's set |
|---|---|---|
| Idle (no pipeline running) | `♪ default` | Default fallback; restored by pipeline teardown |
| `/brain` active | `♪ orchestra` | `brain.md` Phase 1 appends `ORCHESTRA_MODE=orchestra` to `state.env` |
| `/duo` active | `♪ duo` | `duo.md` Phase 1 appends `ORCHESTRA_MODE=duo` to `state.env` |
| `/orchestra-mode acceptEdits` | `♪ acceptEdits` | Written by `/orchestra-mode` command |
| `/orchestra-mode auto` (v2) | `♪ auto` | Written by `/orchestra-mode` command |

Files modified:
- `~/.claude/commands/brain.md` — Phase 1 start: `echo "ORCHESTRA_MODE=orchestra" >> state.env`; Phase 4 done (new step 5): `echo "ORCHESTRA_MODE=default" >> state.env`.
- `~/.claude/commands/duo.md` — Phase 1 start: `echo "ORCHESTRA_MODE=duo" >> state.env`; Phase 4 done: `echo "ORCHESTRA_MODE=default" >> state.env`.

No changes to `status-line.sh` — it already reads `ORCHESTRA_MODE` via `grep … | tail -n 1` (last-write-wins semantics on `state.env`), so the new values render automatically. Validated with four badge values (`default`, `orchestra`, `duo`, `acceptEdits`) — all render correctly.

**Notable design point — `state.env` append semantics**: both pipelines append rather than rewrite `state.env`, consistent with the existing hook pattern. The file accumulates pairs of lines per pipeline run (`MODE=orchestra` on start, `MODE=default` on done). The status-line reads the last occurrence (`grep … | tail -n 1`), so earlier lines are shadowed. No cleanup is needed, but `state.env` will grow slowly over many sessions; a periodic trim is acceptable hygiene.

**Validation — idempotency audit (2026-04-25, post-restructure)**

All deployed files verified identical between the repo and `~/.claude/`:

| File | Repo path | Live path | Status |
|---|---|---|---|
| planner.md | `.claude/agents/planner.md` | `~/.claude/agents/planner.md` | ✅ identical |
| actor.md | `.claude/agents/actor.md` | `~/.claude/agents/actor.md` | ✅ identical |
| reviewer.md | `.claude/agents/reviewer.md` | `~/.claude/agents/reviewer.md` | ✅ identical |
| brain.md | `.claude/commands/brain.md` | `~/.claude/commands/brain.md` | ✅ identical |
| duo.md | `.claude/commands/duo.md` | `~/.claude/commands/duo.md` | ✅ identical |
| orchestra-mode.md | `.claude/commands/orchestra-mode.md` | `~/.claude/commands/orchestra-mode.md` | ✅ identical |
| orchestra-hook.sh | `scripts/orchestra-hook.sh` | `~/.claude/scripts/orchestra-hook.sh` | ✅ identical |
| config.yaml | `config/config.yaml` | `~/.claude/orchestra/config.yaml` | ✅ identical |
| Orchestra hooks in settings | `config/settings-hooks.json` | `~/.claude/settings.json` `.hooks` | ✅ all 3 entries match |
| design.md | `docs/design.md` | symlink → `~/Gin-AI/chats/Claude-orchestra.md` | ✅ identical |
| design-history.md | `docs/design-history.md` | symlink → `~/Gin-AI/chats/Claude-code-tmux-pipeline--TODO.md` | ✅ identical |

**Smoke test of `/duo` pipeline (2026-04-25)**

| Step | Result |
|---|---|
| Plan-mode gate check (first invocation — no plan mode) | ✅ Detected; prompted user to `Shift+Tab` first |
| Plan mode active (second invocation) | ✅ Detected correctly |
| Explore subagent (repo state read) | ✅ Launched; returned accurate current state |
| Stale plan detection | ✅ Identified that existing `PLAN.md` described already-committed work |
| `AskUserQuestion` | ✅ Rendered and returned answer |
| `state.env` write (`ORCHESTRA_MODE=duo`) | ⏸ Blocked by plan mode — correct; fires after ExitPlanMode approval in real use |
| `ExitPlanMode` | ⏸ Not called — no real task to approve (correct for a smoke test) |

The pipeline is wired correctly. The `state.env` badge write is intentionally placed after plan approval — it fires in Phase 1 execution, not during the planning conversation itself.

### Amendment — 2026-04-25 (follow-up session): deploy target disambiguation + repo restructure (later reverted)

**1. `deploy.sh` gained `--global`/`--local` target flags** — subsequently simplified. See Amendment 2026-04-26.
~~`--global` and `--local` were mutually exclusive required arguments; `--dry-run` and `--diff` were additive.~~

**2. Repo restructured to mirror `~/.claude/` layout (Option B) — subsequently reverted.** See Amendment 2026-04-26.
~~`agents/` and `commands/` moved into `.claude/` inside the repo. Claude Code picked up dev versions automatically when launched inside the repo. No deploy step needed to test agent/command changes.~~

### Amendment — 2026-04-26: `deploy.sh` simplified — `--local` removed

`--global` and `--local` target flags removed. `./deploy.sh` always deploys to `~/.claude/`. `--dry-run` and `--diff` remain.

**Rationale:** `--local` created invisible divergence — two different versions of the same agent could be active in different projects simultaneously with no status-line indication. Without the per-project `.enabled` gate, there is no natural counterpart to `--local`. The correct workflow is: edit → commit → `./deploy.sh` → test in any project. If a staged-rollout is ever needed, that belongs in a separate test project with an explicit explicit opt-in, not a hidden local override.

### Amendment — 2026-04-26: revert Option B — explicit deploy model

Option B (repo `.claude/agents/` auto-discovery) was reverted. The reason: dogfooding is an intentional, as-agreed step — not something that should happen automatically whenever Claude Code is launched in the repo. Silent shadowing of the deployed versions was undesirable.

**What changed:**

- `agents/` and `commands/` moved back to repo root (from `.claude/agents/` and `.claude/commands/`). Git history preserved via `git mv`.
- `.claude/` in the repo is now **entirely gitignored** — it is pure runtime (orchestra state, local-deploy artifacts). No source files live there.
- `deploy.sh` and `collect.sh` paths updated to match top-level `agents/` and `commands/`.
- Claude Code running in this repo has **no** project-level agents or commands active. It uses `~/.claude/` exclusively.
- Deploying is an explicit, conscious step: `./deploy.sh` (always targets `~/.claude/`; see Amendment 2026-04-26 below).

**Current repo layout (post-revert):**
```
agents/           ← source: planner, actor, reviewer
commands/         ← source: brain, duo, orchestra-mode
scripts/          ← source: orchestra-hook.sh
config/           ← source: config.yaml, settings-hooks.json
status-line/      ← standalone orchestra-block.sh
docs/             ← design.md (symlink), design-history.md (symlink)
.claude/          ← runtime only, gitignored entirely
```

**No silent shadowing.** Changes to agent/command files only take effect after an explicit deploy.

### Amendment — 2026-04-26: Brain critical stance + Planner pedantic posture

Behavioral changes to `brain.md` and `agents/planner.md`:

**Brain (`commands/brain.md`) — Critical stance section added before the pipeline.**
Before delegating to Planner, Brain must interrogate the request:
- Push back on the request itself — challenge framing, necessity, and clarity before accepting.
- Surface alternatives explicitly — when multiple approaches exist, present each with concrete pros/cons and require an explicit user choice; do not silently pick one.
- Force clarity at every gap — definition of done, scope, reuse vs replace, test expectations, API/contract impact must all be unambiguous before proceeding.
- Be sceptical of the plan Planner returns — Brain reviews critically (is the approach matched? are risks covered? were silent choices made?); iterate with Planner rather than surfacing a bad plan.

**Planner (`agents/planner.md`) — Pedantic posture section added before the plan structure.**
Before producing a plan, Planner challenges the task:
- Demand precision from the caller — if Brain's prompt is ambiguous (wrong target, unspecified scope, unresolved approach choice), return questions rather than guessing.
- Surface alternatives at step level — when a step can be implemented in multiple meaningful ways, name options with pros/cons and mark pending decisions; applies especially to data model, API contracts, error handling, dependencies, test scope.
- Be aggressive about risks — the Risks/unknowns section is mandatory and substantive; unverifiable assumptions and system boundary gaps must be flagged loudly.
- Flag scope creep — anything implied by the task but not explicitly mentioned must be named as in-scope or explicitly deferred in "Out of scope".

### Amendment — 2026-04-25: live action feeds in stage windows

Three related changes shipped together. All are in `scripts/orchestra-hook.sh` and the hook configuration; no agent prompt files changed.

**Problem:** tmux stage windows (`plan`, `implement`, `review`) showed only the prompt text and a static "Subagent running…" line for the entire duration of subagent execution. Edits, bash calls, and writes made by Actor/Planner/Reviewer were invisible until the subagent finished. Gap 3 in §5.3.

**Changes:**

1. **`live-stage.env`** — a new overwrite file (not append-only like `state.env`) tracking the currently-active logfile.
   - On `start`: `printf 'ACTIVE_LOGFILE=%s\n' "$LOGFILE" > "${ORCHESTRA_DIR}/live-stage.env"` (overwrites; no concurrency concern — one subagent active at a time in v1).
   - On `end`: `rm -f "${ORCHESTRA_DIR}/live-stage.env"` (clears the pointer so `tool` hooks no-op after the subagent finishes).

2. **`live.log` symlink** — stable path for `tail -f` in VSCode (no need to find the timestamped logfile).
   - On `start`: `ln -sfn "$LOGFILE" "${ORCHESTRA_DIR}/live.log"` (outside `in_tmux()` guard; useful in all environments).
   - Updated on every new subagent dispatch; persists after `end` pointing at the last run's log.

3. **`tool` mode in `orchestra-hook.sh`** — new `case` branch triggered by `PreToolUse(Edit|Write|Bash)`.
   - If `live-stage.env` absent → exit 0 (no-op in non-orchestra sessions).
   - Sources `live-stage.env`, extracts `ACTIVE_LOGFILE`.
   - Appends `[HH:MM:SS] TOOLNAME param` to the logfile (truncated to 120 chars).
   - All errors swallowed; always exits 0.

4. **New PreToolUse matchers in `settings.json`** and `config/settings-hooks.json`: `Edit`, `Write`, `Bash` → `orchestra-hook.sh tool`. Existing `Bash` → `venv-enforce.sh` preserved; deploy merge logic updated to preserve non-orchestra PreToolUse entries by command string.

5. **`deploy.sh` idempotency fix** — old check tested only for `SubagentStop` presence; now computes the set of orchestra PreToolUse matchers and re-merges only when the set diverges.

**VSCode guidance updated:** `brain.md` and `duo.md` now point to `tail -f live.log` instead of `invocations.log | jq .`. Single `tail -f live.log` follows the full pipeline across all stages.

**Permission toggle note added to `duo.md`:** Phase 3 dispatch message now reminds the user to press `Shift+Tab` before Actor is dispatched if they want `default` (per-edit confirmation) instead of `bypassPermissions` (uninterrupted). No code change — prose only.

**Verification caveat:** smoke-tested all paths (no-op without `live-stage.env`; `start` creates pointer + symlink; `tool` appends live lines; `end` clears pointer; `tool` no-ops again after end; deploy idempotent on second run). Whether `PreToolUse` fires for tool calls *inside* a subagent (vs. only in the parent session) is the key open question — not yet confirmed by a live pipeline run. If hooks don't fire inside subagents, Tier 2 fallback (actor self-reporting via Bash after each step) would be needed.

### Amendment — 2026-04-26: migrate to Option A — per-tier `claude -p` subprocesses

The architecture was migrated from Option B (native Agent tool subagents) to Option A
(headless `claude -p` subprocess per tier) for `/brain` and `/duo` pipelines. Hard cutover —
the native Agent-tool dispatch path was removed from these commands.

**Why now.** The PreToolUse-based live feed shipped 2026-04-25 only showed tool-call lines
(Edit/Write/Bash) — no thinking, no prose, no tool results. The user's expectation that
`/brain` and `/duo` should show a feed comparable to interactive default mode required
crossing the hook boundary. Hooks fire only at tool-call boundaries; model output (thinking
blocks, prose between tool calls) is never exposed to hooks. Option A solves this by running
each tier as its own `claude -p` process whose `--output-format stream-json --include-partial-messages`
output we render via `format-stream.sh` — capturing the full event stream including
thinking-block boundaries (encrypted content via `signature_delta`, but visible status),
tool calls with arguments, tool results with stdout/stderr, and final result.

**Why Option A now versus when originally rejected.** The 2026-04-24 rejection (design-history.md §3)
cited three cons: three concurrent API bills, handoff friction (mailbox + inotifywait + tmux
send-keys), and "parallelism visual only". All three are no longer relevant: tiers run
sequentially (not concurrent — same cost as Agent tool); file-polling handoff is far
simpler than inotifywait; the pipeline is sequential by design. The implied loss of
`ExitPlanMode` and permission-mode integration is also resolved — `ExitPlanMode` is called
by Brain (the native session) regardless of how tiers are dispatched, and per-subprocess
`--permission-mode` is *better* than session-level Shift+Tab.

**Components added.**

- `scripts/format-stream.sh` — line-by-line `stream-json` parser → human-readable terminal
  output. Renders `system.init` header, `content_block_start/delta/stop` events for thinking
  (with elapsed time) and text (streamed), tool_use blocks (consolidated from `assistant`
  message), and tool results (from `user` message + Claude-Code-specific `tool_use_result`
  field). Writes final result text to `$RESULT_FILE` env var on `result` event arrival.
- `scripts/run-tier.sh` — spawns the `claude -p` subprocess. In tmux: `tmux new-window`
  named for the stage; outside: detached `nohup` writing to `live.log`. Sets up the
  `live-stage.env` pointer at start and clears it at end (subprocess always cleans up via
  `; rm -f live-stage.env` appended to its pipeline).
- `~/.claude/agents/.stripped/` — frontmatter-stripped versions of `actor.md`, `planner.md`,
  `reviewer.md`. Generated at deploy time. Consumed by `run-tier.sh` via
  `--append-system-prompt-file`. Pre-stripping at deploy is optimization (2) for
  byte-stable system prompts (max prompt-cache reuse).

**Components used (Claude Code CLI flags).**

- `--bare` — skip hooks, CLAUDE.md auto-discovery, plugins, attribution, auto-memory,
  background prefetches, keychain reads. Replaces the originally-planned
  `CLAUDE_ORCHESTRA_DISABLE_ALL` env-var guard. Cleaner: hooks simply do not fire inside
  the subprocess.
- `--model <model>` — explicit per-tier model selection. `claude-sonnet-4-6` for
  Planner / Reviewer; `claude-haiku-4-5-20251001` for Actor.
- `--permission-mode <mode>` — explicit per-tier permission mode. `default` for read-only
  tiers (Planner, Reviewer); `bypassPermissions` for Actor (uninterrupted execution).
- `--allowedTools "<comma-list>"` — explicit per-tier tool whitelist (matches the
  `tools:` frontmatter from the Option B agent files).
- `--append-system-prompt-file` (×2 or ×3) — stripped agent file + global CLAUDE.md +
  project CLAUDE.md (the latter two replace `--bare`'s skipped CLAUDE.md auto-discovery).
- `--output-format stream-json --include-partial-messages --verbose` — required combination
  for streaming events. `--verbose` is mandatory (validated empirically; `claude -p` rejects
  `stream-json` without it).
- `--no-session-persistence` — subprocess sessions don't write to `~/.claude/sessions/`.
  Avoids polluting transcript history with tier-internal state.

**Within-tier prompt-cache reuse — preserved.** The Anthropic edge cache is keyed on the
prefix bytes (system prompt + tools + initial messages). The same byte-stable prefix is
sent on every Planner / Actor / Reviewer invocation (frontmatter pre-stripped, no per-call
templating in the system prompt), so within-tier calls within the 5-min default TTL hit
cache. Cross-tier reuse is impossible by design (different system prompts) and was not
possible under Option B either. Brain's own session cache is unaffected.

**Optimizations shipped.**

1. Byte-stable system prompts — `run-tier.sh` always passes the same flags in the same
   order; agent files have no time-varying data.
2. Pre-stripped agent files at deploy time — `deploy.sh` produces
   `~/.claude/agents/.stripped/<name>.md` once per deploy. `run-tier.sh` consumes the
   stripped version. Avoids ~50ms of stripping per invocation and guarantees byte-identical
   prefixes.

**Optimizations deferred to v2 — see TO DO sections below.**

3. Persistent subprocess per tier (one long-lived `claude -p --input-format stream-json`
   per tier, multiple turns streamed to it) — eliminates startup overhead per call,
   maintains session context across calls. Defer until profiling shows startup cost matters
   in real pipeline runs.
4. 1-hour TTL prompt caching — Anthropic supports `cache_control: {ttl: "1h"}` with ~30%
   premium on cache writes. `claude -p` does not currently expose TTL via CLI flag, so
   would require Claude Code adding the flag or moving to direct SDK calls. Defer until
   measurement (TTL-miss-rate per tier from `cache_read_input_tokens` /
   `cache_creation_input_tokens` in API usage data) shows it would pay back.

**Trade-offs accepted.**

- *Context isolation.* The subprocess has no access to Brain's conversation history. Brain
  must serialise everything into the prompt explicitly. brain.md and duo.md updated to
  emphasise this.
- *Subprocess startup overhead.* ~1–2 s per invocation, accepted for v1 simplicity.
  Persistent-subprocess optimization (3) will eliminate this in v2 if needed.
- *Cross-environment behaviour.* In tmux: each tier gets its own named window (`plan`,
  `implement`, `review`), auto-closing 120s after completion. In VSCode (no tmux):
  subprocess runs detached, output written to `live.log` symlink — user tails one terminal
  split for the whole pipeline.

**Hard cutover, no fallback flag.** No new `orchestra-mode` preset; the native Agent-tool
path is gone from `/brain` and `/duo`. Rollback is via `git revert` if Option A surfaces a
real-world blocker. Ad-hoc Brain-driven research subagents (Explore, general-purpose) keep
using the native Agent tool — they are not pipeline tiers.

### Known limitations of Option A (post-migration)

| Limitation | Workaround / future fix |
|---|---|
| Thinking-block content is encrypted via `signature_delta` (model-side; not Claude-Code-specific) | Show "💭 thinking… (Ns)" status only; reasoning text inaccessible. Same as Claude Code interactive mode. |
| Subprocess startup ~1–2 s per call | v2 optimization (3) — persistent subprocess |
| Brain's Bash tool call blocks for the tier's full duration (potentially 5–10 min for Actor) | Bash tool timeout must accommodate; brain.md polling loop capped at 300 × 2 s = 10 min |
| Concurrent tier subprocesses in same project would write to overlapping `live-stage.env` | Acceptable — pipeline is sequential by design; not relevant in v1 |
| Failed subprocess (crash, API error) doesn't write `RESULT_FILE` → Brain polls forever | Caller's `for i in $(seq 1 300)` cap prevents infinite blocking; surface "tier did not complete in 10 min" to user |

### TO DO — v2 optimization (3): persistent subprocess per tier

**Premise.** Each tier currently spawns a fresh `claude -p` subprocess per invocation
(spawn-per-call). For pipelines with many fix-loop iterations or many plan steps, this
incurs ~1–2 s of startup overhead per call (loading config, parsing CLAUDE.md, initialising
tools).

**Approach.** Keep one `claude -p --input-format stream-json --output-format stream-json`
subprocess alive per tier across the entire pipeline run. Brain streams new task prompts
to it via stdin (turn-by-turn input); subprocess responds via stdout. Lifecycle: open at
start of Phase 3, close at end of Phase 3.

**Assumptions to verify before implementing.**
- `claude -p --input-format stream-json --output-format stream-json` accepts continuous
  turn-based input (not just one-shot)
- The stream-json `result` event marks turn boundaries cleanly so Brain can read full
  responses and the subprocess waits for the next prompt
- Subprocess crashes are rare enough that recovery cost is acceptable

**Implications.**
- Eliminates startup overhead per call
- Maintains session context across calls — Actor remembers what it did in step 1 when
  working on step 2 (currently context must be re-serialised by Brain)
- Maximises within-pipeline cache reuse — one continuous session, no TTL concerns
- Brain protocol shifts from spawn/poll/teardown-per-call to open/stream/stream/close-per-tier
- Tmux UX: one long-lived window per tier instead of one per invocation
- Failure mode: subprocess crash mid-pipeline loses tier session; recovery requires
  restarting and re-sending prior context (or accepting the loss for that pipeline run)

**When to revisit.** After v1 (spawn-per-call) ships and is stable, profile real pipeline
runs:
- If startup overhead exceeds ~5% of total wall-clock time per pipeline run, OR
- If "Actor doesn't remember step 1 when running step 2" causes coordination bugs that
  cost more in extra steps than persistent-subprocess complexity costs to maintain

then implement persistent subprocess. Otherwise the simplicity of spawn-per-call wins.

### TO DO — v2 optimization (4): 1-hour TTL prompt caching

**What it is.** Anthropic's prompt cache supports two TTL tiers:
- Default: 5 minutes (included in standard pricing)
- Extended: 1 hour (requires `cache_control: {type: "ephemeral", ttl: "1h"}` in the API
  request, with ~30% premium on the cache-write multiplier; cache reads cost the same)

**Why deferred.** `claude -p` does not currently expose `cache_control` TTL via CLI flag.
Implementation would require either Claude Code adding the flag, or moving to direct
Anthropic SDK calls (non-trivial).

**When it might pay off.**
- Pipelines that span >5 minutes between same-tier calls (long Actor steps where
  Reviewer's prior cache expires before the next call)
- Long human-decision pauses at G2 (`ExitPlanMode`) — user takes 10+ min to read the plan
- Heavy daily use where one user runs many `/brain` pipelines on similar tasks

**How to quantify.**

1. Instrument tier invocations to log API usage data:
   - `cache_creation_input_tokens` (cache write occurred)
   - `cache_read_input_tokens` (cache hit)
   - timestamp + tier + invocation ID

   These fields are already present in the `result.usage` block of the stream-json `result`
   event (verified empirically — see Amendment). Capture by parsing in `format-stream.sh`
   and appending to a usage log.

2. Run a representative sample (5–10 typical `/brain` runs, 5–10 typical `/duo` runs)
   covering normal task variety.

3. For each tier, compute the *miss rate due to TTL expiry*:
   - missed = invocations where the same tier's prefix was sent within prior 1 hour but
     >5 min ago (cache would have hit at 1h TTL but expired at 5m TTL)
   - rate = missed / total within-tier invocations

4. Decision rule: if any tier shows TTL-miss-rate >20%, 1-hour TTL would help that tier.
   Apply selectively (only the tier(s) that need it), not blanket.

5. Cost comparison:
   - Status quo: each TTL-miss costs full-input-rate × prefix tokens
   - With 1h TTL: extra ~30% premium on cache write paid once, then hits at 10% of normal
     rate
   - Break-even: at TTL-miss-rate r, switching is worthwhile when
     `r > 0.30 / (1.00 - 0.10) ≈ 33%` (rough — actual pricing has nuances)

### Amendment — 2026-04-26: `/brain` Phase 0 — RESEARCH (Option II.b + concurrent runs)

This amendment adds a formal **Phase 0 — RESEARCH** to `/brain`, splits the orchestration
into a launcher + spawned-session model, introduces a multi-run registry, and decouples
pipeline state into per-run subdirectories. Substantial architecture change to `/brain`;
`/duo` left unchanged.

**Origin.** User wanted Opus 4.7 specifically for the dialogue ("a more high-powered
dialog"). Inline cannot deliver model switch — a slash command has no API to change the
host session's model. The fix: spawn a **separate** interactive Claude session for Phase 0.

**Architecture: Option II.b + concurrent (a)** — Phase 0 dialogue runs in its own
interactive `claude` session in a separate tmux window (or terminal split for VSCode).
Launcher chat panel is freed after dispatching Phase 0; operator returns to launcher and
runs `/brain-resume <slug>` once research is done.

#### Three levels of decoupling now in place

| Level | What | Mechanism |
|---|---|---|
| 1 — Tier execution | Each tier runs as its own `claude -p` subprocess | Option A — `run-tier.sh` |
| 2 — Phase 0 dialogue | Phase 0 in its own interactive `claude` session, with its own model | This amendment — `start-research.sh` |
| 3 — Pipeline orchestration | Launcher chat panel freed after dispatch; operator resumes via `/brain-resume <slug>` | This amendment — split slash commands |

#### Slash command split

| Command | Purpose |
|---|---|
| `/brain <task>` | **Launcher only.** Slugifies, registers run, spawns Phase 0, prints instructions, exits. |
| `/brain-resume <slug>` | After RESEARCH.md exists, dispatches Planner → Actor + Reviewer loop → Phase 4 summary. |
| `/brain-status` | List all runs with state, age. |
| `/brain-abandon <slug>` | Mark run abandoned. |

`brain.md` is now a thin launcher (~140 lines). The bulk of orchestration logic lives in
`brain-resume.md`. By design choice: each slash command has a single, clear job; no state
machine spanning turns.

#### Per-run state subdirectories

`.claude/orchestra/runs/<run_id>/{RESEARCH.md, PLAN.md, TASKS.json, review-comments.md,
researcher-prompt.txt, initial-prompt.txt, logs/}` — per-run isolation.

`run_id` format: `<UTC-ts>-<slug>` (e.g. `20260425T193000Z-explore-pros-cons`). Timestamp
prevents collision on duplicate slugs; slug is human-recognisable.

`/duo` continues using the flat `.claude/orchestra/` path — Option II.b applies to `/brain`
only.

#### Run registry

`.claude/orchestra/runs.jsonl` — append-only JSONL. Each line is a state-transition event:

```json
{"event":"start","run_id":"...","slug":"...","task":"...","window":"...","model":"claude-opus-4-7","host":"...","pid":12345,"ts":"..."}
{"event":"research_complete","run_id":"...","ts":"..."}
{"event":"plan_dispatched","run_id":"...","ts":"..."}
{"event":"done","run_id":"...","ts":"..."}
{"event":"abandoned","run_id":"...","reason":"...","ts":"..."}
```

Most-recent event per `run_id` defines current state. States: `start` → `research_complete`
→ `plan_dispatched` → `planning` → `implementing` → `reviewing` → `done`. `abandoned` /
`error` may occur at any point.

CRUD via `scripts/runs-registry.sh {start|transition|latest-state|resolve|field|list|count-active|by-state}`.

#### Disambiguation rules (operator must be precise)

By design choice: **no most-recent-default**. Operator must reference each run explicitly
by slug or unique prefix. Even with a single in-flight run, operator must reference it
explicitly. Avoids ambiguity drift as more runs accumulate.

- Exact slug — works
- Unambiguous prefix — works (e.g. `explore` if only one slug starts with that)
- Ambiguous prefix → registry helper prints candidates, exits non-zero
- No prefix → command refuses with usage hint

#### Status-line multi-run badge

`status-line/orchestra-block.sh` appends `(N)` when more than one run is active:

| Active runs | Badge |
|---|---|
| 0 | `♪ default` |
| 1 | `♪ orchestra` |
| N>1 | `♪ orchestra(N)` |

Active = state not in `{done, abandoned, error}`. Counted from registry by reading
`runs.jsonl` directly.

#### VSCode workflow (v1 stop-gap)

VSCode has no programmable way to spawn a new chat panel. For Phase 0 in VSCode,
`start-research.sh` writes `/tmp/brain-launch-<run_id>.sh`. Operator manually opens a
terminal split (Ctrl+\`) and runs `bash /tmp/brain-launch-<run_id>.sh`. Interactive claude
runs in that terminal — the **model switch IS preserved** (the launcher script invokes
`claude --model claude-opus-4-7`). The friction is the one-time copy-paste.

##### VSCode UX polish (implemented)

1. **`.vscode/tasks.json` integration** ✓ — `.vscode/tasks.json` in orchestra repo root defines a
   "Start Brain Run" task that runs the most recent `/tmp/brain-launch-*.sh`; trigger via
   Ctrl+Shift+P → "Run Task: Start Brain Run".
2. **Clipboard injection** ✓ — `start-research.sh` auto-copies the `bash <script>` command to
   clipboard (via `wl-copy` / `xclip` / `pbcopy` depending on platform, with failure-safe fallback).

#### Concurrent runs

Multiple `/brain` invocations can be in flight simultaneously. Each gets its own `run_id`,
state subdir, spawned window. The launcher chat panel can be used for unrelated work
between invocations.

Bulk abandonment (`abandon all`) requires confirmation showing the count.

Stale runs are NOT auto-cleaned (per user preference: "leave forever, operator should
clean manually"). Registry retains all events.

#### Files added / modified

| File | Status |
|---|---|
| `agents/researcher.md` | New — Phase 0 system prompt |
| `scripts/runs-registry.sh` | New — registry CRUD |
| `scripts/start-research.sh` | New — Phase 0 spawner |
| `commands/brain.md` | Rewritten as launcher only |
| `commands/brain-resume.md` | New — Phases 1-4 orchestrator |
| `commands/brain-status.md` | New — list |
| `commands/brain-abandon.md` | New — abandon |
| `scripts/run-tier.sh` | Modified — accepts `--run-id`, routes state to per-run subdir |
| `status-line/orchestra-block.sh` | Modified — multi-run count suffix |
| `deploy.sh` | Modified — handles new scripts |
| `docs/design.md` | This amendment |

#### Trade-offs accepted

- **Brain in launcher does not retain pipeline state across turns** — each slash command
  is independent. State lives in registry + per-run subdirs.
- **VSCode**: clipboard injection auto-copies the command; `.vscode/tasks.json` provides
  one-keystroke launch via Ctrl+Shift+P → Start Brain Run.
- **`/duo` not migrated** — adding Phase 0 + multi-run isolation would defeat the
  lightweight purpose. Operators wanting research dialogue should use `/brain`.

#### Verification performed

**Mechanical (pre-dogfooding):**
- Unit tests for `runs-registry.sh` (start, transition, list, resolve prefix matching,
  count-active, by-state, field) ✓
- Mechanical smoke test of `start-research.sh` in tmux: registry event, tmux window
  opens, per-run subdir created with substituted system prompt, abandonment transitions
  cleanly, count-active drops to 0 ✓
- All four slash commands visible in skills list after deploy ✓

**End-to-end dogfooding** (run_id `20260425T185840Z-test-the-new-phase-0-spawn-mechanics`,
2026-04-26):

| Phase | Tier / role | Model | Duration | Outcome |
|---|---|---|---|---|
| Phase 0 | Researcher (interactive in tmux window) | Opus 4.7 | manual | Dialogue produced 5.4 KB RESEARCH.md; spawned session correctly self-discovered the status-line bug (spawned windows showing `♪ default` instead of self-identifying) |
| Phase 1 | Planner subprocess | Sonnet 4.6 | 156 s | 9.8 KB / 242-line PLAN.md with verbatim before/after code blocks and step-level scope guards |
| Phase 2 | G2 gate (`ExitPlanMode`) | n/a | < 1 s | Approved |
| Phase 3 (impl) | Actor subprocess | Haiku 4.5 | 74 s | Edited `status-line/orchestra-block.sh` per plan (env-first BRANCH A + registry BRANCH B + 30-char truncation in both). Steps 1-4 done; step 5 manual smoke deferred to operator |
| Phase 3 (review) | Reviewer subprocess | Sonnet 4.6 | 140 s | Verdict **PASS**: source matches spec, syntax check passes, deployed grep finds expected markers, scope honoured |
| Phase 4 | Brain (launcher chat) | Opus 4.7 | < 1 s | Registry transitioned `done`, idle badge restored |

**Dogfooded fix (real bug shipped):** `status-line/orchestra-block.sh` — env-first
detection of `CLAUDE_BRAIN_RUN_ID` for spawned windows; identical 30-char no-ellipsis
truncation in both branches; verified to produce identical output in launcher (registry
path) and spawned (env path) contexts.

**Bug found and patched mid-flight:** the original `agents/researcher.md` did NOT
instruct the spawned session to transition the registry to `research_complete` after
writing `RESEARCH.md`. Without the transition, `/brain-resume` would refuse with state
mismatch. Patched in source (added `runs-registry.sh transition … research_complete`
step after the atomic-rename) and redeployed; future spawned sessions auto-transition.

#### Verification still deferred

- Multi-run concurrency in real use (multiple `/brain` invocations simultaneously) —
  smoke-tested mechanically but not exercised under realistic load
- VSCode manual-launcher path (`bash /tmp/brain-launch-<id>.sh` in a terminal split) —
  the path exists in code; not yet driven through an actual VSCode-only workflow
- A `/brain-resume` round that triggers the FIX-loop (Reviewer returns FIX, not PASS,
  forcing re-dispatch) — first dogfooded run had Reviewer PASS on first pass

#### Status line UX by surface (clarified 2026-04-26)

After the dogfooded fix shipped, here is the canonical map of where the custom
status line appears:

| Surface | Underlying process | Has status line? | Display source |
|---|---|---|---|
| Launcher chat panel | Interactive Claude Code | ✓ | Branch B — registry-driven |
| Phase 0 RESEARCH window (tmux) | Interactive `claude --bare …` | ✓ | Branch A — env-first (`CLAUDE_BRAIN_RUN_ID`) |
| VSCode terminal split running Phase 0 launcher | Interactive `claude --bare …` | ✓ | Branch A |
| Planner / Actor / Reviewer subprocess windows | Headless `claude -p` (no TUI) | ✗ — by design | n/a — stream-json via `format-stream.sh` |

**Why no status line in tier subprocess windows.** `claude -p` is headless: no
TUI, no input prompt, no chat surface. `statusLine.command` is not invoked. What
runs in those tmux windows is the formatter pipeline:
```
claude -p --bare … --output-format stream-json |  format-stream.sh  |  tee → logfile
```
The "promptless tmux window with raw text streamed" observed during dogfooding
is the expected behaviour of A1 (headless + formatter), not a defect.

**Bringing TUI / status line to tier windows** is the deferred A2 path
(interactive `claude` in tmux per tier, with prompt-injection + result-file
handoff). Documented in this design doc under the original A1 vs A2 discussion.
Not in scope for v1.

#### Deploy gotcha — `chmod +x` for status-line.sh patch path (fixed 2026-04-26)

The `deploy.sh` orchestra-block patch path uses `awk` + `mv -f` to re-deploy
the orchestra block into `~/.claude/scripts/status-line.sh`. Both branches
(idempotent re-deploy and initial-append) preserved file content correctly but
did NOT explicitly `chmod +x` after the move. Earlier in-place strip/edit
cycles during this session had dropped the exec bit from the deployed file.
Claude Code's `statusLine.command` invocation (which calls the script directly
without a `bash` prefix) then failed silently with **Permission denied**, and
the entire custom status line vanished from the chat panel.

The bug was masked for over a dozen exchanges because manual smoke-testing
used `bash <path>`, which bypasses the exec-bit requirement. Direct invocation
(`<path>` without `bash` prefix) reproduced the failure immediately.

**Fix:** both `deploy.sh` orchestra-block-patch branches now `chmod +x
"$STATUS_LINE"` after the `mv -f`. Idempotent. Commit `4704def`.

**Lesson:** when patching files that are invoked directly by external tooling
(hooks, status lines, etc.), always re-apply executable permissions after any
write that goes through a tempfile + rename. The other deploy.sh script-copy
path (the `for s in orchestra-hook.sh run-tier.sh …` loop) already does this
via an explicit `chmod +x` after `cp`; the status-line patch path was the
outlier.

---

## v2 TO-DO classification (architecture-aware)

The 2026-04-26 migration to Option A (`claude -p` subprocesses on `main`) makes some
v2 TO-DOs architecture-specific. The Option B (native Agent-tool subagents) work is
preserved on the **`sub-agents`** git branch for fallback or future development.

| TO-DO | Common | Option A (`main`) | Option B (`sub-agents` branch) |
|---|---|---|---|
| Optional FINALIZE doc-review stage | ✓ | applies | applies |
| `auto` mode (existing detailed spec below) | concepts only | implementation needs rewrite¹ | implementation matches the spec |
| Optimization (3): persistent subprocess per tier | | ✓ | n/a (Agent tool reuses session natively) |
| Optimization (4): 1-hour TTL prompt caching | | ✓ | n/a (Agent tool reuses Brain's session cache) |
| Lock sentinel for cross-machine project sessions (§10.3) | ✓ | applies | applies |

¹ The existing `auto` mode spec was written assuming Option B. Under Option A, several
implementation details change:
- `SubagentStop` hook signal → result-file polling (`scripts/run-tier.sh` already implements this)
- Agent-tool error capture → subprocess exit codes + stream-json `result.is_error` field
- Concurrent Actor fan-out → spawn multiple `claude -p` subprocesses (one per branch worktree)
- Crash recovery → subprocess re-spawn vs. Agent-tool retry semantics
- Token-budget tracking → `result.total_cost_usd` per subprocess (already captured in stream-json)

High-level concepts (CROSS-CHECK, branch isolation, test gate, halt-and-resume, checkpoint
commits) remain valid in either architecture; only the plumbing differs.

---

### TO DO — optional FINALIZE doc-review stage (common to both architectures)

We chose the lightweight path (Planner pre-considers + Phase 4 post-checks) over a formal FINALIZE stage. If the lightweight approach proves insufficient, reconsider Option B:

**What Option B would add.** A formal FINALIZE stage between REVIEW and DONE in `/brain`, with Actor automatically dispatched to update docs based on the diff, followed by a *doc-only Reviewer pass* with distinct review style. The v2 `auto` preset's FINALIZE stage already contemplates this; Option B would bring an equivalent stage into `default` / `acceptEdits` presets too.

**Why not in this amendment.** Avoids adding a stage to every `/brain` run (many have no doc impact worth a full stage); keeps doc review in the same style as code review; no new infrastructure. Lightweight path is "good enough" for v1 use.

**When to revisit.**
- If the lightweight check misses doc updates more than ~20% of the time in real use.
- If doc review style needs to differ meaningfully from code review (style guides, terminology audits, link checking, screenshot regeneration, etc.).
- If you want the same strictness around docs that `auto` mode will bring to code.

**What would change if adopted.**
- `brain.md` gets a new Phase 4 body (FINALIZE stage with explicit Actor dispatch + Reviewer pass dedicated to docs).
- A `~/.claude/agents/documentarian.md` subagent file may be added if doc tool set diverges meaningfully from Actor's.
- `~/.claude/orchestra/config.yaml` gets a `finalize.doc_stage: enabled` toggle and a distinct `finalize.review_style: docs` key.
- The TODO design-history doc gets a new resolution note superseding this TO DO entry.

### TO DO — v2 `auto` mode: detailed implementation spec

> **Architecture note (added 2026-04-26):** the spec below was written assuming Option B
> (native Claude Code subagents via Agent tool). Under the post-2026-04-26 Option A
> architecture (`claude -p` subprocesses on `main`), the high-level design (CROSS-CHECK,
> branch isolation, test gate, halt-and-resume, checkpoint commits, dangerous-Bash guard,
> scope check, budget caps) **all still apply**. What changes is the plumbing:
>
> - `SubagentStop` hook signal ↔ result-file polling (see `scripts/run-tier.sh`)
> - "Modified files" list below mostly still applies, but `orchestra-hook.sh` may need
>   fewer modes since hooks no longer track tier lifecycle
> - "Concurrent fan-out" of multiple Actors becomes parallel `claude -p` subprocesses,
>   each with its own tmux window
> - Token-budget tracking: `result.total_cost_usd` field in stream-json `result` event
>   (already captured per-tier — easy to aggregate)
>
> **The `sub-agents` git branch** preserves the Option B implementation; if `auto` mode
> is built on that branch, the spec below applies verbatim. On `main`, treat the spec as
> a design reference and adapt the plumbing details.

Section §10.2 above sketched the `auto` preset as a v2 stub. This entry captures the concrete detailed spec worked out in the 2026-04-24 design session, organised as a decision tracker for when v2 appetite arrives. Build this AFTER answering the ten open decisions below (in roughly the stated order — earlier questions are foundational; later ones are cosmetic or easily changed).

#### Premise

Unattended PLAN → IMPLEMENT → REVIEW requires mechanical substitutes for every point at which a human currently eyeballs the work. Fifteen failure modes identified (Actor hallucination, Reviewer over-approval, FIX loops, scope creep, context overflow, destructive actions, test regressions, bad plans, CROSS-CHECK gaps, budget exhaustion, network glitches, history pollution, concurrent runs, leaked secrets). Each needs an automated guard.

#### Component inventory

**New files (6):**
- `~/.claude/agents/auditor.md` — independent second reviewer (Sonnet 4.6, skeptical prompt)
- `~/.claude/commands/brain-resume.md` — resume from halt file
- `~/.claude/commands/brain-rollback.md` — reset to checkpoint
- `~/.claude/scripts/orchestra-auto.sh` — helper library (branch isolation, checkpoints, test gate, scope/size/cost checks, halt)
- `~/.claude/scripts/orchestra-test-detect.sh` — per-project test-command detection (pytest / pnpm / make / cargo / go)
- `~/.claude/scripts/orchestra-dangerous-bash.sh` — PreToolUse(Bash) deny-pattern guard, active only under `auto`

**Modified files (8):**
- `.claude/commands/brain.md` — major rewrite: auto branch of control flow with branch-iso, step-level commits, test gate, scope check, auditor, CROSS-CHECK, replan trigger, stuck detection, halt/resume
- `.claude/commands/orchestra-mode.md` — remove the `auto` stub; wire full behaviour (Axis X flip to `bypassPermissions` + state.env writes + prerequisite checks)
- `.claude/agents/planner.md` — in auto mode, plan must include file allowlist + exact test command
- `.claude/agents/actor.md` — scope-lock reminder; diff-summary in return; no-commit reinforced
- `.claude/agents/reviewer.md` — rubric-based Y/N verdict alongside prose; mechanical derivation; Auditor cross-reference
- `orchestra/config.yaml` — activate all v2 keys (currently stubs)
- `settings.json` — add second `PreToolUse(Bash)` entry for dangerous-bash guard
- `scripts/orchestra-hook.sh` — invocation_id correlation, token-cost accumulator, stuck-detection signal
- `scripts/status-line.sh` — auto-mode progress fields (step N/M, iter K, running cost, branch)

#### Ten decisions needed before building (ordered by implementation dependency)

Each decision listed with: when it arises, default leaning, trade-off.

**1. Lock sentinel semantics** — *foundational; needed before any auto code is written*
- When: before first auto run can safely execute on an NFS-shared project.
- Default lean: use `mkdir` (atomic on POSIX+NFS) as the lock primitive at `.claude/orchestra/.auto.lock/`; TTL 90 min (longer than wall-clock timeout).
- Trade-off: too short and a slow auto run self-evicts; too long and a crashed run blocks the next one.

**2. Dangerous-Bash deny patterns** — *needed for the hook script*
- When: before `orchestra-dangerous-bash.sh` is written.
- Default lean: conservative list including `rm -rf /`, `dd … /dev/*`, `mkfs.*`, `chown -R … /`, `curl … | sh`, `git push --force`, `git push … main|master`, `npm/pnpm/cargo publish`.
- Trade-off: under-include and real destructive actions slip through; over-include and legitimate operations get blocked (kubectl, systemctl). Extension via `config.yaml → dangerous_bash.extra_patterns`.

**3. Auditor always-on or toggleable** — *needed before `auditor.md` is written*
- When: defines whether the subagent even exists as a hard dependency.
- Default lean: always-on; togglable via `--no-auditor` at invocation.
- Trade-off: always-on means ~40% higher subagent cost per step; toggleable adds one more config surface and risks the user disabling the safety rail.

**4. Reviewer rubric granularity** — *needed before `reviewer.md` rewrite*
- When: defines the quality bar.
- Default lean: 7-item Y/N rubric (compile, tests pass, scope respected, no new TODOs, no obvious security issues, diff size reasonable, no regression vs baseline). Any N → FIX or BLOCK; all Y → PASS.
- Trade-off: looser rubric means more PASSes on marginal work; stricter rubric means thrashing.

**5. Scope-lock enforcement — halt or warn** — *needed before `/brain.md` auto-branch rewrite*
- When: defines Brain's reaction when Actor edits outside the plan's allowlist.
- Default lean: halt, treat as plan bug (trigger replan).
- Trade-off: halt is safer but costs more runs; warn allows Actor to hop scope when the plan was incomplete.

**6. Option B revisit under auto** — *needed before `/brain.md` auto FINALIZE design*
- When: interacts with the Phase 4 doc-update amendment already in v1.
- Default lean: keep per-step doc-delta checks under auto (consistent with v1 Phase 4) rather than resurrecting Option B's dedicated FINALIZE doc stage.
- Trade-off: consistency with v1 vs. dedicated doc-review pass that might catch more. Option B becomes more attractive under auto because there's no human to catch doc misses.

**7. Replan cap** — *config default*
- When: at config-drafting time.
- Default lean: 2 replans per `/brain` invocation.
- Trade-off: more replans recover from bad initial plans; fewer replans halt sooner on structurally wrong plans.

**8. Token budget default** — *config default*
- When: at config-drafting time.
- Default lean: 5M tokens total subagent cost (≈ $15 at mixed tier pricing).
- Trade-off: too low and runs halt mid-flight; too high and unattended runs can quietly rack up cost.

**9. Halt-file retention** — *config default + cleanup automation*
- When: at config-drafting time.
- Default lean: keep `auto-halt-<ts>.md` files 30 days; PreCompact hook (or a dedicated cron) prunes older ones.
- Trade-off: forever is safe but accumulates; too short and `/brain-resume` fails on last-week's halts.

**10. Status-line format under auto** — *cosmetic; last*
- When: final polish.
- Default lean: compact form `♪ auto N/M·i2·$Xk·br:auto-…` to keep the line from wrapping.
- Trade-off: compact is cramped but fits; verbose is readable but pushes other fields off-screen on narrow terminals.

#### Invariants the implementation MUST preserve

Regardless of how decisions 1–10 resolve, these are non-negotiable for auto mode:

- Every successful step ends in exactly one checkpoint commit.
- Every halt writes a resumable halt file.
- Every subagent invocation has a unique invocation_id logged.
- Every Actor edit is inside the plan's file allowlist, or the run halts.
- Every test gate runs; red stops.
- Both Reviewer AND Auditor must PASS for a step to be accepted.
- **No push. No PR. No publish.** Ever — not even in `auto`.
- No work on a protected branch — isolation is a precondition.
- Cost and wall-clock caps are hard halts.
- Lock sentinel prevents concurrent auto runs per project.

#### Non-goals

- Not a reliability proof — reduces failure probability, doesn't eliminate it.
- Not a substitute for CI — the isolated branch still needs human review before merge to main.
- Not secure against adversarial code generation; dangerous-Bash guard is pattern-based.
- Not automatic merging to main — FINALIZE stops at the isolated branch.
- Not cross-machine — lock sentinel enforces single-machine-per-project.

#### Estimated effort

~800 lines of bash + ~400 lines of prompt text across 6 new files and 8 modified files. Focused work: 4–6 hours optimistic, 6–10 hours realistic with debug cycles.

#### Trigger for revisiting

Build v2 `auto` when:
- You have at least 5 successful `/brain` runs under v1 (to understand real-world failure patterns before designing automation for them).
- You have a specific unattended-run use case in mind (e.g., overnight RAG regression sweeps, multi-project benchmark fan-out) — unattended runs need concrete problems to solve.
- You're comfortable with the wallet exposure implied by default `token_budget: 5M` (configurable lower).

Until then, v1 `default` + `acceptEdits` presets cover all interactive flows — the thing v2 adds is specifically unattended-ness, which isn't yet a pressing need.

---

## Amendment — 2026-04-28: revert headless detour, return to canonical subagents

**This amendment supersedes earlier amendments dated 2026-04-26 onwards** (the Option A migration, the Phase 0 separate-session, the multi-run registry). Those amendments described an experiment that was rolled back. The original §§1–13 description of subagent architecture is again authoritative.

### Why the revert

Five pieces of evidence accumulated between 2026-04-26 and 2026-04-28 made the headless approach untenable:

1. **The capability rationale was wrong.** The 2026-04-26 migration was justified by a belief that subagents could not carry per-agent model + permission settings. They can. The Anthropic Claude Code Subagents guide (Apr 2026) and the operator's own empirical test confirm that subagent YAML frontmatter supports `model`, `permissionMode`, `tools`, `disallowedTools`, `effort`, `maxTurns`, `isolation`, and `memory`. The only documented caveat is that a parent's `--dangerously-skip-permissions` flattens children — which is a constraint we already had to design around in any architecture.

2. **The cost story was inverted.** The "headless = cheaper because per-tier model routing" intuition is false in practice. Each `claude -p` cold-starts a new process and defeats the parent session's prompt cache. The PDF guide reports that ~90% of subagent token cost in long sessions is cache reads at ~$0.50/MTok on Opus-equivalent — **subagents within a warm parent are plausibly cheaper than headless subprocesses**, despite the nominal 4–7× multiplier looking scarier on paper.

3. **The complexity tax was real.** The headless approach added ~890 lines of bash plumbing (`start-research.sh`, `runs-registry.sh`, `run-tier.sh`, `format-stream.sh`, status-line tracking, multi-run state machine) and a separate VSCode tasks.json launcher integration. Subagents need none of it.

4. **Two of the four claimed benefits were illusory or anti-goals.** The headless approach was supposed to deliver: (a) live visibility into substream work, (b) cross-day resumability, (c) parallel runs in one operator session, (d) independent permission contexts. The operator disavowed (a) and (b) explicitly ("I want WHAT not WHY", "/brain-resume is overkill"); (c) is replaced by "open another `claude` session"; (d) is provided by subagents already.

5. **`/orchestra-mode` was forgotten.** When the operator was asked which commands to keep, they did not remember `/orchestra-mode` existed. That is sufficient evidence it was not earning its slot. Deleted alongside the rest.

### What the new architecture looks like

```
operator's main claude session
    │
    └── Brain (Sonnet 4.6 minimum, Opus 4.7 recommended for /brain)
            │
            ├── Phase 0 RESEARCH ← inline (Brain interrogates the operator)
            │   posture absorbed from old researcher.md system prompt
            │   parent must be in plan mode
            │
            ├── Phase 1 PLAN
            │   └── Task(subagent_type: planner)  ── Sonnet 4.6, read-only
            │       returns plan text; Brain persists PLAN.md
            │       operator approves plan
            │       Brain calls ExitPlanMode → standard CC "auto-edit/manual/cancel" prompt
            │
            ├── Phase 2 EXECUTE  (one or more invocations)
            │   └── Task(subagent_type: actor)    ── Haiku 4.5, read+write
            │       executes one or more steps; self-persists TASKS.json
            │       returns diff summary + ready_for_review|blocked|partial
            │
            └── Phase 3 REVIEW
                └── Task(subagent_type: reviewer) ── Sonnet 4.6, read-only
                    returns PASS|FIX|BLOCK + minimal-fix list
                    Brain persists review-comments.md
```

`/duo` is the same shape minus Phase 0 and Phase 3:

```
operator's main claude session (Sonnet 4.6)
    │
    └── interactive plan with operator
            ├── ExitPlanMode after plan approval
            └── Task(subagent_type: actor) ── Haiku 4.5
```

### What the new architecture explicitly does NOT do

- No `claude -p` subprocesses.
- No tmux windows opened by the orchestra.
- No multi-run registry (`runs.jsonl`) or per-run subdirs under `runs/<run_id>/`.
- No `/brain-resume`, `/brain-abandon`, `/brain-status`, `/orchestra-mode` slash commands.
- No live tool-call streaming feed (subagents are opaque-by-design; PreToolUse(Edit/Write/Bash) hook removed).
- No state.env `ORCHESTRA_MODE` badge tracking.
- No CLAUDE_BRAIN_RUN_ID env propagation.
- No status-line "active runs count" or "spawned-window slug" displays.

### Permission flow (Plan-Then-Execute)

The canonical Claude Code pattern:

1. Operator launches `claude` in normal mode (not `--dangerously-skip-permissions`).
2. Operator enters plan mode (Shift+Tab) before typing `/brain` or `/duo`.
3. Brain runs Phase 0 (in `/brain`) or Phase 1 (in `/duo`) under plan mode — read-only by parent constraint.
4. Subagent dispatch during these phases is also read-only (Planner is read-only by frontmatter; the parent's plan mode would constrain even a write-capable subagent).
5. Operator approves the plan.
6. Brain calls `ExitPlanMode` with the plan content.
7. Claude Code displays the standard "Yes, and auto-edit / Yes, manually approve edits / Cancel" prompt at the parent.
8. Operator's choice sets the permission posture for Phase 2.
9. Brain dispatches Actor, whose tool calls fire under whatever permission posture the operator just chose.

**Bypass-flattens-down caveat (documented prominently):** If the operator launches the parent with `--dangerously-skip-permissions`, all subagent `permissionMode` frontmatter is silently overridden. Read-only Planners and Reviewers can still write files. The permission architecture is a useful invariant only when the operator does *not* bypass at the parent.

Subagent `permissionMode` frontmatter is used to **narrow** (e.g., Planner read-only by tool list), never to **widen**. Children cannot escalate above parent.

### Per-session subdirectory + 30-day cleanup

Each `/brain` or `/duo` invocation:

1. Reads `housekeeping.session_retention_days` from config (project override > global default > hardcoded 30).
2. Lazily cleans up any `.claude/orchestra/sessions/<id>/` subdirs older than that retention window via `find -mtime +N -exec rm -rf`.
3. Creates a fresh per-invocation subdir `<UTC-timestamp>-<PID>/` for its `RESEARCH.md`, `PLAN.md`, `TASKS.json`, `review-comments.md`.
4. Exports `CLAUDE_ORCHESTRA_SESSION_DIR` so the spawned subagents read/write artifacts under the same root.

There is no canonical `CLAUDE_SESSION_ID` env var in Claude Code 2.1.121; PID-based identifiers are stable enough for the practical use case.

### Persistence ownership

| Artifact | Written by | Read by |
|---|---|---|
| `RESEARCH.md` | **Brain** (after operator agrees Phase 0 is done) | Planner (as input prompt context) |
| `PLAN.md` | **Brain** (after Planner returns plan text) | Actor; operator review |
| `TASKS.json` | **Actor** (frequent intra-step updates; atomic-rename) | Brain; Reviewer; operator |
| `review-comments.md` | **Brain** (after Reviewer returns review text) | operator review |

Planner and Reviewer are purely read-only (`tools` lists exclude `Write` and `Edit`). The earlier "exception clause" in their `.md` bodies that granted them Write/Bash for atomic-rename was inconsistent with the actual frontmatter allowlist and could not work — Brain owning persistence resolves that.

### Hook script behaviour

`scripts/orchestra-hook.sh` is reduced to three modes (was four):

- `start` (PreToolUse on Agent matcher): record subagent invocation; create per-stage logfile under `.claude/orchestra/logs/`; append event to `.claude/orchestra/invocations.log`.
- `end` (SubagentStop): mark logfile as done; append completion event to invocations.log.
- `compact` (PreCompact): write `.claude/orchestra/brain-state.md` snapshot listing the most recent session subdir's artifacts. Audit-only — there is no `/brain-resume` to consume it.

Removed: `tool` mode (PreToolUse on Edit/Write/Bash matchers) and all tmux operations.

### Status-line behaviour

`status-line/orchestra-block.sh` reduced to ~50 lines:

- `♪ orchestra` — static badge when this project has the orchestra installed.
- `▶ Sonnet:plan` / `▶ Haiku:implement` / `▶ Sonnet:review` — active subagent indicator (reads `invocations.log`).
- `⚠ >200K` — warning when Brain context exceeds 180K (subagent-overflow risk).

Removed: BRANCH A (CLAUDE_BRAIN_RUN_ID env-driven slug display), BRANCH B (state.env mode badge + runs.jsonl active-count tracking).

### Deferred features (with trigger conditions)

Documented as not-in-scope for v1 but cleanly addable when the trigger fires:

| Feature | Trigger to revisit |
|---|---|
| `memory:` field on subagents (per-agent persistent MEMORY.md) | When telemetry shows Brain re-injecting the same context block in ≥50% of invocations of a given subagent |
| `Explorer` subagent for parallel codebase investigation (PDF p.10 domain-routing pattern) | When Brain's own Read/Grep/Glob proves insufficient on real workloads — likely never |
| `/brain --mode auto` (overnight unattended run with test gate, branch isolation, CROSS-CHECK loop) | The original v2 plan; trigger documented in the "auto preset" section above |
| `/brain-resume` style cross-day continuation | Currently disavowed; revisit if multi-day work patterns emerge |
| Cleanup of stale remote branches (`origin/headless-claude`, `origin/sub-agents` hyphenated, `origin/headless-caude` typo) | After this revert is merged to main |

### Files deleted in the revert

```
agents/researcher.md             (159 lines)
commands/brain-abandon.md         (47 lines)
commands/brain-resume.md         (127 lines)
commands/brain-status.md          (31 lines)
commands/orchestra-mode.md
scripts/start-research.sh        (199 lines)
scripts/runs-registry.sh         (146 lines)
scripts/run-tier.sh              (192 lines)
scripts/format-stream.sh         (194 lines)
.vscode/tasks.json
+ ~106 lines from scripts/orchestra-hook.sh
+ ~70 lines from status-line/orchestra-block.sh
+ deploy.sh: ~30 lines (stripped/ generation, multi-script for-loop)
+ config/config.yaml: tmux block
+ config/settings-hooks.json: Edit/Write/Bash matchers
```

Total: ~1100 lines removed; ~150 lines added (new minimal hook script body, new per-session preamble, new orphan-cleanup logic in deploy.sh).

### Implementation history (commit chain on the `subagents` branch)

```
b606508  chore: delete researcher agent + headless scripts; clean orphans on deploy
4474a2b  chore: delete obsolete /brain-{resume,abandon,status} + /orchestra-mode
bbb69d9  feat(orchestra): per-session subdirs + 30d lazy cleanup
e300329  refactor(agents): per-session paths; clarify persistence ownership
ebb3f88  feat(duo): dispatch Actor as Haiku subagent; remove headless run-tier path
eaa535c  feat(brain): inline Phase 0, dispatch Planner/Actor/Reviewer as subagents
c1947ef  refactor(hooks): trim orchestra-hook.sh of headless dispatch
a4a7dc0  chore: trim status-line + drop .vscode/tasks.json
```

(Plus this docs commit and the research-note preservation commit.)

### Open question deferred to operator

The `subagents` branch is local-only at the time of this writing. Whether it eventually merges to `main`, replaces `main`, or remains a parallel "canonical" track is an operator decision — out of scope for the revert work itself.

