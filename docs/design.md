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

A three-tier orchestration layer over Claude Code: **Brain (Opus 4.7)** / **Planner (Sonnet 4.6)** / **Actor (Haiku 4.5)** / **Reviewer (Sonnet 4.6)**, using Claude Code's native subagent primitive. Tmux windows for live visibility in terminal; logfile-only in VSCode. Designed to be installed once at `~/.claude/` and usable from any project on any machine that mounts the NFS home.

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
| Subagent about to start | `PreToolUse` (matcher: `Agent`) | Spawn tmux window (if `$TMUX`); append prompt line to `invocations.log` |
| Subagent ended | **`SubagentStop`** | Mark window `✓`; schedule 120 s `kill-window`; append result line to `invocations.log` |
| Before context compaction | `PreCompact` | Save Brain state to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/brain-state.md` |

`SubagentStop` is deliberately used instead of `PostToolUse(Agent)` — it's Claude Code's purpose-built hook for the subagent-ended event and is more future-proof.

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
| Plain terminal inside tmux session | ✅ | Spawn window named `<stage>` / `<stage>_N`, tail its logfile | Mark window `✓`, schedule 120 s `kill-window`, append to logs |
| VSCode Claude Code extension panel | ❌ | No window spawned; append prompt line to `invocations.log` | Append result line to `invocations.log` |
| VSCode integrated terminal (no inner tmux) | ❌ | Same as VSCode extension panel | Same |
| Plain terminal without tmux | ❌ | Same as VSCode extension panel | Same |

### 5.3 Gaps and workarounds

**Gap 1 — No live per-stage window in VSCode.**
In tmux you see a dedicated window per active subagent. In VSCode the equivalent information only accumulates in `invocations.log`.

- *Workaround*: open a terminal split inside VSCode and run
  ```bash
  tail -f ${CLAUDE_PROJECT_DIR}/.claude/orchestra/invocations.log | jq .
  ```
  for a live feed while Brain works in the extension panel. Not automatic — a manual one-time setup per project-session.

**Gap 2 — Per-stage logs are separate files, not tailed by default in VSCode.**
Each subagent invocation writes its own `<stage>-<UTC-ts>-<HOSTNAME>-<PID>.log` file with prompt + result. In tmux these are tailed in the spawned window automatically; in VSCode you must manually open them after the fact, or tail the aggregated `invocations.log`.

- *Workaround*: VSCode task `Terminal → Run Task → Tail orchestra` that runs `tail -f <latest stage log>`. Not built; manual if needed.

**Gap 3 — Nested subagent tool calls are invisible in both environments.**
By design (bracketed visibility chosen in §6f of the TODO). If you want to see what the Actor is editing *while* it edits, you currently cannot — only the prompt going in and the result coming out.

- *Workaround*: none in v1. Would require verifying whether hooks fire for nested tool calls and instrumenting them. Deferred unless a real need appears.

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
        └── <stage>-<UTC-ts>-<HOST>-<PID>.log     # per-invocation stage logs
```

`.claude/orchestra/` is globally gitignored via `~/.gitignore_global` (configured
2026-04-25) — no per-project `.gitignore` entry needed.

## 9. Locked decisions

All v1 decisions as of 2026-04-24:

| # | Item | Decision |
|---|---|---|
| Architecture | Option A/B/C | **Option B** — native sub-agents in one Brain session |
| Scope | Global vs project-scoped | **Global** at `~/.claude/` |
| Visibility | Tmux vs logfile only | **Conditional** — `$TMUX`-detecting hook script |
| Window vs pane | — | **Window**, not pane |
| Window naming | — | **Stage names** (`plan`, `implement`, `review`, …); underscore counter suffix (`_1`, `_2`, …); dashes for multi-word stages (`cross-check`) |
| Window termination | — | **Auto-close 120 s** after `SubagentStop` |
| Granularity | — | **Bracketed** (prompt-in / result-out); no nested-tool-call visibility |
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
| `~/.claude/settings.json` | modified | Appended hook entries: `PreToolUse(matcher: Agent)` → `orchestra-hook.sh start`; `SubagentStop` → `orchestra-hook.sh end`; `PreCompact` → `orchestra-hook.sh compact`. Existing `PreToolUse(Bash)` → `venv-enforce.sh` preserved untouched. All other settings (env vars, permissions, statusLine, additionalDirectories) unchanged. |

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

### Amendment — 2026-04-25 (follow-up session): repo restructure + per-project deploy

**1. Repo restructured to mirror `~/.claude/` layout (Option B).**
`agents/` and `commands/` moved into `.claude/` inside the repo so that:
- The repo layout is a direct mirror of the deployment target (`repo/.claude/` → `~/.claude/`).
- Claude Code automatically picks up dev versions when launched inside the repo (project-level `.claude/agents/` and `.claude/commands/` take precedence over user-level `~/.claude/`). No deploy step needed to test agent/command changes while working in the repo.
- `deploy.sh` and `collect.sh` paths updated accordingly.

**2. `deploy.sh` now requires an explicit target argument.**
```bash
./deploy.sh --global          # deploy to ~/.claude/ (system-wide)
./deploy.sh --local           # deploy to $PWD/.claude/ (current project only)
```
`--global` and `--local` are mutually exclusive and required. `--dry-run` and `--diff` remain additive. `--local` skips settings.json hooks merge, status-line patch, and gitignore setup (global-only infrastructure). This eliminates silent global deployments and supports isolated per-project testing.

**3. Development (dogfooding) workflow — three-level promote model.**
```
repo/.claude/agents|commands (edit here)
  └─ ./deploy.sh --local   → self-check + local config only
  └─ ./deploy.sh --global  → promote to ~/.claude/ (all projects, all machines)
```
- **Level 1 (no deploy)**: just launch Claude Code from inside the repo — dev agents/commands are live immediately via project-level discovery.
- **Level 2 (`--local` from repo root)**: self-check (agents/commands show "unchanged"), writes local hook copy and config. Note: the hook copied to `.claude/scripts/` is **not invoked** — the global `settings.json` references `~/.claude/scripts/orchestra-hook.sh` by absolute path. Hook changes require `--global`.
- **Level 3 (`--global`)**: promotes committed changes to `~/.claude/` for all projects and machines.

### TO DO / reconsider later — Option B: dedicated FINALIZE stage

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
