---
title: "Claude Orchestra — Resources consulted & disregarded references"
date: 2026-04-28
created_by: Claude Code (Claude Haiku 4.5)
context: >
  Extract from the design.md reference document, capturing the resources and
  external references that informed the Orchestra architecture design, as well
  as third-party claims that were explicitly evaluated and rejected.
---

# Resources & References

## Resources consulted

| Source | Location | Role in the design |
|---|---|---|
| Longform Guide — *"Everything Claude Code"* by affaan-m | `https://github.com/affaan-m/everything-claude-code/blob/main/the-longform-guide.md` | Source of the Sequential Phase Architecture (RESEARCH → PLAN → IMPLEMENT → REVIEW → VERIFY), model-tier assignments (Opus/Sonnet/Haiku), single-input/output-per-agent discipline, and "minimum viable parallelization" guidance. Community resource — not Anthropic canon. |
| Gemini discussion | `/var/tmp/gemini-chat.md` (local copy — original share URL blocked by consent redirect) | Confirmed that `.claude/agents/*.md` with `model:` frontmatter is the real primitive; validated cascade method (multiple `claude --model …` processes); validated handover-via-file pattern. Parts claiming "Agent Teams" / `teammateMode` / auto-spawning panes are explicitly disregarded (not real Claude Code features). |
| Claude Code usage report | `/mnt/nfs/Florian/Gin-AI/.claude/usage-data/report.html` (680 messages, 72 sessions, 2026-03-25 → 2026-04-24) | Provided usage context; specifically recommended trying "parallel multi-agent benchmark sweeps with a coordinator aggregating a decision matrix" — direct motivation for this work. |
| HomeAI project instructions | `/mnt/nfs/Florian/Gin-AI/projects/HomeAI/CLAUDE.md` | NFS-safety conventions (passive files OK on NFS, RocksDB/SQLite NOT OK), Python venv location, documentation metadata convention. |
| Global Claude Code rules | `~/.claude/CLAUDE.md` | "Never commit unless asked" — bounded the autonomy design. |
| Claude Code native primitives (documented) | — | Subagents (`.claude/agents/*.md`), hooks (`PreToolUse`, `SubagentStop`, `PreCompact`), permission modes (`default` / `acceptEdits` / `plan` / `bypassPermissions`), slash commands, `ExitPlanMode` tool. |

## Gemini-sourced material explicitly disregarded

These were claimed as Claude Code features in the Gemini discussion but are not real; the design does **not** depend on them:

- "Agent Teams" feature.
- `teammateMode` setting or `CLAUDE_CODE_TEAMMATE_MODE` env var.
- Automatic tmux pane spawning per spawned teammate.
- `SessionStart` hook that moves a subagent pane to a new window.
- "PrimeLine tools" / a bundled `spawn-worker.sh` ecosystem script.
- `CLAUDE_CODE_SUBAGENT_MODEL` env var as a global default for subagent models.
