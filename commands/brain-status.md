---
description: List all /brain runs (active, awaiting resume, done, abandoned) with state and age. Read-only.
---

# /brain-status — list /brain runs

Print a human-readable table of every `/brain` run registered for this project.

Read the registry by running:
```bash
~/.claude/scripts/runs-registry.sh list
```

Show the full output to the user. Annotate each run with what action is available:

- `start` or `researching` — Phase 0 dialogue in flight; ask user to switch to that
  window/terminal or `/brain-abandon <slug>` if abandoned
- `research_complete` — RESEARCH.md ready; user can `/brain-resume <slug>` to continue
- `plan_dispatched`, `planning`, `implementing`, `reviewing` — pipeline running
- `done` — completed
- `abandoned`, `error` — terminal, no action needed

Also note the current count of active runs (states other than `done`/`abandoned`/
`error`):
```bash
~/.claude/scripts/runs-registry.sh count-active
```

Keep the response compact. No actions are taken; this is purely informational.

$ARGUMENTS
