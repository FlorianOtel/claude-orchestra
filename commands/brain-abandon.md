---
description: Mark a /brain run as abandoned. Requires explicit slug or unique prefix. Use after a research dialogue dead-ends with no plan to be made.
---

# /brain-abandon — mark a run as abandoned

Argument is the run **slug** (or any unambiguous prefix). Mandatory — never guess
which run the user means.

If `$ARGUMENTS` is empty, refuse and tell the user to specify a slug. Suggest they
run `/brain-status` to see active runs.

If `$ARGUMENTS` matches multiple slugs by prefix, refuse and list the candidates.
Tell the user to be more specific.

Otherwise:

1. Resolve the slug via:
   ```bash
   RUN_ID=$(~/.claude/scripts/runs-registry.sh resolve "$ARGUMENTS")
   ```
   If exit code is non-zero, the registry helper has already printed an error to
   stderr; surface that to the user verbatim and stop.

2. If a tmux window with the slug exists, ask the user once: "A live window for this
   run exists (window `<slug>`). Kill it as well as marking abandoned? [y/N]". On
   `y`, run `tmux kill-window -t "<slug>"`. On anything else, leave the window alone.
   (For VSCode/manual runs there's no window to kill — skip this step.)

3. Append the abandonment event to the registry:
   ```bash
   ~/.claude/scripts/runs-registry.sh transition "$RUN_ID" "abandoned" "user request via /brain-abandon"
   ```

4. Print confirmation: "Run `<slug>` marked abandoned." Note the run's state directory
   (`.claude/orchestra/runs/<run_id>/`) is preserved on disk for forensic review;
   user can manually delete if they want.

If the user said "abandon all" rather than a slug, instead:

1. Run `~/.claude/scripts/runs-registry.sh count-active` to get N.
2. List the active runs (`runs-registry.sh list`, filter to active states).
3. Ask the user: "Abandon all `<N>` active runs? [y/N]". Require explicit `y`/`yes`.
4. On confirmation, loop and transition each to `abandoned`. Don't auto-kill windows
   in bulk; just mark abandoned.

$ARGUMENTS
