#!/usr/bin/env bash
# orchestra-block.sh — status-line additions for Claude Orchestra (subagents)
#
# USAGE: deploy.sh appends this block to ~/.claude/scripts/status-line.sh
# (presence sentinel: # ORCHESTRA_BLOCK_START). Manual install: source or
# inline just before the final `echo -e "$status_line"` line.
#
# Prerequisites — the host script must already have:
#   - $cwd          (from: cwd=$(echo "$input" | jq -r '.workspace.current_dir'))
#   - $tokens_used  (from your existing token-usage calculation)
#   - $status_line  (the running status string to append to)
#   - $RESET        (ANSI reset code)

# ORCHESTRA_BLOCK_START — do not remove; deploy.sh uses this as presence sentinel

if [ -n "$cwd" ] && [ -f "$HOME/.claude/orchestra/config.yaml" ]; then
    # Gruvbox Dark palette additions
    ORCHESTRA_COLOR="\033[38;2;211;134;155m"  # bright_purple #D3869B
    ACTIVE_COLOR="\033[38;2;215;153;33m"      # dark yellow   #D79921
    WARNING_COLOR="\033[38;2;254;128;25m"     # bright_orange #FE8019

    # Static orchestra badge — single cue that this project has orchestra installed.
    # No multi-run registry to consult; no per-mode sub-badge ("duo"/"acceptEdits"
    # state.env tracking is gone with the headless plumbing).
    status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ orchestra${RESET}")

    # Active-subagent indicator: latest "start" event in invocations.log with no
    # later matching "end". orchestra-hook.sh writes both events (PreToolUse(Agent)
    # = start, SubagentStop = end). Visible while a Planner/Actor/Reviewer is running.
    invlog="$cwd/.claude/orchestra/invocations.log"
    if [ -f "$invlog" ]; then
        last_start_line=$(grep '"event":"start"' "$invlog" 2>/dev/null | tail -n 1)
        last_end_line=$(grep   '"event":"end"'   "$invlog" 2>/dev/null | tail -n 1)
        if [ -n "$last_start_line" ]; then
            IFS=$'\t' read -r last_start_ts active_stage active_subagent < <(
                echo "$last_start_line" | jq -r '[.ts // "", .stage // "", .subagent // ""] | @tsv'
            )
            last_end_ts=$(echo "$last_end_line" | jq -r '.ts // ""')
            if [ -n "$last_start_ts" ] && [ "$last_start_ts" \> "${last_end_ts:-}" ]; then
                case "$active_subagent" in
                    planner|reviewer) tier="Sonnet" ;;
                    actor)            tier="Haiku"  ;;
                    *)                tier="agent"  ;;
                esac
                status_line+=$(printf " ${ACTIVE_COLOR}▶ %s:%s${RESET}" "$tier" "$active_stage")
            fi
        fi
    fi

    # Subagent context-overflow warning: Brain context >180K risks truncation
    # when delegating to a 200K-context subagent.
    if [ "$tokens_used" -gt 180000 ]; then
        status_line+=$(printf " ${WARNING_COLOR}⚠ >200K${RESET}")
    fi
fi

# ORCHESTRA_BLOCK_END
