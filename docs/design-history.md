---
title: "Claude Code three-tier orchestrator (Brain/Planner/Actor) — design notes & open questions"
date: 2026-04-24
created_by: Claude Code (Claude Opus 4.7, 1M context)
updated_by: Claude Code (Claude Opus 4.7, 1M context)
updated_on: 2026-04-24
context: >
  Working session exploring how to build a three-layer Brain/Planner/Actor
  orchestrator on top of Claude Code, originally motivated by the Cline VSCode
  plugin's Plan/Act dual-model workflow. Sources consulted in this session:
  (1) Gemini share https://gemini.google.com/share/c9b60b1a3c79 — blocked by
  Google consent redirect on direct fetch, later read from a local copy at
  /var/tmp/gemini-chat.md; (2) the "Longform Guide" at
  https://github.com/affaan-m/everything-claude-code/blob/main/the-longform-guide.md;
  (3) the local Claude Code usage report at
  /mnt/nfs/Florian/Gin-AI/.claude/usage-data/report.html; (4) HomeAI repo
  context (CLAUDE.md, memory/ directory, source tree).
  User's literal ask was a dedicated tmux session with three windows running
  Opus 4.7 / Sonnet 4.6 / Haiku 4.5 in parallel. Three architectural options
  (A: tmux pipeline, B: native sub-agents, C: hybrid tmux + Agent SDK) were
  proposed and the user chose to pursue Option B further. This document
  captures the state of the design before any implementation starts, and
  lists the open questions that must be answered first.
---

# Claude Code three-tier orchestrator — TODO

## 1. The ask, in one line

Build a Brain (Opus 4.7) / Planner (Sonnet 4.6) / Actor (Haiku 4.5) pattern on
top of Claude Code, inspired by Cline's Plan/Act but with three tiers instead of
two, and with enough visibility that the user can inspect each tier as it works.

## 2. Sources reviewed

| Source | Location | Key takeaways |
|---|---|---|
| Longform guide | GitHub `affaan-m/everything-claude-code` | Sequential Phase Architecture (RESEARCH → PLAN → IMPLEMENT → REVIEW → VERIFY); single input/output per agent; `/clear` between stages; model-tier assignments match the Brain/Planner/Actor ask almost verbatim; git worktrees for parallelism; "minimum viable parallelization". |
| Usage report | `/mnt/nfs/Florian/Gin-AI/.claude/usage-data/report.html` | 680 messages / 72 sessions / 2026-03-25 → 2026-04-24, 30.9 msgs/day. Report itself flags "parallel multi-agent benchmark sweeps with a coordinator aggregating a decision matrix" as an ambitious pattern to try — direct motivation for this work. |
| Gemini discussion | `/var/tmp/gemini-chat.md` (191 lines) | Confirms `.claude/agents/*.md` with `model:` frontmatter is the real Claude Code primitive. Also hallucinates several features that do NOT exist — see §4 below. |

## 3. The three options considered

### Option A — Tmux pipeline (literal reading of the ask)
Three live interactive `claude --model …` sessions in three tmux windows; NFS
mailbox directory for handoff; watcher script (`inotifywait` or polling) reads
one agent's outbox and injects the next prompt into the next window via
`tmux send-keys`.
- **Pros**: matches the literal ask; each tier has its own full 1M-token
  context window; theatrical visibility of all three agents working.
- **Cons**: three concurrent API bills (Opus ~15× Haiku); handoff friction;
  "parallelism" is visual only unless Planner fans out to several Actors.

### Option B — Native sub-agents, one Claude session  ← **CHOSEN**
Single Opus 4.7 session = Brain. Planner and Actor defined as custom agents
under `.claude/agents/` with `model:` frontmatter. Brain invokes them via the
Agent tool. Parallel fan-out comes free (multiple Agent tool-uses in one
message run concurrently).
- **Pros**: dramatically simpler; already supported natively; cheapest;
  subagent-tool access can be restricted per-tier; Brain orchestrates without
  extra plumbing.
- **Cons**: no "three windows lit up" visual by default — agent output arrives
  inline as tool results. Mitigation: hook-to-logfile + optional tmux tail pane
  for inspection (see §5).

### Option C — Tmux + Claude Agent SDK (hybrid)
Interactive Brain in one window; a Python orchestrator (Agent SDK) fans out
headless Sonnet Planner + N headless Haiku Actors into sibling windows.
- **Pros**: true parallel Actors; clean programmatic code path; visible in tmux.
- **Cons**: upfront plumbing; overkill unless Actor fan-out is routine.

**Decision**: pursue Option B. Options A and C deferred; A may be revisited
later as a showcase/demo.

### 3.1 Option B refined further — "conditional visibility" (2026-04-24 update)

Two new desirables added:

1. Planner and Actor should appear in their own tmux windows, spawned and
   terminated automatically.
2. The whole setup must be interchangeable between terminal (tmux) and the
   VSCode Claude Code extension.

Reality check: Option B subagents are *in-process* Agent-tool invocations from
Brain's single session. There is no separate Claude process per tier for a tmux
window to attach to. Therefore the tmux windows act as **viewers**, not
separate agents:

- PreToolUse(Agent) hook spawns a stage-named window (see §6f for naming spec),
  tailing that stage's logfile.
- SubagentStop hook writes the result, marks the window `✓ done`, triggers
  auto-close after the grace period (120 s).

**Decided in this update**:
- Visibility granularity: **bracketed** (prompt-in / result-out). Nested
  subagent tool-call visibility is NOT required; the must-verify item about
  whether hooks fire for nested tool calls is therefore **moot and can be
  skipped**.
- Window termination policy: **auto-close 120 seconds after PostToolUse**.
- NFS / cross-machine concurrency protection: **hostname + PID stamping
  only**. Every log line and per-invocation logfile name carries
  `${HOSTNAME}:${PID}:${CLAUDE_SESSION_ID}:${TIMESTAMP}`. No lock sentinel.
  Rationale: user confirmed Claude Code normally runs on one machine at a
  time per project, so the silent-clobber risk that a lock would address is
  negligible, and stamping is crash-safe by construction (nothing to clean
  up on hook crash). If clobbers ever show up in practice, a lock sentinel
  can be layered on top additively — no rework.
- State-file crash safety (orthogonal): Planner/Actor write `PLAN.md` and
  `TASKS.json` using the atomic-rename pattern (write `.tmp`, fsync,
  `rename` to target). `rename` is atomic on POSIX + NFS. Codified in the
  Planner/Actor system prompts and enforceable via a PreToolUse guard on
  `Write` that rejects direct writes when a sibling `.tmp` exists.

**Portability mechanism**: one hook script with env detection —

```
$TMUX set?
  yes  → spawn / update / close per-tier tmux windows
  no   → append to .claude/orchestra/invocations.log
         (covers VSCode extension panel, VSCode integrated terminal, plain shell)
```

Same `.claude/agents/*.md`, same `.claude/settings.json` hook entries; only the
visibility skin changes with environment.

**Hook types** (canonical-aligned per §6c):
- `PreToolUse` (matcher: `Agent`) — spawn window, append prompt line to log.
- `SubagentStop` — finalize window, schedule 120 s auto-close, append result
  line to log. Canonical primitive for the "subagent ended" moment.

## 4. Gemini discussion — what is real vs hallucinated

This matters because Gemini's second half of the transcript confidently invents
Claude Code features that do not exist. Planning around them would waste time.

### Real (confirmed against Claude Code docs, tool surface, and settings schema)
- `.claude/agents/*.md` subagent files with `name`, `description`, `model`,
  `tools` frontmatter. Invoked via `/agents` or programmatically via the Agent
  tool.
- Subagent context is isolated from the parent; return value goes back to the
  parent as a single result message.
- `claude --model sonnet` / `claude --model haiku` launches separate
  interactive Claude Code processes with the given model.
- The "Cascade" method (multiple independent `claude` sessions in separate tmux
  windows/panes, each with its own 1M context) is a valid manual pattern.
- Handover via a shared status file (e.g. `PLAN.md`, `TASKS.json`) is a valid
  pattern, just not a built-in.

### Hallucinated (do NOT plan around these)
- "Agent Teams" feature.
- `teammateMode` setting / `CLAUDE_CODE_TEAMMATE_MODE=tmux` env var.
- Automatic tmux pane spawning per spawned teammate.
- "SessionStart hook that moves a subagent pane to a new window" (based on the
  above fictions; no pane exists to break out — subagents do not run in a
  separate tmux pane).
- "PrimeLine tools" / a bundled `spawn-worker.sh` ecosystem script.
- `CLAUDE_CODE_SUBAGENT_MODEL` global-default env var for subagents (not in
  the settings schema; the documented override is the `model:` field in agent
  frontmatter and the `model` param on the Agent tool). To verify before any
  reliance.

## 5. Option B — refined design (what would actually be built)

```
Brain  (current Opus 4.7 session, main transcript)
  │
  ├─ Agent(subagent_type="planner", model="sonnet-4-6", prompt=…)
  │     ↑ defined by .claude/agents/planner.md
  │     · tools: Read, Grep, Glob, WebFetch, TodoWrite  (read-only, proposed)
  │     · role: decompose Brain's intent into a numbered plan
  │     · optional side-effect: write .claude/orchestra/PLAN.md
  │
  └─ Agent(subagent_type="actor",  model="haiku-4-5",  prompt=…)
        ↑ defined by .claude/agents/actor.md
        · tools: Read, Edit, Write, Bash, Grep, Glob  (write + exec, proposed)
        · role: execute a specific, scoped step from the plan
        · can be invoked N in parallel by Brain for independent steps
```

### Inspection / visibility (replaces the "tmux windows" part of the ask)

1. **PreToolUse hook on `Agent`** in `.claude/settings.json` writes a JSON line
   per invocation (timestamp, subagent, model, prompt preview, result size) to
   `.claude/orchestra/invocations.log`.
2. **Optional tmux companion pane** runs
   `tail -f .claude/orchestra/invocations.log | jq .` so the user sees agents
   firing live without giving up the single-session cost/simplicity story.
3. Output of each subagent is also visible inline in Brain's transcript as an
   Agent-tool result, so "what did the Actor do" is answerable in-band.

### Persistence / resumability across `/clear`

Optional shared state under `.claude/orchestra/`:
- `PLAN.md` — Planner's latest output, rewritten on each plan cycle.
- `TASKS.json` — structured checklist mirroring the plan; Actor updates status.
- `invocations.log` — append-only log from the hook above.

## 6. Open questions — MUST be answered before implementing

1. **Tool boundaries**
   Planner strictly read-only (`Read`, `Grep`, `Glob`, `WebFetch`, `TodoWrite`)
   and Actor write/exec (`Read`, `Edit`, `Write`, `Bash`, `Grep`, `Glob`)?
   Or looser? Any tools to explicitly deny (e.g. deny Bash with `rm -rf` for
   Actor via a PreToolUse guard)?

2. **Handover channel**
   Planner returns text to Brain in-message only, or ALSO writes
   `.claude/orchestra/PLAN.md`? (File makes the pipeline resumable across
   `/clear` and context compaction; pure in-message is simpler but fragile.)

3. **Invocation style** — ✅ RESOLVED (2026-04-24 per §6c edit #3)
   `/brain` slash command ONLY, and only as a **heavyweight opt-in** verb
   for tasks that benefit from the full pipeline. No `/plan`, `/act`, or
   `/review` stage commands in v1. For regular work, user talks to Brain
   normally and Brain decides whether to delegate via the Agent tool — this
   is the canonical Claude Code pattern; forced pipeline ordering is
   community convention, not canon.

4. **Inspection mechanism** — ✅ RESOLVED (2026-04-24)
   Hook-to-logfile + per-tier tmux windows via PreToolUse/PostToolUse hook
   with `$TMUX` env detection. Bracketed visibility only (prompt-in /
   result-out). Auto-close 120 seconds after the subagent returns.
   Companion `claude --model …` processes are NOT used.

5. **Working directory / scope** — ✅ RESOLVED (2026-04-24)
   **Global at `~/.claude/`.** Install once, available in every project.
   Runtime/per-project state goes under the current project at
   `${CLAUDE_PROJECT_DIR:-$PWD}/.claude/orchestra/` (auto-created by the hook
   on first invocation) so PLAN.md, TASKS.json, and per-invocation logs stay
   scoped to the project being worked on.

   Split of concerns:
   - Global infrastructure at `~/.claude/`:
     - `~/.claude/agents/planner.md`
     - `~/.claude/agents/actor.md`
     - `~/.claude/settings.json` — hook entries for `Agent` tool
     - `~/.claude/scripts/orchestra-hook.sh` — the hook script itself
     - `~/.claude/commands/brain.md`, `plan.md`, `act.md` — slash commands
       (pending resolution of open item 3)
   - Per-project runtime at `${CLAUDE_PROJECT_DIR}/.claude/orchestra/`:
     - `PLAN.md`, `TASKS.json`
     - `invocations.log`
     - `planner-<N>.log`, `actor-<N>.log`
     - Should be added to each project's `.gitignore`.

   Implication: hooks will fire on **every** project where Claude Code is
   launched. That is by design given the "global" choice. The hook should
   still work sensibly in projects that never opt in — on those, it simply
   writes to the project's `.claude/orchestra/invocations.log` (auto-created)
   and that is it.

6. **Model-name pinning**
   Pin `model: claude-sonnet-4-5` and `model: claude-haiku-4-5-20251001` in
   frontmatter, or use short aliases (`sonnet`, `haiku`) that track whatever
   the CLI resolves at runtime? (Pinning is reproducible; aliases auto-upgrade.)

7. **Cost posture for Brain**
   Brain always Opus 4.7, or Brain starts Sonnet 4.6 and promotes to Opus 4.7
   on demand via a `/promote` slash command or explicit `/model opus-4-7`?

## 6b. Sequential Phase Architecture — gate policy (2026-04-24)

Aligns with the Longform Guide's RESEARCH → PLAN → IMPLEMENT → REVIEW →
VERIFY pipeline. Gate decisions:

| Gate | Between | Policy | Mechanism |
|---|---|---|---|
| G1 | RESEARCH → PLAN | skip (default); configurable to `notify` | — |
| **G2** | **PLAN → IMPLEMENT** | **approve (required)** | **ExitPlanMode** ✅ |
| G3 | IMPLEMENT internal | follow Claude Code permission mode | settings.json `permissions.{allow,deny,ask}` |
| G4 | IMPLEMENT → REVIEW | skip (auto-dispatch Reviewer) | — |
| **G5** | **REVIEW → VERIFY/LOOP** | **auto-loop, cap 3 iterations** ✅ | Brain counts, surfaces after cap or structural issue |
| G6 | VERIFY → DONE | notify | Brain prints summary and halts |
| G7 | DONE → COMMIT/PR | explicit user request | per global CLAUDE.md "never commit unless asked" |

Configurable via `~/.claude/orchestra/config.yaml` (global default) with
optional per-project override at `${CLAUDE_PROJECT_DIR}/.claude/orchestra/config.yaml`:

```yaml
gates:
  after_research:  skip             # skip | notify | approve
  after_plan:      approve          # THE gate
  after_implement: skip
  after_review:    auto_loop        # skip | auto_loop | approve
  after_verify:    notify

approval_method:  exit_plan_mode    # exit_plan_mode | slash_command | sentinel_file
review_loop_max:  3
```

Implication: the pipeline adds a **Reviewer** tier alongside Planner and Actor.
Reviewer = Sonnet 4.6 (read-only + analysis), called after Actor finishes each
implementation step, returns `review-comments.md` (atomic-rename). Brain feeds
comments back to Actor up to `review_loop_max` iterations.

Minor note: RESEARCH stage can be served by Brain itself (Opus) or by the
built-in `Explore` subagent — no dedicated Researcher agent file needed unless
later experience shows the benefit.

## 6c. Canonical alignment — three edits applied (2026-04-24)

Stress-test against Claude Code's documented primitives surfaced three spots
where the earlier design drifted from canon. All three are applied:

### Edit 1 — End-of-subagent trigger uses `SubagentStop`, not `PostToolUse(Agent)`
`SubagentStop` is Claude Code's canonical hook for the subagent-ended event.
`PostToolUse(Agent)` fires at nearly the same moment but is semantically
"after the Agent tool's return trip"; `SubagentStop` is purpose-built.
Cleaner; more future-proof.

Hook matrix for the orchestrator:

| Event | Hook | Action |
|---|---|---|
| Subagent about to start | `PreToolUse` (matcher: `Agent`) | Spawn tmux window (if `$TMUX`); append prompt line to `invocations.log` |
| Subagent ended | `SubagentStop` | Finalize window title to `✓ done`; schedule 120 s `kill-window`; append result line to `invocations.log` |
| Before context compaction | `PreCompact` | Save Brain state to `${CLAUDE_PROJECT_DIR}/.claude/orchestra/brain-state.md` |

### Edit 2 — `ExitPlanMode` is Brain-only; Planner does NOT emit it
Canonical plan-mode flow:
1. Brain enters **plan mode** (permission mode — `Shift+Tab` cycle or
   `--permission-mode plan` or `/plan-mode`). The `/brain` command enters
   plan mode automatically at start of a planning cycle.
2. Brain delegates to Planner subagent; Planner returns plan as text AND
   writes `PLAN.md` via atomic-rename.
3. **Brain** calls `ExitPlanMode` with the plan content. UI surfaces approve /
   reject.
4. On approve, Brain exits plan mode and dispatches Actor.

Implications:
- `~/.claude/agents/planner.md` frontmatter `tools:` list **must exclude
  `ExitPlanMode`**. Planner returns plan text; it cannot surface it to the
  user — only Brain can.
- This mirrors Anthropic's built-in `Plan` subagent, which also excludes
  `ExitPlanMode`. Same model.
- Approval via edit-sentinel-file is the documented headless fallback.

### Edit 3 — Drop `/plan`, `/act`, `/review`; keep only `/brain` as opt-in pipeline
The canonical Claude Code pattern is: user talks to Brain, Brain decomposes
and delegates via the Agent tool as needed — often multiple subagents in
parallel in a single message. Forcing every interaction through a 5-stage
pipeline is community convention (Longform Guide), not Anthropic canon.

Consequences:
- `/brain` = heavyweight opt-in. User invokes it when a task is
  big-enough-to-warrant-the-pipeline (architecture work, multi-file
  refactors, anything where G2 approval genuinely matters). Enters plan
  mode, delegates to Planner → surfaces plan via ExitPlanMode → on approve
  delegates to Actor → delegates to Reviewer → loops up to cap-3 → halts
  with summary.
- Default conversation with Brain = canonical behaviour. Brain auto-delegates
  to Planner / Actor / Reviewer (or built-in Explore, Plan, etc.) when the
  request warrants, without a prescribed pipeline.
- This aligns with Anthropic's "minimum viable parallelization" guidance.

## 6d. Moderate deviations — your call before implementation

Two items flagged as "acceptable but a more canonical alternative exists":

| # | Deviation | Proposed v1 | Canonical alternative |
|---|---|---|---|
| D1 | Custom state dir `.claude/orchestra/` | keep (co-located with other Claude Code config) | sibling `.orchestra/` to keep `.claude/` pristine |
| D2 | Custom `orchestra/config.yaml` | keep (flexible, per-project overridable) | extend `~/.claude/settings.json` with `orchestra:` key |

Both are moderate; neither blocks implementation. Defaults stand unless you
override.

## 6e. Autonomy modes — two axes and three presets (2026-04-24)

Autonomy has **two independent axes** that the earlier design conflated:

| Axis | Controls | Primitive |
|---|---|---|
| **X — Tool-level prompts** | Does Claude Code prompt on each Edit/Write/Bash? | Claude Code's built-in permission modes: `default` / `acceptEdits` / `plan` / `bypassPermissions` |
| **Y — Stage-level gates** | Does the orchestra pause between PLAN / IMPLEMENT / REVIEW / VERIFY / COMMIT? | Orchestra `gates.*` and `commit.policy` in `config.yaml` |

Preset names use **canonical Claude Code terminology** (Axis X permission mode
names) rather than invented terms:

| Preset | Axis X (Claude Code perm mode) | G2 plan | G5 review loop | G7 commit | Use case |
|---|---|---|---|---|---|
| **`default`** (v1 default) | `default` (ask on every tool) | approve via ExitPlanMode | auto_loop cap 3 | explicit | Interactive pair-programming |
| **`acceptEdits`** (v1) | `acceptEdits` (edits auto, Bash asks) | approve via ExitPlanMode | auto_loop cap 3 | explicit | Trust edits, gate Bash |
| **`auto`** (v2 — stubbed in v1) | `bypassPermissions` (nothing asks) | notify only | auto_loop cap 5 + CROSS-CHECK loop | auto-commit on branch | Unattended multi-step work |

### Mode switching — portable between tmux and VSCode

- **Axis X**: `Shift+Tab` cycle, `/permissions` slash command, or
  `--permission-mode X` flag at launch. Claude Code canon; works identically
  in tmux and VSCode.
- **Axis Y**: `/orchestra-mode <preset>` slash command (new; see §6e.1).
  Writes preset name to the orchestra state, hook script reads it on next
  invocation.
- **`/brain --mode <preset>`**: temporarily override Y for a single pipeline
  invocation.

### 6e.1 `/orchestra-mode` — v1 stub + v2 intent

**v1 (ship now)**: `~/.claude/commands/orchestra-mode.md` as a stub that:
- Accepts arg `default` | `acceptEdits` | `auto`
- For `default` and `acceptEdits`: writes the preset to
  `${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env` (simple key=value file)
  and echoes a confirmation. Does NOT change the Claude Code permission mode
  (that's user-driven via `Shift+Tab` / `/permissions` in v1 to keep the
  stub harmless).
- For `auto`: prints a clear "not yet implemented in v1 — see §6e.2 of the
  orchestra TODO for v2 intent" and exits. Does not change any state.

**v2 intent (document now, implement later)**:
- Accept the same three args plus optional `--cap N`, `--token-budget USD`,
  `--branch-prefix …` overrides.
- On selecting a preset, sync **both axes**: issue `/permissions <mode>` to
  Claude Code (or set `--permission-mode` on next agent spawn) AND write the
  orchestra-level gate / loop / commit-policy overrides to `state.env`.
- `auto` preset additionally: (a) verifies current git branch is not
  protected, auto-creates `orchestra/auto-<UTC-ts>` if needed; (b) arms the
  CROSS-CHECK stage; (c) wires checkpoint-commit-per-iteration; (d) arms
  the test gate (auto-detects pytest / pnpm test / make test / cargo test)
  and refuses FINALIZE on red tests; (e) enforces iteration cap and
  token-budget cap; (f) on any rail trip, writes
  `orchestra/auto-halt-<ts>.md` with full context and halts cleanly for
  user-driven `/brain-resume`.
- `/brain-resume` (also v2) reads a halt file and continues from the
  checkpointed state.

**Implementation note for v2**:
- The hook script (`~/.claude/scripts/orchestra-hook.sh`) already reads
  `state.env` on each invocation in v1 — v2 just adds more keys it reacts
  to (`cap`, `token_budget`, `commit_policy`, etc.).
- CROSS-CHECK is a Brain-level concern (not a subagent), so v2 adds a
  `/brain-crosscheck` internal step in the `/brain` skill body, not a new
  agent file.
- Branch isolation and checkpoint commits are implemented in the `/brain`
  skill body as explicit `Bash` tool calls; no new infrastructure.
- Test gate detection is a shell-level scan in the `/brain` skill;
  project-specific overrides via `config.yaml → test_gate.command`.

### 6e.2 Config schema (v1 keys + v2 keys)

```yaml
# ~/.claude/orchestra/config.yaml  (global default)
# ${CLAUDE_PROJECT_DIR}/.claude/orchestra/config.yaml  (per-project override)

orchestra_mode: default            # v1: default | acceptEdits
                                   # v2: + auto

# v1 — already wired
gates:
  after_research:  skip
  after_plan:      approve         # ExitPlanMode
  after_implement: skip
  after_review:    auto_loop
  after_verify:    notify

approval_method:  exit_plan_mode
review_loop_max:  3

commit:
  policy: explicit

# v2 — stubs in config; honored only when orchestra_mode=auto
crosscheck_loop_max: 5
token_budget_usd:   5              # 0 disables
commit_auto:
  branch_prefix:    "orchestra/auto-"
  branch_protect:   ["main", "master"]
  checkpoint_every_iteration: true
test_gate:
  detect_from: [pytest, pnpm, npm, make, cargo]
  required_for_finalize: true
```

### 6e.3 Safety rails for `auto` (v2 only, documented now)

Non-optional when `orchestra_mode: auto`:

1. **Branch isolation** — refuse to run on protected branches; auto-create
   `orchestra/auto-<UTC-ts>`.
2. **Checkpoint commits per iteration** — each IMPLEMENT step produces a
   `[orchestra auto iter N]` commit; full rollback via `git reset` to any
   checkpoint.
3. **Iteration cap** — hard stop at `crosscheck_loop_max` iterations.
4. **Token budget cap** — optional soft stop at `token_budget_usd`.
5. **Test gate** — tests must pass before FINALIZE.
6. **No push, no PR** — auto mode commits locally only; pushing and PR
   creation remain explicit user actions (consistent with global CLAUDE.md
   "never commit unless asked" rule; auto-commit on an isolated branch is
   a bounded relaxation, not a full abandonment of the rule).
7. **Resumable halt** — on any rail trip, write `auto-halt-<ts>.md` with
   full context and halt cleanly; user decides whether to `/brain-resume`.

### 6e.4 Extended pipeline under `auto` (v2)

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

CROSS-CHECK is Brain-level (not a new subagent). REVIEW = "is the code
good" (Reviewer). CROSS-CHECK = "does the code fulfil PLAN.md" (Brain). Both
must pass for FINALIZE.

## 6f. Tmux window naming (2026-04-24)

Windows (not panes), one per subagent invocation. Names track the
**Sequential Phase Architecture stage** the subagent serves, not the agent's
own name (Planner/Actor/Reviewer):

| Subagent invoked | Window base name | Stage served |
|---|---|---|
| Planner | `plan` | PLAN |
| Actor | `implement` | IMPLEMENT |
| Reviewer | `review` | REVIEW |
| built-in `Explore` (when used for G1) | `research` | RESEARCH |
| (v2) Brain CROSS-CHECK | `cross-check` | CROSS-CHECK |
| (v2) Brain FINALIZE | `finalize` | FINALIZE |

Brain itself does NOT get a window — Brain runs in the main tmux session
window the user invoked `claude` in.

### Suffix rule

If a window with the base name already exists (e.g. two Actors running
concurrently, or a second IMPLEMENT iteration after REVIEW), append
underscore-counter suffix per the user spec:

- First Actor → `implement`
- Second concurrent or subsequent Actor → `implement_1`
- Third → `implement_2`
- …

Hook logic at spawn time: `tmux list-windows -F '#W'` filtered to the base
name; lowest unused integer wins. First instance of a stage is the bare
base name (no suffix).

### Cross-machine note

Tmux sessions are per-machine. Window names stay clean (no hostname in the
name). The cross-machine disambiguation lives in **logs** and **per-invocation
logfile names** (`plan-<UTC-ts>-<HOSTNAME>-<PID>.log`), not in tmux window
names. If two machines both show an `implement` window, that's fine; they're
in different tmux sessions.

### Multi-word stages

Stage names with multiple words use dashes; the suffix counter uses
underscores. Example: `cross-check`, `cross-check_1`, `cross-check_2`. This
is consistent with the user's original spec (`implement_1`, `implement_2`).

### What each window shows

Bracketed view only (per §3.1 decision):

1. On spawn (`PreToolUse` on Agent): window opens running
   `tail -f <stage>-<id>.log` where `<id>` is the full stamp
   (`<UTC-ts>-<HOSTNAME>-<PID>`). Hook also writes the outgoing prompt to
   that logfile before starting the tail so the window shows context
   immediately.
2. While subagent runs: nothing further streams — in-process subagent
   tool calls are not surfaced (bracketed visibility chosen). The window
   shows "working…" at most.
3. On completion (`SubagentStop`): hook appends the result summary to the
   logfile (visible in the tail), renames the window to
   `<base>_<suffix> ✓` (or equivalent marker), and schedules
   `tmux kill-window -t <target>` in 120 s.

## 7. What comes next

Do not implement yet. Resolve the still-open items (see §8), then the v1
implementation work is:

1. `~/.claude/agents/planner.md` (Sonnet 4.6, read-only tool allowlist;
   `tools:` excludes `ExitPlanMode`; system prompt produces a numbered plan
   and writes `PLAN.md` via atomic-rename).
2. `~/.claude/agents/actor.md` (Haiku 4.5, write+exec tool allowlist; denies
   on `Bash(rm -rf …)`, `Bash(git push …)`, writes outside project; system
   prompt executes a scoped step and updates `TASKS.json`).
3. `~/.claude/agents/reviewer.md` (Sonnet 4.6, read-only + analysis; returns
   `review-comments.md` via atomic-rename).
4. `~/.claude/settings.json` additions:
   - `PreToolUse` (matcher: `Agent`) → calls `orchestra-hook.sh start`.
   - `SubagentStop` → calls `orchestra-hook.sh end`.
   - `PreCompact` → saves Brain state to
     `${CLAUDE_PROJECT_DIR}/.claude/orchestra/brain-state.md`.
   - Per-agent tool `permissions.deny` rules.
5. `~/.claude/scripts/orchestra-hook.sh` — env-detecting hook script
   (branches on `$TMUX`; spawns/kills windows in tmux; appends to
   `invocations.log` either way; all log writes stamped
   `${HOSTNAME}:${PID}:${CLAUDE_SESSION_ID}:${TIMESTAMP}`).
6. `~/.claude/commands/brain.md` — heavyweight opt-in pipeline skill
   (enters plan mode, delegates Planner → Brain calls ExitPlanMode → Actor
   → Reviewer → loops up to cap 3 → notify/halt).
7. `~/.claude/commands/orchestra-mode.md` — v1 stub (see §6e.1): accepts
   `default` / `acceptEdits` / `auto`; writes preset to `state.env`; `auto`
   prints "not yet implemented" with a pointer to §6e of this doc.
8. `~/.claude/orchestra/config.yaml` — global default config per §6e.2.
9. Per-project bootstrap: `${CLAUDE_PROJECT_DIR}/.claude/orchestra/` dir is
   auto-created by the hook on first Agent invocation; `.enabled` marker
   gates whether the hook does anything beyond a no-op.
10. Per-project `.gitignore` entry `.claude/orchestra/` (user action per
    project they opt in).

### Deferred to v2 (do not build now)
- `auto` preset implementation, CROSS-CHECK stage, branch isolation,
  checkpoint commits, test gate, token-budget cap, halt-and-resume — all
  per §6e.1/§6e.3/§6e.4.
- Option A (separate `claude --model …` per tier) as showcase — only if
  v1 proves insufficient.
- Dedicated Researcher agent — only if Brain/Explore proves inadequate for G1.
- Lock sentinel — only if real clobbers appear.
- Non-NFS machine deployment helper (`make install-orchestra`).

## 8. Still open before v1 implementation

- Tool boundaries per tier (defaults proposed in §6 item 1)
- Handover channel (defaults proposed in §6 item 2)
- Model pinning (§6 item 6)
- Brain cost posture (§6 item 7)
- `.enabled` opt-in marker behaviour
- D1 state dir name (§6d)
- D2 config file location (§6d)
