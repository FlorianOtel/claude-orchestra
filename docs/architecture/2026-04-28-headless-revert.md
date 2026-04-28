---
title: "Headless → Subagents revert — research note"
date: 2026-04-28
run_id: subagents-vs-headless-revisited-20260428
branch: subagents
status: implemented
supersedes: design.md "Amendment — 2026-04-26: migrate to Option A"
relates_to: docs/design.md (Amendment — 2026-04-28)
---

> This is the **versioned, permanent record** of the Phase 0 RESEARCH note for
> the run `subagents-vs-headless-revisited-20260428`. The runtime artifact at
> `.claude/orchestra/RESEARCH.md` is gitignored and may be cleaned up by
> housekeeping; this file is the source of truth for why the revert happened
> and what was decided.
>
> Read this *before* the corresponding "Amendment — 2026-04-28" in
> `docs/design.md`; the amendment is the *consequence*, this is the *reasoning*.

# Research — subagents-vs-headless-revisited-20260428

**Run identifier:** `subagents-vs-headless-revisited-20260428`
**Branch:** `subagents` (local; branched from `headless-claude` at `af9822d`)
**Date:** 2026-04-28
**Operator request:** *"I want to streamline the design and architecture"*

## Goal

Streamline the claude-orchestra design and architecture by **abandoning the
headless `claude -p` execution model in favor of canonical Claude Code
subagents**, preserving multi-tier model routing for cost discipline while
removing structural complexity that was introduced in commit `98543c0`
("switch from subagents to headless claude sessions") under a partial
misreading of subagent capabilities.

The architectural target is the **idiomatic hub-and-spoke pattern**: a single
orchestrator (Brain, the operator's main Claude Code session) dispatches to
flat sibling specialists (Planner, Actor, Reviewer), each pinned to its own
cost tier. One level of delegation depth, not nested.

## Approach decided

**Revert to subagent execution model on a new `subagents` branch.**

Concretely:

- **Brain** = the operator's main Claude Code session. Orchestrates the
  pipeline. Runs on Sonnet 4.6 minimum / Opus 4.7 recommended for `/brain`,
  Sonnet 4.6 for `/duo`. The operator chooses the model before invoking
  the slash command; Brain's model is not auto-pinned by the framework.
- **Planner** subagent (Sonnet 4.6, read-only) — produces `PLAN.md`.
- **Actor** subagent (Haiku 4.5, read+write) — implements one or more
  approved steps; reports back with diff and `ready_for_review | blocked |
  partial` status signal.
- **Reviewer** subagent (Sonnet 4.6, read-only) — reviews after Actor;
  pass/fail with minimal-fix list.
- **Phase 0 RESEARCH** absorbed by Brain itself — no separate session, no
  separate process, no `Researcher` subagent. Brain wears the
  critical-stance interrogation posture for Phase 0 via its system prompt
  in `commands/brain.md`.

**Permission flow** (canonical Plan-Then-Execute, no escalation tricks):

1. Operator runs `/brain` from a session in **plan mode** (Shift+Tab).
2. Brain runs Phase 0 RESEARCH inline — interrogation, alternatives, scope
   fencing — using read-only tools (enforced by parent plan mode).
3. Operator approves the research conclusion → Brain delegates to Planner.
4. Planner returns `PLAN.md`; operator reviews and approves.
5. Brain calls `ExitPlanMode` → standard Claude Code "auto-edit / manually
   approve / cancel" prompt fires at the parent.
6. Brain delegates to Actor → Actor's tool calls go through the
   permission posture the operator just chose.
7. Brain delegates to Reviewer → pass/fail.

Subagent `permissionMode` frontmatter is used only to **narrow** (Planner
read-only by frontmatter), never to widen. The bypass-flattens-down caveat
(parent's `--dangerously-skip-permissions` overrides children) is documented
prominently as a known constraint.

**Parallel runs** are supported by per-session subdirectories
(`.claude/orchestra/sessions/<session-id>/PLAN.md`, `TASKS.json`).
Two `/brain` invocations on the same project from separate Claude Code
sessions no longer collide. Lazy cleanup via `find -mtime +30` at `/brain`
start; retention window configurable in `config/config.yaml`.

**`/duo`** re-skins to subagent dispatch: Planner subagent + Actor subagent,
no Reviewer, same plan-mode → ExitPlanMode flow.

**`/brain`** re-skins to inline Phase 0 + Planner → Actor → Reviewer dispatch.

## Rejected alternatives

- **Status quo (headless `claude -p`).** Kludgy, non-idiomatic, plausibly
  *more* expensive than subagents because every invocation cold-starts a new
  process and defeats parent-prompt-cache warm reads (PDF: 90% of subagent
  token cost is cache reads at ~$0.50/MTok on Opus). Requires ~700 lines of
  bespoke registry / tmux / launcher / format-stream plumbing.
- **Agent Teams.** Verified via `code.claude.com/docs/en/agent-teams`:
  also 1-level deep (lead + flat teammates), still token-expensive (~15× per
  PDF), adds cross-teammate messaging we explicitly don't need, currently
  experimental with documented cleanup issues. Doesn't solve any problem
  subagents don't already solve.
- **Keep multi-tier delegation depth via headless.** False premise. Headless
  never gave us nested delegation; every `claude -p` was already a flat
  sibling spawned by Brain. We paid the complexity tax for capabilities we
  were not, in fact, getting.
- **Keep `agents/researcher.md` as opt-in subagent.** Five of the six
  original rationales for separating Researcher from Brain are disavowed by
  current decisions (different model, clean context, concurrency, cross-day
  resumability, token-cost-stays-out-of-main); the sixth (critical-stance
  posture) is just system-prompt text and moves into `commands/brain.md`.
  Keeping `researcher.md` would leave a 159-line file that nothing invokes.
- **Enable `memory:` field in v1.** Marginal cost benefit at best (CLAUDE.md
  already auto-injects project conventions into subagents); negative
  simplicity impact (new artifact category, stale-memory failure mode,
  cross-project pollution risk for `memory: user`); two mechanisms for the
  same job (PLAN.md/TASKS.json artifacts already do cross-invocation
  handoff). Defer to v2 with documented trigger condition.
- **Maintain `/orchestra-mode` preset command.** The operator did not
  remember the command exists. That alone is sufficient evidence it is not
  earning its slot. Delete.
- **Maintain `/brain-resume`, `/brain-abandon`, `/brain-status`.** All three
  exist solely to navigate the multi-run registry, which is itself being
  deleted. With inline + synchronous `/brain`, "resume" is "stay in the
  session and keep talking" and "abandon" is "type something else." Delete.

## Scope

### In scope

**Architectural changes:**

- Rewrite `commands/brain.md` to absorb Phase 0 RESEARCH inline and
  dispatch Planner → Actor → Reviewer as canonical subagents (Task tool
  invocations).
- Rewrite `commands/duo.md` to dispatch Planner + Actor as canonical
  subagents.
- Update `agents/planner.md`, `agents/actor.md`, `agents/reviewer.md`
  frontmatter and bodies as needed to match canonical subagent invocation
  semantics. Existing `model:` fields are kept (Planner: Sonnet 4.6;
  Actor: Haiku 4.5; Reviewer: Sonnet 4.6).
- Switch artifact paths from flat `.claude/orchestra/PLAN.md` to per-session
  `.claude/orchestra/sessions/<session-id>/PLAN.md` (and `TASKS.json`,
  `RESEARCH.md`).
- Add lazy housekeeping: `find -mtime +30` cleanup at `/brain` start; new
  config knob `housekeeping.session_retention_days: 30` in
  `config/config.yaml`.
- Document the bypass-flattens-down caveat prominently in `docs/design.md`
  and in `commands/brain.md` prerequisites.
- Rewrite relevant sections of `docs/design.md` to reflect the new
  architecture; preserve §13 (or equivalent) as a record of why the
  headless detour was attempted and abandoned.
- Document the deferred `memory:` feature with a concrete trigger condition.

**Deletions:**

- `agents/researcher.md`
- `commands/orchestra-mode.md`
- `commands/brain-resume.md`
- `commands/brain-abandon.md`
- `commands/brain-status.md`
- `scripts/start-research.sh`
- `scripts/runs-registry.sh`
- `scripts/run-tier.sh`
- `scripts/format-stream.sh`
- Headless-specific dispatch logic in `scripts/orchestra-hook.sh`
  (PreToolUse may survive if it serves purposes orthogonal to headless;
  SubagentStop and PreCompact handlers wrapping headless workflow go).
- Live-feed / multi-window status-line plumbing tied to headless runs
  (specific files identified in PLAN).
- `.vscode/tasks.json` entries that invoke the headless launcher.

### Out of scope (hard fence)

- Adding any new agent beyond Planner / Actor / Reviewer (e.g., a future
  `Explorer` for parallel codebase investigation per PDF's domain-routing
  pattern). Brain's own Read/Grep/Glob is treated as sufficient for v1.
- Enabling the `memory:` frontmatter field on any subagent.
- Any change to the `./deploy.sh` / `./collect.sh` cycle or the `~/.claude/`
  deploy target. Deploy mechanism stays as-is.
- Cross-project or cross-machine state synchronization. Project-local is
  sufficient.
- A `/brain --mode auto` overnight unattended run with test gate and branch
  isolation. Defer indefinitely.
- Replacing or rearchitecting CLAUDE.md / project-config conventions.
- Merging the new `subagents` branch into `main`. That is a separate
  operator decision after this work lands.
- Cleaning up stale remote branches (`origin/headless-caude` typo branch,
  `origin/headless-claude`, `origin/sub-agents`). Defer.

## Constraints / risks

1. **Bypass-flattens-down caveat.** If the operator launches the parent
   session with `--dangerously-skip-permissions`, all subagent
   `permissionMode` frontmatter is silently overridden. Must be documented
   prominently. Mitigation: `commands/brain.md` prerequisites instruct
   operator to launch from a non-bypass session.
2. **CLAUDE.md inheritance into subagents.** Assumed yes (canonical Claude
   Code behavior), but not empirically verified for the Claude Code version
   we are running. **PLAN must include a sanity check** before we rely on
   it. If the assumption fails, agent `.md` bodies need explicit
   re-injection of project conventions.
3. **Cache warmth assumption.** The PDF's claim that ~90% of subagent token
   cost is cache reads holds for *long warm sessions*. Short-lived sessions
   pay closer to the nominal 4–7× multiplier. Real cost behavior on the
   actual claude-orchestra workload requires post-deployment measurement.
4. **Loss of live visibility into substream work.** Subagents are
   opaque-by-design; the parent transcript shows tool-use events as
   collapsed nodes but not real-time model output. Operator has
   disavowed this as an anti-goal; if the need returns, the only path back
   is the headless approach we are deleting.
5. **Loss of cross-day resumability.** `/brain-resume` is being deleted.
   If a `/brain` run is interrupted mid-flight, the operator stays in the
   same session to continue or re-runs from scratch. No registry to consult.
6. **Per-session subdir + cleanup race.** A `find -mtime +30` cleanup running
   at `/brain` start could in principle delete a subdir whose owning session
   is still active (if a session has been idle for 30 days and is then
   resumed). Mitigation options: (a) accept the constraint and document it;
   (b) skip cleanup if any subdir has been touched in the current calendar
   day. Resolved in PLAN; current preference is (a).
7. **Existing `origin/sub-agents` remote branch.** Pre-headless snapshot
   from `84842ec`, hyphenated name. Untouched by this work. Will need
   operator decision after the new architecture lands about
   merge/delete/rename.

## Open questions

Resolved during PLAN (mechanical):

- Empirical verification that CLAUDE.md auto-injects into subagent system
  prompts in our Claude Code version.
- Whether `permissionMode` frontmatter on Actor/Planner/Reviewer is needed
  given that the parent always sets the effective gate (recommended: omit
  the field, rely on parent state).
- Specific list of headless-related lines in `scripts/orchestra-hook.sh`
  to remove vs. preserve.
- Specific status-line files / blocks tied to headless live-feed UX.
- Migration path for any in-flight `.claude/orchestra/runs/<id>/` artifacts
  on operator machines (probably: delete on first deploy of new code).

Deferred to v2:

- `Explorer` subagent for parallel codebase investigation.
- `memory:` field opt-in, with a refined trigger condition once telemetry
  exists.
- A test-gate / overnight `/brain --mode auto` workflow.
- Cleanup of stale remote branches.

Operator-only:

- Whether the new `subagents` branch eventually merges to `main` or replaces
  `main`.
- Disposition of `origin/sub-agents` and `origin/headless-claude` after
  merge.
