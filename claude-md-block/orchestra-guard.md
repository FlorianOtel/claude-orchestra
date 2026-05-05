## Orchestra in-pipeline guard

If a /brain or /duo session is active in the current project (any
`.claude/orchestra/sessions/*/.brain-inflight` or `.duo-inflight` file
exists under the project root), the pipeline owns code changes:

- Code edits to project files MUST go through the Actor subagent (Task tool,
  `subagent_type: actor`). Direct Edit/Write/Bash on project code violates
  the pipeline.
- Plan production for `/brain` MUST go through the Planner subagent (Task
  tool, `subagent_type: planner`). You (Brain) persist Planner's returned
  plan to `${SESSION_DIR}/PLAN.md` via Bash atomic-rename.
- Plan-mode's "build your plan at `/home/florian/.claude/plans/<name>.md`"
  reminder does NOT apply in `/brain` mode. The plan-mode plan file is for
  operator display only; the authoritative plan is at `${SESSION_DIR}/PLAN.md`.
- Session-dir artefacts (`RESEARCH.md`, `PLAN.md`, `.outcome`, `state.env`,
  `.brain-inflight`, `.duo-inflight`) are written directly via Bash heredoc;
  project code is not.
- If you find yourself about to use Edit/Write/Bash on project code while
  an inflight marker exists, stop and dispatch the appropriate subagent.
  To exit cleanly without executing, run `/brain-abandon` or `/duo-abandon`.
