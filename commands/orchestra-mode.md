---
description: Set or display the Claude Orchestra autonomy preset (default | acceptEdits | auto). v1 stub — does not yet change Claude Code permission modes; documents v2 intent.
---

# /orchestra-mode — Orchestra autonomy preset

Parse `$ARGUMENTS` as the requested preset name. Valid values: `default`, `acceptEdits`, `auto`.

If no argument provided, show the current preset (read from `${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env`, key `ORCHESTRA_MODE`; if missing, report `default`).

## v1 behaviour

For `default` or `acceptEdits`:

1. Ensure the orchestra directory exists: `${CLAUDE_PROJECT_DIR}/.claude/orchestra/`.
2. Append `ORCHESTRA_MODE=<preset>` to `state.env` (sourced by the hook script on each invocation; later writes win).
3. Echo confirmation back to the user:
   > Orchestra preset set to `<preset>`. Note: in v1 this does NOT change Claude Code's permission mode — use `Shift+Tab` or `/permissions` for that (Axis X). The orchestra-level gate policy (Axis Y) is honored by `/brain` and the hook script on next subagent invocation.

For `auto`:

Print this message and exit without changing any state:

> `/orchestra-mode auto` is **not yet implemented in v1**. See §10.2 of `docs/design.md` in this repository for the full v2 intent. A brief summary of what `auto` will do when implemented:
>
> - Sync both Axis X (Claude Code permission mode → `bypassPermissions`) and Axis Y (gates → G2 notify, G5 cap 5, commit auto-on-branch).
> - Verify current git branch is not protected; auto-create `orchestra/auto-<UTC-ts>` if it is.
> - Arm the CROSS-CHECK stage (Brain-level read-only audit between REVIEW and FINALIZE).
> - Checkpoint-commit per iteration on the isolated branch.
> - Arm test-gate auto-detection; refuse FINALIZE on red tests.
> - Enforce iteration and token-budget caps.
> - On rail trip, write `auto-halt-<UTC-ts>.md` and halt cleanly; resumable via `/brain-resume` (also v2).
> - Never push. Never open a PR.
>
> For now, use `default` (fully interactive) or `acceptEdits` (edits auto-approve, Bash asks).

## v2 implementation note (for the future human or agent picking this up)

The preset should drive BOTH axes in one step:

- Axis X: issue a Claude Code permission-mode change (`/permissions <mode>` or record for `--permission-mode` on next agent spawn).
- Axis Y: write `state.env` keys that the hook script and `/brain` skill consult.

For `auto` specifically:

- Key new logic: the CROSS-CHECK Brain-level step inside `/brain`, reading PLAN.md/TASKS.json and auditing repo state.
- Branch isolation and checkpoint-commit are implemented inside `/brain` as explicit `Bash` tool calls.
- Test-gate detection: shell scan for `pytest`, `pnpm test`, `npm test`, `make test`, `cargo test`; project override via `orchestra/config.yaml → test_gate.command`.
- Halt-and-resume: write `orchestra/auto-halt-<ts>.md` with full context (current step, last Actor report, last Reviewer verdict, iteration counters, branch name, uncommitted diff summary) on any rail trip. `/brain-resume` reads the halt file and picks up from the checkpoint.

Do not push / open PRs from `auto` — ever. That remains explicit user action.

$ARGUMENTS
