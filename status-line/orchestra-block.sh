#!/usr/bin/env bash
# orchestra-block.sh — status-line additions for Claude Orchestra
#
# USAGE: source or inline this block into your ~/.claude/scripts/status-line.sh
# just before the final `echo -e "$status_line"` line.
#
# Prerequisites: the script must already have:
#   - $cwd    (from: cwd=$(echo "$input" | jq -r '.workspace.current_dir'))
#   - $tokens_used  (from your existing token-usage calculation)
#   - $status_line  (the running status string to append to)
#   - $RESET  (ANSI reset code)
#
# deploy.sh will append this block automatically if not already present.
# The presence check looks for the sentinel comment: # ORCHESTRA_BLOCK_START

# ORCHESTRA_BLOCK_START — do not remove this line; used by deploy.sh as presence sentinel

# 6. Orchestra state (shows in all projects when orchestra is globally installed)
if [ -n "$cwd" ] && [ -f "$HOME/.claude/orchestra/config.yaml" ]; then
    # Gruvbox Dark colors — added alongside your existing palette
    ORCHESTRA_COLOR="\033[38;2;211;134;155m"  # bright_purple #D3869B — distinct from all other fields
    ACTIVE_COLOR="\033[38;2;215;153;33m"      # dark yellow   #D79921
    WARNING_COLOR="\033[38;2;254;128;25m"     # bright_orange #FE8019

    # DESIGN OPTIONS (glyph choices):
    # Option 1: ♪  (U+266A eighth note) — monospace-safe, thematic ("orchestra")  ← IMPLEMENTED
    # Option 2: ⎈  (U+2388 helm symbol) — literal orchestration semantic
    # Option 3: ◈  (U+25C8 diamond with dot) — neutral geometric
    # Option 4: 🎼 (U+1F3BC musical score) — emoji, variable-width, may misalign

    # Preset (fallback to "default" when state.env is missing or unset)
    orchestra_mode="default"
    if [ -f "$cwd/.claude/orchestra/state.env" ]; then
        last_mode=$(grep -E '^ORCHESTRA_MODE=' "$cwd/.claude/orchestra/state.env" 2>/dev/null | tail -n 1 | cut -d= -f2)
        [ -n "$last_mode" ] && orchestra_mode="$last_mode"
    fi

    status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET}" "$orchestra_mode")

    # Active-subagent indicator: latest "start" event with no later matching "end"
    invlog="$cwd/.claude/orchestra/invocations.log"
    if [ -f "$invlog" ]; then
        last_start_line=$(grep '"event":"start"' "$invlog" 2>/dev/null | tail -n 1)
        last_end_line=$(grep '"event":"end"'   "$invlog" 2>/dev/null | tail -n 1)
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

    # Subagent-overflow warning: Brain context > 180K risks truncation when
    # delegating to a 200K-context subagent (Haiku Actor, Sonnet Planner/Reviewer).
    if [ "$tokens_used" -gt 180000 ]; then
        status_line+=$(printf " ${WARNING_COLOR}⚠ >200K${RESET}")
    fi
fi

# ORCHESTRA_BLOCK_END
