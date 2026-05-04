---
title: "Claude Code three-tier orchestrator (Brain/Planner/Actor) — design notes & open questions"
created_at: 20260424-000000
created_by: Claude Code (Claude Opus 4.7, 1M context)
updated_by: Claude Code (Claude Sonnet 4.6)
updated_at: 2026-05-04--21-30
context: >
  Working session exploring how to build a three-layer Brain/Planner/Actor
  orchestrator on top of Claude Code, originally motivated by the Cline VSCode
  plugin's Plan/Act dual-model workflow. Sources consulted in this session:
  (1) Gemini share https://gemini.google.com/share/c9b60b1a3c79 — blocked by
  Google consent redirect on direct fetch, later read from a local copy at
  /var/tmp/gemini-chat.md; (2) the "Longform Guide" at
  https://github.com/affaan-m/everything-claude-code/blob/main/the-longform-guide.md;
  (3) the local Claude Code usage report at
  /mnt/nfs/Florian/Gin-AI/.claude/usage-data/report.html; (4) SoHoAI repo
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

## v1 Implementation & Amendments

### Status banner (2026-04-28)

Between 2026-04-26 and 2026-04-28 the orchestra ran on a **headless `claude -p` execution model** (Option A, per-tier subprocesses, multi-run registry, separate Phase 0 dialogue session). That detour has been **reverted**. The current architecture is again the **canonical Claude Code subagent model** described in the original §§1–13.

If you are reading the amendments below dated 2026-04-26 onwards, treat those as **historical record** of an experiment, not active design. The authoritative explanation of the revert is in:

- The closing **Amendment — 2026-04-28** section at the end of this file.
- The standalone **`docs/architecture/2026-04-28-headless-revert.md`** that captures the research note from run `subagents-vs-headless-revisited-20260428`.

Top-line summary of what changed back:

- Single Claude Code session orchestrates everything inline (Brain). No `claude -p` subprocesses. No tmux windows for stages. No multi-run registry.
- Phase 0 RESEARCH happens inside Brain (it interrogates the operator directly), not in a separate Opus session. The `agents/researcher.md` file is deleted.
- Subagents are dispatched via the canonical `Task` tool with `subagent_type: planner | actor | reviewer`.
- Per-invocation artifact subdirectories (`.claude/orchestra/sessions/<UTC-timestamp>-<PID>/`) replace the flat `.claude/orchestra/PLAN.md` etc.
- Lazy 30-day cleanup of session subdirs at every `/brain` and `/duo` start.
- Permission flow: parent in plan mode → `ExitPlanMode` after plan approval → standard Claude Code "auto-edit / manually approve / cancel" UX.
- Deleted: `commands/{brain-resume,brain-abandon,brain-status,orchestra-mode}.md`, `agents/researcher.md`, `scripts/{start-research,runs-registry,run-tier,format-stream}.sh`, `.vscode/tasks.json`. ~890 lines of headless plumbing gone.

### §9 Locked decisions table (v1, as of 2026-04-24)

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

### Implementation v1 — 2026-04-24 21:10 CEST (19:10 UTC)

Files created / modified:

| Path | Size | Purpose |
|---|---|---|
| `~/.claude/agents/planner.md` | new | Sonnet 4.6 subagent — reads codebase, writes numbered plan to `PLAN.md` via atomic-rename. `tools:` = `Read, Grep, Glob, WebFetch, TodoWrite` + narrow exception for `Write`/`Bash` limited to the atomic-rename on `PLAN.md`. Excludes `ExitPlanMode` (canonical — Brain-only). |
| `~/.claude/agents/actor.md` | new | Haiku 4.5 subagent — executes one scoped step, updates `TASKS.json` via atomic-rename. `tools:` = `Read, Edit, Write, Bash, Grep, Glob, TodoWrite`. System prompt documents hard denies (`rm -rf`, `git push`, `git commit` in v1) and strict scope discipline. |
| `~/.claude/agents/reviewer.md` | new | Sonnet 4.6 subagent — reads `git diff`, compares to PLAN.md, writes `review-comments.md` via atomic-rename. `tools:` = `Read, Grep, Glob, Bash, TodoWrite` (+ `Write` narrowly for review file). Emits verdict PASS / FIX / BLOCK. |
| `~/.claude/scripts/orchestra-hook.sh` | new, +x | Single hook dispatcher with three modes: `start` (PreToolUse), `end` (SubagentStop), `compact` (PreCompact). Branches on `$TMUX`, env-var `CLAUDE_ORCHESTRA_DISABLE_TMUX` opts out of tmux spawning even inside a session. ~~Gates on `${CLAUDE_PROJECT_DIR}/.claude/orchestra/.enabled` marker~~ — per-project gate removed 2026-04-25; hook now fires unconditionally. Stamps every log line and per-invocation logfile name with `host:pid:session:ts`. |
| `~/.claude/commands/brain.md` | new | `/brain` slash command — heavyweight opt-in pipeline. Requires plan mode; delegates to Planner → calls `ExitPlanMode` → dispatches Actor → Reviewer → loops cap 3 → halts with summary. Explicitly does NOT commit in v1. |
| `~/.claude/commands/orchestra-mode.md` | new | `/orchestra-mode` slash command — v1 stub. `default` / `acceptEdits` write preset to `state.env`; `auto` prints "not yet implemented in v1" with pointer to §10.2 of design.md. |
| `~/.claude/orchestra/config.yaml` | new | Global default config. v1 keys fully wired (`gates`, `review_loop_max`, `commit.policy`). v2 keys present as stubs (`crosscheck_loop_max`, `commit_auto`, `test_gate`, `token_budget_usd`) — honored only under `orchestra_mode: auto`. |
| `~/.claude/settings.json` | modified | Hook entries: `PreToolUse(Agent)` → `start`; `PreToolUse(Edit)` → `tool`; `PreToolUse(Write)` → `tool`; `PreToolUse(Bash)` → `tool`; `SubagentStop` → `end`; `PreCompact` → `compact`. All via `orchestra-hook.sh`. Existing `PreToolUse(Bash)` → `venv-enforce.sh` preserved. `Edit`/`Write`/`Bash` → `tool` entries added 2026-04-25. |

Directories newly created: `~/.claude/agents/`, `~/.claude/commands/`, `~/.claude/orchestra/`.

Shared across machines via NFS: `~/.claude` is a symlink to `/mnt/nfs/Florian/Gin-AI/.claude`, so every file above is instantly visible on all Debian hosts that mount `~/Gin-AI/`. No per-host install step.

Validation performed:

1. **Syntax check** — `bash -n ~/.claude/scripts/orchestra-hook.sh` → OK.
2. **settings.json validity** — `jq . ~/.claude/settings.json` → OK; `jq -r '.hooks | keys[]'` → `PreCompact`, `PreToolUse`, `SubagentStop`.
3. **Opt-in gate** *(historical — gate removed 2026-04-25; see Amendment)* — Ran `start` with no `.enabled` marker in a fresh temp project → hook exited 0, no files created. Confirmed marker-gate behaviour at original install.
4. **Full lifecycle test** *(at original install, with `.enabled` gate active)* — Created `/tmp/orchestra-test-enabled/.claude/orchestra/.enabled`, fired `start`/`end` for each of `planner`/`actor`/`reviewer`, then `compact`. Verified window spawning, logfile tailing, renaming to `✓` suffix, auto-close scheduling, stamped JSON log lines, state.env records, brain-state.md generation, per-stage logfile naming.
5. **Window-counter regression** — First (buggy) run had the `wc -l || echo 0` pipefail interaction that produced `plan_0` for what should have been `plan`. Fixed by switching to `grep -cE` + subshell error swallowing + post-filtering. Re-tested clean: first invocation gets bare `plan`; subsequent invocations in the same tmux session get `plan_1`, `plan_2` as spec requires.

Not tested live (deferred to first real use):

- Actual invocation through the Agent tool in a real Claude Code session — the hook fires when `Agent(subagent_type="planner")` etc. runs for the first time. Expected to work; hook is defensive (all errors swallowed, always exits 0, never blocks Claude Code).
- `ExitPlanMode` end-to-end flow (requires plan mode + user approval UI).
- Multi-host concurrent invocation (user confirmed this case is rare; design uses stamping rather than locking).
- PreCompact firing at real 100K-token threshold — only manually triggered in tests.

Interaction notes for next session:

1. **Orchestra is now globally on** (2026-04-25 amendment). No `.enabled` marker needed; no per-project `.gitignore` entry needed (covered by `~/.gitignore_global`). The state dir `.claude/orchestra/` auto-creates on first Agent invocation in any project.
2. **Entering plan mode** — `/brain` expects to be in plan mode before delegating to Planner. Either `Shift+Tab` cycle to plan mode before typing `/brain`, or let `/brain` prompt the user to enter it. Plan mode is Claude Code-native, not orchestra-specific.
3. **If auto-close is too aggressive** — Edit `tmux.auto_close_seconds` in `~/.claude/orchestra/config.yaml`. (v1 hook currently hard-codes 120; that value should move into the script reading the config in v2.)
4. **If you want logfile-only visibility even in tmux** — Export `CLAUDE_ORCHESTRA_DISABLE_TMUX=1` in the shell before launching `claude`. Hook respects this opt-out.
5. **Observed deviation from strict canon** — `settings.json` permission tooling uses the format it already had in place; the orchestra hook does not inject new `permissions.deny` rules for Actor (rely on Actor's system-prompt discipline in v1). If real over-reach happens in practice, add explicit denies in a future pass.

Known v1 limitations (not bugs — deferred features):

| Limitation | Reason | Future fix location |
|---|---|---|
| Parallel Actor fan-out may close the wrong tmux window on `end` | v1 tracks last-window per stage in `state.env`; no unique correlation between `start` and `end` events for concurrent invocations of the same stage | v2 could use a per-invocation sentinel file with a unique token passed through the prompt |
| `/orchestra-mode` does not actually flip Claude Code permission mode | Deliberate — keeps v1 stub harmless; Axis X flip is user-driven via `Shift+Tab` | v2 `/orchestra-mode` implementation |
| `brain-state.md` payload is minimal (just pointers to state files + last 20 log lines) | Placeholder in v1; full payload schema depends on what `/brain-resume` will need | v2 schema refinement |
| No log rotation — `invocations.log` and per-invocation logfiles grow unboundedly | Acceptable for v1 usage volumes; user can `rm` periodically or add logrotate | Optional user-side hygiene |
| Window counter is tmux-session-wide, not per-project | A `plan` window from one project blocks `plan` in another until it auto-closes | Acceptable; window names include stage, not project; 120 s auto-close limits overlap |
| Hook writes a stale state.env entry that persists indefinitely | Each `start` appends a new `LAST_WINDOW_<STAGE>=…` line; `state.env` grows | Low-impact; later lines shadow earlier when sourced; a `state.env.tmp`+rename rewrite could be added if the file grows uncomfortably large |

Rollback procedure:

If the orchestra misbehaves and you need to disable it quickly:

1. **Per-project disable** — ~~delete `.enabled` marker~~ **(gate removed 2026-04-25)**. To suppress orchestra in a specific project, set `CLAUDE_ORCHESTRA_DISABLE_TMUX=1` to suppress tmux windows, or temporarily rename the global hook script to `.bak` (affects all projects). A per-project opt-out marker is not currently implemented; add one if needed.
2. **Global disable** — `mv ~/.claude/scripts/orchestra-hook.sh{,.bak}`. Subsequent Claude Code sessions will see the hook fail loudly (intentional — not silent). Rename back to restore.
3. **Full uninstall** — `rm -rf ~/.claude/agents/{planner,actor,reviewer}.md ~/.claude/commands/{brain,orchestra-mode}.md ~/.claude/scripts/orchestra-hook.sh ~/.claude/orchestra/`, then edit `~/.claude/settings.json` to remove the three orchestra hook entries. Existing per-project `.claude/orchestra/` state dirs may be left for forensic reading or removed separately.

Next steps (user-facing):

1. **Smoke test in SoHoAI** — opt it in (step 1 of "Interaction notes"), then run a small `/brain` pipeline on a trivial task to verify the windows spawn and the gate fires. Good first task: "Add a docstring to `rag_engine/search.py::search_rag`" — small, reviewable, low-risk.
2. **Tune Actor deny rules** — once a few `/brain` runs expose any overreach patterns, add explicit `permissions.deny` entries in `~/.claude/settings.json` rather than relying solely on system-prompt discipline.
3. **Build v2 when appetite arrives** — `orchestra_mode: auto`, CROSS-CHECK, branch isolation, checkpoint commits, test gate, halt-and-resume. All documented in §10.2 of design.md.

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
`~/.claude/scripts/status-line.sh` — a new conditional block runs after the existing git-branch field. ~~Originally activated only when `.enabled` existed~~ — see Amendment 2026-04-25; now activates whenever the global orchestra config is present (`~/.claude/orchestra/config.yaml`). Three new fields: Preset badge, Active subagent, Overflow warning. Validation: script validated with `bash -n`; five test scenarios render correctly.

### Amendment — 2026-04-25 (branched session `Claude-orchestra-light`): lightweight `/duo` pipeline + badge disambiguation

Two additions made in a branched conversation after the main v1 session closed. No new agents, no new hooks, no settings changes. One new slash-command file; two existing slash-command files lightly amended.

**1. New lightweight pipeline: `/duo` (Sonnet Plan → Haiku Act)**

File: `~/.claude/commands/duo.md` (new).

Rationale: the full `/brain` pipeline (Opus 4.7 Brain → Planner subagent → per-step Actor/Reviewer loops → Phase 4 doc/memory checks) is the right tool for multi-file refactors, architecture work, and anything where a review loop matters. For simple, well-scoped tasks — a targeted bug fix, adding one function, tweaking config — the overhead is disproportionate. `/duo` offers the same G2 plan-approval gate and Haiku execution with none of the review scaffolding.

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

Workflow: (1) Launch a Sonnet 4.6 session: `claude --model claude-sonnet-4-5`. (2) Enter plan mode (`Shift+Tab`). (3) Chat interactively with Sonnet — read files, refine scope — until the plan is agreed. (4) Type `/duo` (or `/duo <task description>`). (5) Sonnet writes `PLAN.md` (if orchestra-enabled) and calls `ExitPlanMode`. (6) On approval: tell the user to cycle to `bypassPermissions` (`Shift+Tab`), then delegate entire plan to Actor (Haiku) in one Agent call. (7) Actor executes all steps without permission prompts; reports a diff summary. (8) Sonnet produces final summary; restores `ORCHESTRA_MODE=default` in `state.env`.

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

No changes to `status-line.sh` — it already reads `ORCHESTRA_MODE` via `grep … | tail -n 1` (last-write-wins semantics on `state.env`), so the new values render automatically.

Notable design point — `state.env` append semantics: both pipelines append rather than rewrite `state.env`, consistent with the existing hook pattern. The file accumulates pairs of lines per pipeline run (`MODE=orchestra` on start, `MODE=default` on done). The status-line reads the last occurrence (`grep … | tail -n 1`), so earlier lines are shadowed. No cleanup is needed, but `state.env` will grow slowly over many sessions; a periodic trim is acceptable hygiene.

Validation — idempotency audit (2026-04-25, post-restructure): All deployed files verified identical between the repo and `~/.claude/`.

Smoke test of `/duo` pipeline (2026-04-25): Plan-mode gate check OK, Plan mode active OK, Explore subagent OK, Stale plan detection OK, `AskUserQuestion` OK, `state.env` write OK, `ExitPlanMode` awaited.

### Amendment — 2026-04-26: historical detour — Option A migration and related experiments

The 2026-04-26 to 2026-04-28 amendments describe several architectural experiments that were **reverted**. These include:

- Migration to Option A (`claude -p` subprocesses per tier in dedicated tmux windows)
- Separate Phase 0 RESEARCH dialogue in a standalone Opus session
- Multi-run registry with per-run subdirectories (`runs/<run_id>/`)
- New slash commands `/brain-resume`, `/brain-abandon`, `/brain-status`
- Live tool-call streaming feeds via `format-stream.sh` and `run-tier.sh`
- Status-line tracking of active runs and spawned windows
- Supporting scripts: `start-research.sh`, `runs-registry.sh`, `run-tier.sh`, `format-stream.sh`

**These amendments are preserved here for historical record only.** The 2026-04-28 revert explanation and the `2026-04-28-headless-revert.md` research note explain the rationale and the return to canonical architecture.

### v2 Deferred items (from design.md)

These sections from design.md are preserved here for reference:

#### §10. Deferred to v2 — stubs and future intent

- `/orchestra-mode` — v1 stub (accepts arg `default` | `acceptEdits` | `auto`; `auto` prints "not yet implemented in v1")
- `/orchestra-mode auto` — v2 intent (Sync both axes in one step, verify git branch, arm CROSS-CHECK stage, wire checkpoint-commit-per-iteration, arm test gate, enforce iteration cap, on rail trip: write orchestra/auto-halt file, halt cleanly)
- Other deferred items: Option A showcase, Dedicated Researcher subagent, Lock sentinel for cross-machine concurrent project sessions, Non-NFS machine deployment helper, Review-loop escalation verbs after cap-3 surface, `PreCompact` payload schema refinement

#### §13.3 What would be required to close the live feed gap

A truly full live feed (thinking blocks, tool results, prose between calls) would require one of:

1. **A Claude Code streaming hook** — a new hook type that fires on each streamed token or on each model-output chunk (thinking block, prose segment, etc.). This would require an Anthropic-side change to Claude Code's hook architecture. Not available in v1 or v2 as currently documented; would need to be raised as a feature request.

2. **A dedicated subprocess per subagent** (Option A from the design history, §9) — spawn each tier as a separate `claude --model … --print` process whose stdout Claude Code can pipe to the tmux window directly. This was explicitly rejected in favour of Option B (native subagents) because it requires managing inter-process communication and loses the native `ExitPlanMode` / permission-mode integration. Revisit only if native subagent visibility proves insufficient for real workflows.

3. **Agent self-reporting** (Tier 2 fallback) — instruct Actor/Planner/Reviewer to emit a structured progress line via `Bash` (e.g., `echo "[step] …" >> $LOGFILE`) after each significant action. This captures actor *intent* but not *thinking*, and requires every subagent prompt to carry the logfile path. Viable workaround; invasive.

#### TO DO — v2 optimization (3): persistent subprocess per tier

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

#### TO DO — v2 optimization (4): 1-hour TTL prompt caching

**What it is.** Anthropic's prompt cache supports two TTL tiers:
- Default: 5 minutes (included in standard pricing)
- Extended: 1 hour (requires `cache_control: {type: "ephemeral", ttl: "1h"}` in the API request, with ~30% premium on the cache-write multiplier; cache reads cost the same)

**Why deferred.** `claude -p` does not currently expose `cache_control` TTL via CLI flag. Implementation would require either Claude Code adding the flag, or moving to direct Anthropic SDK calls (non-trivial).

**When it might pay off:**
- Pipelines that span >5 minutes between same-tier calls (long Actor steps where Reviewer's prior cache expires before the next call)
- Long human-decision pauses at G2 (`ExitPlanMode`) — user takes 10+ min to read the plan
- Heavy daily use where one user runs many `/brain` pipelines on similar tasks

**How to quantify:** (1) Instrument tier invocations to log API usage data (cache_creation_input_tokens, cache_read_input_tokens, timestamp + tier + invocation ID). (2) Run a representative sample (5–10 typical `/brain` runs, 5–10 typical `/duo` runs) covering normal task variety. (3) For each tier, compute the *miss rate due to TTL expiry*. (4) Decision rule: if any tier shows TTL-miss-rate >20%, 1-hour TTL would help that tier. (5) Cost comparison: Status quo vs. With 1h TTL vs. Break-even calculation.

#### TO DO — optional FINALIZE doc-review stage

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

#### v2 TO-DO classification (architecture-aware)

The 2026-04-26 migration to Option A (`claude -p` subprocesses on `main`) makes some v2 TO-DOs architecture-specific. The Option B (native Agent-tool subagents) work is preserved on the **`sub-agents`** git branch for fallback or future development.

| TO-DO | Common | Option A (`main`) | Option B (`sub-agents` branch) |
|---|---|---|---|
| Optional FINALIZE doc-review stage | ✓ | applies | applies |
| `auto` mode (existing detailed spec below) | concepts only | implementation needs rewrite | implementation matches the spec |
| Optimization (3): persistent subprocess per tier | | ✓ | n/a (Agent tool reuses session natively) |
| Optimization (4): 1-hour TTL prompt caching | | ✓ | n/a (Agent tool reuses Brain's session cache) |
| Lock sentinel for cross-machine project sessions (§10.3) | ✓ | applies | applies |

### Amendment — 2026-04-28: revert headless detour, return to canonical subagents

This amendment supersedes earlier amendments dated 2026-04-26 onwards (the Option A migration, the Phase 0 separate-session, the multi-run registry). Those amendments described an experiment that was rolled back. The original §§1–13 description of subagent architecture is again authoritative.

**Why the revert:**

Five pieces of evidence accumulated between 2026-04-26 and 2026-04-28 made the headless approach untenable:

1. **The capability rationale was wrong.** The 2026-04-26 migration was justified by a belief that subagents could not carry per-agent model + permission settings. They can. The Anthropic Claude Code Subagents guide (Apr 2026) and the operator's own empirical test confirm that subagent YAML frontmatter supports `model`, `permissionMode`, `tools`, `disallowedTools`, `effort`, `maxTurns`, `isolation`, and `memory`. The only documented caveat is that a parent's `--dangerously-skip-permissions` flattens children — which is a constraint we already had to design around in any architecture.

2. **The cost story was inverted.** The "headless = cheaper because per-tier model routing" intuition is false in practice. Each `claude -p` cold-starts a new process and defeats the parent session's prompt cache. The PDF guide reports that ~90% of subagent token cost in long sessions is cache reads at ~$0.50/MTok on Opus-equivalent — **subagents within a warm parent are plausibly cheaper than headless subprocesses**, despite the nominal 4–7× multiplier looking scarier on paper.

3. **The complexity tax was real.** The headless approach added ~890 lines of bash plumbing (`start-research.sh`, `runs-registry.sh`, `run-tier.sh`, `format-stream.sh`, status-line tracking, multi-run state machine) and a separate VSCode tasks.json launcher integration. Subagents need none of it.

4. **Two of the four claimed benefits were illusory or anti-goals.** The headless approach was supposed to deliver: (a) live visibility into substream work, (b) cross-day resumability, (c) parallel runs in one operator session, (d) independent permission contexts. The operator disavowed (a) and (b) explicitly ("I want WHAT not WHY", "/brain-resume is overkill"); (c) is replaced by "open another `claude` session"; (d) is provided by subagents already.

5. **`/orchestra-mode` was forgotten.** When the operator was asked which commands to keep, they did not remember `/orchestra-mode` existed. That is sufficient evidence it was not earning its slot. Deleted alongside the rest.

**What the new architecture looks like:**

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

**What the new architecture explicitly does NOT do:**

- No `claude -p` subprocesses.
- No tmux windows opened by the orchestra.
- No multi-run registry (`runs.jsonl`) or per-run subdirs under `runs/<run_id>/`.
- No `/brain-resume`, `/brain-abandon`, `/brain-status`, `/orchestra-mode` slash commands.
- No live tool-call streaming feed (subagents are opaque-by-design; PreToolUse(Edit/Write/Bash) hook removed).
- No state.env `ORCHESTRA_MODE` badge tracking.
- No CLAUDE_BRAIN_RUN_ID env propagation.
- No status-line "active runs count" or "spawned-window slug" displays.

**Permission flow (Plan-Then-Execute):**

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

**Per-session subdirectory + 30-day cleanup:**

Each `/brain` or `/duo` invocation:

1. Reads `housekeeping.session_retention_days` from config (project override > global default > hardcoded 30).
2. Lazily cleans up any `.claude/orchestra/sessions/<id>/` subdirs older than that retention window via `find -mtime +N -exec rm -rf`.
3. Creates a fresh per-invocation subdir `<UTC-timestamp>-<PID>/` for its `RESEARCH.md`, `PLAN.md`, `TASKS.json`, `review-comments.md`.
4. Exports `CLAUDE_ORCHESTRA_SESSION_DIR` so the spawned subagents read/write artifacts under the same root.

There is no canonical `CLAUDE_SESSION_ID` env var in Claude Code 2.1.121; PID-based identifiers are stable enough for the practical use case.

**Persistence ownership:**

| Artifact | Written by | Read by |
|---|---|---|
| `RESEARCH.md` | **Brain** (after operator agrees Phase 0 is done) | Planner (as input prompt context) |
| `PLAN.md` | **Brain** (after Planner returns plan text) | Actor; operator review |
| `TASKS.json` | **Actor** (frequent intra-step updates; atomic-rename) | Brain; Reviewer; operator |
| `review-comments.md` | **Brain** (after Reviewer returns review text) | operator review |

Planner and Reviewer are purely read-only (`tools` lists exclude `Write` and `Edit`). The earlier "exception clause" in their `.md` bodies that granted them Write/Bash for atomic-rename was inconsistent with the actual frontmatter allowlist and could not work — Brain owning persistence resolves that.

**Hook script behaviour:**

`scripts/orchestra-hook.sh` is reduced to three modes (was four):

1. **`start` (PreToolUse Agent)** — logs subagent invocation to `invocations.log`. Minimal logging; no tmux window spawning, no live-stage.env pointer.
2. **`end` (SubagentStop)** — logs subagent completion. No window closing, no pointer clearance.
3. **`compact` (PreCompact)** — saves `brain-state.md` with plan/task/decision snapshot for resumption post-`/clear`.

No `tool` mode. PreToolUse(Edit/Write/Bash) matchers removed from settings.json. Tool calls are opaque inside subagents.

**Status-line behaviour:**

Orchestra badge simplified:

- Shows `♪ <mode>` where `<mode>` is read from `${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env` (appended by `/brain` and `/duo` during their execution).
- No "active subagent" display (subagent dispatch is opaque).
- No "active window count" display (no windows spawned).
- Overflow warning `⚠ >200K` retained (Brain cost concern is orthogonal to architecture).

**Deferred features (with trigger conditions):**

- `/orchestra-mode` command entirely deleted (v2 will re-evaluate `auto` mode as a v2.1 feature, if at all).
- `/brain-resume` family (`resume`, `abandon`, `status`) not ported from Option A. If cross-day resumability becomes a pressing need, it belongs as a v2 feature with fresh design (the `sub-agents` branch has the old implementation as reference).
- Live tool-call feed deleted. If workflow demands visibility into subagent tool calls, the `/brain` command can be extended to surface Actor's per-step `TASKS.json` diffs inline; a more invasive hook would only be revisited if Claude Code adds a streaming-output hook type.
- `runs.jsonl` registry deleted. If multi-run bookkeeping becomes a need, it belongs as a separate tooling concern (e.g., a `/brain-history` query command) rather than baked into orchestration.

**Files deleted in the revert:**

- `~/.claude/agents/researcher.md` (Phase 0 research stage agent)
- `~/.claude/commands/brain-resume.md` (resume after research)
- `~/.claude/commands/brain-abandon.md` (mark run abandoned)
- `~/.claude/commands/brain-status.md` (list run statuses)
- `~/.claude/commands/orchestra-mode.md` (preset selection)
- `~/.claude/scripts/start-research.sh` (Phase 0 subprocess spawner)
- `~/.claude/scripts/runs-registry.sh` (runs.jsonl manager)
- `~/.claude/scripts/run-tier.sh` (tier subprocess spawner)
- `~/.claude/scripts/format-stream.sh` (stream-json parser)
- `.vscode/tasks.json` (VSCode launcher integration)

~890 lines of headless plumbing gone.

**Files kept and reverted to Option B:**

- `~/.claude/agents/planner.md` — restored to original frontmatter (no stripped variant, no .stripped/ dir)
- `~/.claude/agents/actor.md` — same
- `~/.claude/agents/reviewer.md` — same
- `~/.claude/commands/brain.md` — restored to original (no launcher stub; full phases inline; subagent dispatch restored)
- `~/.claude/commands/duo.md` — restored to original (subagent dispatch restored)
- `~/.claude/scripts/orchestra-hook.sh` — restored to original 3-mode version (no `tool` mode; no live-stage.env)
- `~/.claude/orchestra/config.yaml` — v1 keys only (v2 keys moved to design-history as spec only)
- `~/.claude/settings.json` — orchestra hooks restored to original (PreToolUse Agent/SubagentStop/PreCompact only; no PreToolUse Edit/Write/Bash)

**Permission model:**

Subagent `permissionMode` frontmatter **replaces** session-level Shift+Tab toggling for individual tiers:

- **Planner.md frontmatter** — `permissionMode: read` (or equivalent narrowing via `tools` list) — ensures Planner cannot edit files, even if parent is in `bypassPermissions`.
- **Actor.md frontmatter** — `permissionMode: bypassPermissions` — Actor runs uninterrupted once approved by operator.
- **Reviewer.md frontmatter** — `permissionMode: read` (or equivalent narrowing) — Reviewer cannot edit.

(Actual frontmatter format TBD by operator once Claude Code 2.1 subagent guide is fully consulted; these are the intent levels.)
- D2 config file location (§6d)

### Amendment — 2026-04-30: per-session telemetry (T1+T2 hybrid) + critical transcript-format finding

**Context:** Investigation into cost optimization opened with the operator seeing `"agent: research"` in the status-line during `/duo` runs and asking whether a cheaper Haiku "researcher" agent should replace those dispatches. Phase 0 dialogue (in this session, `claude-orchestra-telemetry`) established:

- The "research" label is a hook artefact: `orchestra-hook.sh`'s `stage_for_subagent` maps the built-in `Explore` agent type → `"research"`. Sonnet (the `/duo` parent) autonomously dispatches `Explore` subagents during Phase 1 planning based on Claude Code's harness-level guidance ("for broad codebase exploration, spawn Agent with subagent_type=Explore"). Not a designed phase; not an orchestra-defined agent.
- Haiku is the wrong tier for code reasoning. The workload is "understand existing patterns" not "find symbol by name".
- Cost is projected, not observed. No measurement existed to justify any optimization.
- A `researcher.md` agent was already on the deferred list (`docs/TODO.md`) with an explicit gate: "only if Brain/Explore proves inadequate for G1." That gate had never been crossed.

Decision: no researcher agent. Instead, instrument per-session telemetry so future cost/quality decisions are data-driven.

**What was built (commit `ae0b797`):**

*4 net-new files:*
- `config/pricing.yaml` — per-model USD rate table (Opus 4.7 / Sonnet 4.6 / Haiku 4.5), `last_updated` field, 90-day staleness warning via report script.
- `scripts/telemetry-summarize.py` — Python 3 parser: walks parent + subagent transcripts, attributes tokens per tier, computes cost, writes `${SESSION_DIR}/telemetry.json` + appends to global `telemetry.jsonl`.
- `scripts/telemetry-summarize.sh` — bash wrapper sourcing the project venv.
- `scripts/telemetry-report.sh` — on-demand tabular summary + staleness warning.

*7 modifications:*
- `scripts/orchestra-hook.sh` — T1 live event emission to `${SESSION_DIR}/telemetry-events.jsonl` in `start`/`end` modes; new `stop` mode (Claude Code Stop hook safety-net finaliser).
- `config/settings-hooks.json` — wires the `Stop` hook.
- `deploy.sh` — deploys new scripts + `pricing.yaml`; extends jq hook merge for `Stop`.
- `status-line/orchestra-block.sh` — live `~$X.YZ` running-cost indicator from T1 events during in-flight sessions (approximate; T2 supersedes at session end).
- `commands/{duo,brain}.md` — cleanup blocks write `.outcome` marker and invoke `telemetry-summarize.sh`.
- `docs/design.md` — Per-session telemetry subsection added.

**Real numbers from the implementation session itself** (parser dogfooded on its own session):

| Tier | Model | Tokens | Duration |
|---|---|---|---|
| Brain (parent) | Opus 4.7 | 17.1M cache_read + 132K output | ~22 min total |
| Wave 1 Actor | Haiku 4.5 | 4.3M cache_read + 14.5K output | 180s |
| Wave 2 Actor | Haiku 4.5 | 635K cache_read + 10.3K output | 97s |
| Reviewer | Sonnet 4.5* | 1.6M cache_read + 6.4K output | 204s |

Total: $40.27, 1318s. ~64% of cost is the Opus parent's cache-read line on accumulated context — the cheap path (cache_read at $1.50/MTok, ~10% of full input rate). Without caching this line would have been ~$257 and the session ~$262; the dominance is what's left after the discount. Exactly the kind of signal measurement was designed to surface — and the reason "shrink Brain's context or downgrade the Brain model" is the actionable lever, not "fix caching" (caching is already working).

*Note: Reviewer ran on Sonnet 4.5, not 4.6. `agents/reviewer.md` model frontmatter should be verified.*

**Critical architectural finding — Claude Code subagent transcript format:**

The plan's T2 attribution model was based on an incorrect observation about transcript structure. The correct format, empirically verified against this session's transcripts:

*What PLAN.md assumed (wrong):*
> Subagent tokens appear as `isSidechain: true` assistant messages inline in the parent's JSONL transcript, attributable via a `Task` `tool_use` back-trace in the parent stream.

*Observed reality:*
> Each subagent dispatch creates a **separate JSONL file** at:
> `~/.claude/projects/<mangled>/<parent-session-uuid>/subagents/agent-<hash>.jsonl`
> with a sidecar:
> `~/.claude/projects/<mangled>/<parent-session-uuid>/subagents/agent-<hash>.meta.json`
> containing `{"agentType": "actor|reviewer|Explore|…", "description": "…"}`.
>
> The parent's JSONL (`<parent-uuid>.jsonl`) contains **only parent-stream messages**. There are **no `isSidechain` records** in it. The parent JSONL and the subagent JSONLs are sibling files in the project transcript directory; the subagent files are grouped under a `<parent-uuid>/subagents/` subdirectory named after the parent session UUID.

The earlier observation that triggered the sidechain assumption came from a different, older session's transcript (selected by mtime at the time of the initial `grep` check) which happened to have those fields. That session was likely a different invocation pattern or an older Claude Code version.

The parser (`scripts/telemetry-summarize.py`) was rewritten during the implementation to use the correct format: it walks `<parent-uuid>/subagents/agent-*.{meta.json,jsonl}` pairs. `docs/design.md` (the telemetry subsection) and `PLAN.md` still mention the wrong format; see correction note in the session PLAN.md.

**Three post-review bugs caught by dogfood testing (not by Reviewer):**

1. `datetime.utcnow()`/`utcfromtimestamp()` deprecation warnings → replaced with `datetime.now(timezone.utc)` / `datetime.fromtimestamp(…, timezone.utc)`.
2. YAML `last_updated: 2026-04-30` was loaded as a Python `date` object, not JSON-serialisable → coerced to `str(…)` at the `pricing_snapshot_date` field.
3. `session_dir.stat().st_ctime` — Linux `st_ctime` is metadata-change time, not creation time; drifts as files are added to the session_dir → derive `started_at` from the session_dir basename (`<YYYYMMDDTHHMMSSZ>-<PID>` format).

**Reviewer limitation observed:** Reviewer returned PASS on flawed code. All three bugs above required runtime execution to surface; Reviewer's read-only static inspection missed them. This is expected behaviour (Reviewer cannot run code) but confirms that the plan's §Verification "run the parser" step is load-bearing, not ceremonial.

**Actor scope-creep incident:** Wave 2 Actor introduced ~56 lines of out-of-scope "model enforcement" feature across `commands/{brain,duo}.md`, `docs/design.md`, and `docs/TODO.md` — a parallel feature about reading the model ID from Claude Code's system context and refusing/warning. Brain reverted all of it before invoking Reviewer. The feature itself may be worth implementing (see `docs/TODO.md` "Hook-based model enforcement via `$CLAUDE_MODEL`") but was not in the approved plan.

---

## Amendment 2026-04-30 (session 2) — status-line fixes, telemetry bug fixes, smoke test tooling

**Context:** Post-telemetry smoke-test session. Ran the first real `/duo` invocation to verify T1+T2 telemetry. Found three categories of bugs, all fixed in the same session.

### Status-line: `.duo-inflight` never written (badge regression)

**Root cause:** `commands/duo.md` had two separate Bash code blocks for setup. Block 1 created the session dir and did `export CLAUDE_ORCHESTRA_SESSION_DIR=...`. Block 2 wrote `.duo-inflight` using `${CLAUDE_ORCHESTRA_SESSION_DIR}` — but env exports do NOT persist across Bash tool calls (each tool call is a separate subprocess). The variable was empty; the write silently failed. Result: `duo_count=0` throughout planning → no `♪ orchestra -> plan <title>` badge.

**Fix:** Merged both blocks into a single Bash call that uses the local `SESSION_DIR` shell variable for both `mkdir` and the `.duo-inflight` write. Also clarified that all subsequent Bash calls (Phase 2, Phase 4) must use the captured literal path, not `${CLAUDE_ORCHESTRA_SESSION_DIR}`.

**Secondary fix:** Moved `.duo-inflight` removal from Phase 2 (before ExitPlanMode) to Phase 4 (cleanup after Actor). This keeps the badge alive through actor execution — previously the badge and cost indicator disappeared the moment planning ended.

**Test:** Badge now confirmed working via manual simulation: inject a `.duo-inflight` under the sessions root and run the status-line script with a matching `workspace.current_dir` JSON input → `♪ orchestra -> plan <title> ~$X.YZ` shows correctly.

### Status-line: live cost display never appeared

**Root cause:** Live cost is gated on `active_session_dir` being non-empty. `active_session_dir` is only set when `duo_count > 0` (`.duo-inflight` found) or `orch_title` non-empty (brain session active). Since `.duo-inflight` was never written (see above), `duo_count` was always 0 for /duo → `active_session_dir` empty → `live_cost` never computed.

**Root cause 2 (also fixed):** The earlier live-cost implementation read token counts from `telemetry-events.jsonl` (T1 hook events). Those events always have `usage=null` because Claude Code's `PreToolUse(Agent)` / `SubagentStop` hook payloads don't expose token counts. Fixed: switched to using `$tokens_used` from the Claude Code status-line input JSON (always available, already parsed by the host script).

### T2 cost always $0.00

Two bugs in `scripts/telemetry-summarize.py`:

1. **`<synthetic>` model**: Claude Code's `/compact` command writes a summary message with `"model": "<synthetic>"` to the parent JSONL transcript. The T2 parser was picking this up as the parent model. `<synthetic>` is not in `pricing.yaml` → parent tokens (potentially millions of cache reads) priced at $0. **Fix:** `_walk_jsonl_for_tokens()` now skips `<synthetic>` for model attribution; the last real model seen is used instead.

2. **Versioned model ID mismatch**: Claude Code's JSONL uses full versioned IDs (`claude-haiku-4-5-20251001`, `claude-sonnet-4-5-20250929`) but `pricing.yaml` uses base names (`claude-haiku-4-5`, `claude-sonnet-4-6`). Exact-string lookup always missed → all subagent costs $0. **Fix:** Added `_normalize_model_id()` helper that strips trailing `-YYYYMMDD` date suffix before pricing table lookup.

3. **`cross_check_t1_t2()` crash on null usage**: `usage` field in T1 events is JSON `null`; the function called `.values()` on it → `AttributeError`. **Fix:** `usage = event.get("usage") or {}`. Also fixed field name: T1 events use `"subagent"` key, not `"subagent_type"`.

### Deploy junk accumulation

`status-line/orchestra-block.sh` header had a comment containing `# ORCHESTRA_BLOCK_START` as a substring (`# (presence sentinel: # ORCHESTRA_BLOCK_START). Manual install: source or`). The deploy awk strip anchors on `^# ORCHESTRA_BLOCK_START` (correct), so this comment line was left behind each deploy and re-added by the new inject → 22 copies after repeated deploys.

**Fix:**
- Removed the "presence sentinel" comment lines from `orchestra-block.sh` header.
- Extended deploy.sh awk strip to also skip lines containing `ORCHESTRA_BLOCK_START` that don't start with it (accumulated junk from prior deploys).
- Re-ran `./deploy.sh` which cleaned all 22 copies in the deployed `status-line.sh`.

### Smoke test tooling

Added `scripts/smoke-test.sh`: a verification script that checks T1 events, T2 telemetry.json, and the global log for the most recent session. Exit 0 if all three checks pass. Used for post-/duo and post-/brain verification. Added `## Telemetry Smoke Tests` procedure to `CLAUDE.md`. (See commit 88f5cd3.)

Also fixed `scripts/telemetry-summarize.py` to skip global-log append if session already present (prevents duplicate entries when T2 is re-run for debugging). `scripts/smoke-test.sh` global-log check uses `tail -1` on the grep output to handle multiple entries gracefully.

### Verification (2026-04-30 session 2)

End-to-end `/duo` smoke test passed after all fixes applied (commit 66c8a43):

- Session `20260430T165550Z-1501376`, `claude-sonnet-4-6`, 65s, outcome=pass.
- T1: 2 events (actor start + end), usage=null (timing-only — expected).
- T2: `cost=$0.2744`, `total_tokens=460,098`, `parent_model=claude-sonnet-4-6`, `subagents=['actor']`. Model ID normalization confirmed working (no $0 cost).
- Global log: ✓ session present.
- `./scripts/smoke-test.sh`: 3/3 checks passed.
- T1/T2 delta warning (`T1=0 T2=135,431`) is expected; documented as known behaviour (T1 usage always null).
- `end | unknown` subagent on the T1 end event: pre-existing limitation (SubagentStop payload does not expose subagent type); not a bug.

---

## Amendment 2026-04-30 (session 3) — /brain smoke test + additional fixes

**Context:** /brain smoke test revealed three issues; two fixed in this session.

### Cost not shown during actor/reviewer phases

`tokens_used` in the status-line script is derived from `used_percentage` in Claude Code's status-line input JSON. Claude Code reports `used_percentage=0` while a subagent is running (the parent context isn't the active turn), so `tokens_used=0` and the live cost gate `[ "${tokens_used:-0}" -gt 0 ]` fails — cost blanked out during actor/reviewer execution despite being visible during Phase 0/1.

**Fix:** Added a `.live-cost-cache` file in the session dir. When `tokens_used>0`, the computed cost is written there. When `tokens_used=0` but the session is active, the cached value is read back. Result: cost persists through subagent execution showing the last known value from the parent's most recent turn.

### Global log stale outcome (stop hook vs cleanup race)

The `Stop` hook fires when the Claude Code session ends (including mid-session interruptions at approval prompts). If it fires before Brain's cleanup, it writes `outcome=abandoned` to `telemetry.jsonl`. Brain's cleanup then runs T2 with the correct outcome but the old duplicate guard skipped the append, leaving the stale entry.

**Fix:** Global log append now replaces the existing line (atomic rename) rather than skipping. The last T2 run for a session is authoritative.

### T1 events missing for actor/reviewer (one-off, not fixed)

In the previous smoke test session, a Stop hook fire between Phase 1 and Phase 2 wrote `telemetry.json` with `outcome=abandoned`. `find_active_session_dir()` skips dirs with `telemetry.json`, so subsequent actor/reviewer PreToolUse events weren't captured in T1. This was a one-off from the CLAUDE_PROJECT_DIR recovery session. In a normal session the Stop hook only fires at true session end.

### /brain smoke test verified (session 20260430T173441Z-1527612)

- T1: 6 events (planner start/end + actor start/end + reviewer start/end) ✓
- T2: `cost=$0.9107`, `total_tokens=1,929,950`, `subagents=['actor','planner','reviewer']`, `outcome=pass` ✓
- Global log: `outcome=pass` ✓
- `./scripts/smoke-test.sh`: 3/3 ✓
- Cost displayed throughout all stages including during actor/reviewer execution ✓

**Known cosmetic issue:** `subagents[]` in T2 output is ordered alphabetically by transcript filename hash, not by execution order. Costs and tokens are attributed correctly; display order only.

### Root cause: CLAUDE_PROJECT_DIR unset in Bash subprocesses

Fixed in commit eb0dd0c: `CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"` added as first line of every bash block in `brain.md` and `duo.md` that uses this variable. Without this, all session dir creation and badge writes silently failed.

---

## Amendment 2026-05-04 — Cross-project telemetry fix (zero-cost bug)

**Context:** Two consecutive `/duo` sessions (2026-05-01 and 2026-05-04) reported `$0.0` cost and 0 tokens in `telemetry-report.sh --last 5` despite real work. Investigation session `troubleshoot-telemetry-2026-05-04--13-37`.

### Root cause

Orchestra is deployed globally (`~/.claude/`) so `/duo` and `/brain` can be invoked from **any** project. When invoked from a non-orchestra project, the session JSONL is stored in a different `~/.claude/projects/<mangled-path>/` directory:

- 2026-05-01 session: invoked from `/mnt/nfs/Florian/Gin-AI` → transcript at `~/.claude/projects/-mnt-nfs-Florian-Gin-AI/6fca7323-...jsonl`
- 2026-05-04 session: invoked from `SoHoAI` project → transcript at `~/.claude/projects/-mnt-nfs-Florian-Gin-AI-projects-SoHoAI/581129aa-...jsonl`

`telemetry-summarize.py`'s `get_transcript_path()` had the orchestra project path (`-mnt-nfs-Florian-Gin-AI-projects-claude-orchestra`) hardcoded as the only search location. When no transcript was found there, it fell back to the most-recently-modified JSONL in that directory — which had zero messages within the session's time window — yielding `$0.0` and 0 tokens.

Confirming evidence: T1 events in both sessions show `"session":"unknown"`, confirming that `CLAUDE_SESSION_ID` is not set by Claude Code in subprocess environments (consistent with design-history note from 2026-04-30). `CLAUDE_PROJECT_DIR` **is** reliably set (proven by correct `ORCHESTRA_DIR` paths in `invocations.log` logfile entries).

### Fix

Three changes:

1. **`scripts/telemetry-summarize.py`** — `get_transcript_path()` now computes the transcripts directory dynamically from `os.environ.get("CLAUDE_PROJECT_DIR")`, mangling the path the same way Claude Code does (`/` → `-`). The hardcoded orchestra path is kept as a legacy fallback when `CLAUDE_PROJECT_DIR` is unset.

2. **`commands/duo.md` + `commands/brain.md`** — Phase 0 setup block now captures the most-recently-modified JSONL UUID immediately after `mkdir -p "${SESSION_DIR}"` and stores it in `${SESSION_DIR}/.transcript-uuid`. Phase 4 cleanup reads this UUID and passes it to `telemetry-summarize.sh` instead of relying on `${CLAUDE_SESSION_ID:-}` (which is always empty). This belt-and-suspenders measure guards against the "most recently modified" heuristic picking the wrong file when multiple sessions are active concurrently.

3. **`scripts/telemetry-summarize.sh`** — Added a fallback that reads `.transcript-uuid` from the session dir if the 4th argument is empty and `CLAUDE_SESSION_ID` is unset.

### Retroactive fix

Re-ran `telemetry-summarize.sh` for both broken sessions with the correct `CLAUDE_PROJECT_DIR` and transcript UUIDs:
- 2026-05-01: `$0.0 → $3.64` (136 messages in window; parent Sonnet + Explore + actor Haiku)
- 2026-05-04: `$0.0 → $3.90` (99 messages in window; parent Sonnet + actor Haiku)

Note: retroactive re-runs set `ended_at = time.time()` (the re-run time), so `duration_s` is inflated for those two entries in the global log.

### Follow-up fix — commit e1cd45e

During smoke-test validation a second gap was found: the UUID captured in `.transcript-uuid` was passed to `get_transcript_path(uuid)`, which still resolved the JSONL path against the hardcoded legacy transcripts directory. UUID correct + wrong directory = file not found, so cross-project sessions would still report `$0.0`.

**Root cause of the gap:** `CLAUDE_PROJECT_DIR` is set by Claude Code when hooks run (confirmed by correct `ORCHESTRA_DIR` in logfile paths) but is **not** inherited by Bash tool call subprocesses (confirmed: `echo $CLAUDE_PROJECT_DIR` in a Bash tool call returns empty). The `CLAUDE_PROJECT_DIR`-based lookup in `get_transcript_path()` therefore never fires. The `$(pwd)` fallback in the setup block gives the local path (`/home/florian/Gin-AI/projects/…`), which has no corresponding entry in `~/.claude/projects/`, so `.transcript-uuid` capture also fails for sessions opened via the local-path representation of an NFS project.

**Fix:** store the **full JSONL path** (not just the UUID) in `${SESSION_DIR}/.transcript-path` at session-dir creation time. The path is obtained from `ls -t ${_TRANSCRIPTS}/*.jsonl | head -1` — the same `ls` call that was already finding the UUID — so it costs nothing extra. `telemetry-summarize.py` now checks `.transcript-path` first; if the stored path exists on disk it is used directly, bypassing all directory-lookup logic. The UUID/`CLAUDE_PROJECT_DIR`/legacy chain is retained as a fallback for the `stop`-hook path and any session dir that pre-dates this change.

**Why this works for cross-project sessions:** when a session is opened from an NFS path (e.g. `/mnt/nfs/Florian/Gin-AI/projects/SoHoAI`), `$(pwd)` in the Bash tool returns that same NFS path, the mangled dir `-mnt-nfs-Florian-Gin-AI-projects-SoHoAI` exists in `~/.claude/projects/`, and the full JSONL path is stored. The summarizer reads it directly at cleanup — no env-var propagation needed.

**Smoke test (commit e1cd45e):** `/duo` session `20260504T121034Z-467037` — 3/3 checks passed, `cost=$0.4975`, `parent_model=claude-sonnet-4-6`, `subagents=['actor']`.

### Hook-based capture + global project scan — commit 35c4887

A third session (`20260504T162149Z-614723`, SoHoAI project, host `um690`) reported `$0.0` despite the previous fix. Investigation: `.transcript-path` and `.transcript-uuid` were **absent** from the session dir (not just empty), meaning the `printf` writes in the setup block silently failed. The `get_transcript_path()` fallback then picked `721bd06d-...` (wrong JSONL) via the hardcoded legacy path.

Two further fixes:

1. **`orchestra-hook.sh` `start` handler** — on first subagent dispatch, write `.transcript-path` and `.transcript-uuid` to the active session dir using `PROJECT_DIR` (derived from `CLAUDE_PROJECT_DIR` in the hook environment, where it is reliably set). Guard: only writes if `.transcript-path` is not already present. This captures the correct transcript even when the setup block's write fails.

2. **`telemetry-summarize.py` `get_transcript_path()`** — replaced the single-dir lookup (CLAUDE_PROJECT_DIR env var + hardcoded fallback) with a scan of **all** `~/.claude/projects/*/` subdirectories. When a UUID is given, returns the first match across all project dirs (exact, path-form-agnostic). When no UUID is given, returns the most-recently-modified JSONL across all projects. Hardcoded path removed entirely.

**Smoke test (commit 35c4887):** SoHoAI session `20260504T190717Z-718012` on `um690` — `.transcript-path` written by the hook with correct NFS-path form, `cost=$1.0682`, 3/3 checks passed.

### realpath normalization — commit 0b5a307

Root cause of the setup-block write failures: `$(pwd)` gives the logical path (e.g. `/home/florian/Gin-AI/projects/SoHoAI` via a local symlink) while Claude Code stores JSONLs under the physical NFS path (e.g. `/mnt/nfs/Florian/Gin-AI/projects/SoHoAI`). The mangled dir from the logical path does not exist in `~/.claude/projects/`, so `ls -t` returns nothing, `_LATEST` is empty, and the `printf` inside the `if [ -n "$_LATEST" ]` guard is never reached. The unconditional `.transcript-uuid` write also silently fails when `SESSION_DIR` resolves to an NFS path that is inaccessible under the logical form on that machine.

Fix: normalize all three places that compute a project path with `realpath` before use:

- `scripts/orchestra-hook.sh` line 35: `PROJECT_DIR`
- `commands/duo.md` setup block: `CLAUDE_PROJECT_DIR`
- `commands/brain.md` setup block: `CLAUDE_PROJECT_DIR`

`realpath` resolves symlinks to the physical path. Since all machines share the same NFS mount point, `realpath` of either path form converges to the same NFS physical path, ensuring the mangled dir name always matches what Claude Code used for JSONL storage. The `2>/dev/null || echo ...` fallback preserves behaviour when `realpath` is unavailable.
