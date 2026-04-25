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

    # /brain run self-identification: env-first, registry fallback.
    #
    # BRANCH A — spawned window (CLAUDE_BRAIN_RUN_ID present in env):
    #   start-research.sh exports CLAUDE_BRAIN_RUN_ID via `tmux new-window -e`.
    #   Derive slug directly from the env var; no cwd or registry dependency.
    #   Truncation: first 30 chars of slug component, no ellipsis.
    if [ -n "${CLAUDE_BRAIN_RUN_ID:-}" ]; then
        _sl_slug="${CLAUDE_BRAIN_RUN_ID#*Z-}"
        orchestra_display="orchestra - brain $(printf '%s' "${_sl_slug:0:30}")"
    else
    # BRANCH B — launcher chat panel (no CLAUDE_BRAIN_RUN_ID in env):
    #   Registry-driven display; preset fallback when no runs are active.

    # Preset (fallback to "default" when state.env is missing or unset)
    orchestra_mode="default"
    if [ -f "$cwd/.claude/orchestra/state.env" ]; then
        last_mode=$(grep -E '^ORCHESTRA_MODE=' "$cwd/.claude/orchestra/state.env" 2>/dev/null | tail -n 1 | cut -d= -f2)
        [ -n "$last_mode" ] && orchestra_mode="$last_mode"
    fi

    # /brain registry-driven display override:
    #   0 active runs : show state.env mode (default / duo / acceptEdits / …)
    #   1 active run  : "orchestra - brain <slug-trunc30>"
    #   N>1 active    : "orchestra(N)"
    # Read the registry directly to avoid a helper-script fork on the status-line hot path.
    runs_log="$cwd/.claude/orchestra/runs.jsonl"
    orchestra_display="$orchestra_mode"
    if [ -f "$runs_log" ]; then
        active_count=0
        single_slug=""
        while IFS= read -r rid; do
            [ -z "$rid" ] && continue
            latest=$(jq -r --arg id "$rid" 'select(.run_id==$id) | .event' "$runs_log" 2>/dev/null | tail -n 1)
            case "$latest" in
                done|abandoned|error) ;;
                *)
                    active_count=$((active_count + 1))
                    if [ "$active_count" -eq 1 ]; then
                        single_slug=$(jq -r --arg id "$rid" 'select(.run_id==$id and .event=="start") | .slug' "$runs_log" 2>/dev/null | tail -n 1)
                    fi
                    ;;
            esac
        done < <(jq -r 'select(.event=="start") | .run_id' "$runs_log" 2>/dev/null | sort -u)

        if [ "$active_count" -gt 1 ] 2>/dev/null; then
            orchestra_display="orchestra(${active_count})"
        elif [ "$active_count" -eq 1 ] 2>/dev/null; then
            orchestra_display="orchestra - brain $(printf '%s' "${single_slug:0:30}")"
        fi
    fi

    fi  # end BRANCH B

    status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET}" "$orchestra_display")

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
