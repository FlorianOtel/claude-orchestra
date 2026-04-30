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

    # --- /brain badge: read mode+title from state.env ---
    state_env="$cwd/.claude/orchestra/state.env"
    orch_mode="orchestra"
    orch_title=""
    if [ -f "$state_env" ]; then
        _om=$(grep '^ORCHESTRA_MODE=' "$state_env" 2>/dev/null | tail -n 1 | cut -d= -f2-)
        _ot=$(grep '^ORCHESTRA_TITLE=' "$state_env" 2>/dev/null | tail -n 1 | cut -d= -f2-)
        [ -n "$_om" ] && [ "$_om" != "default" ] && orch_mode="$_om"
        orch_title="$_ot"
    fi

    # --- /duo badge: count .duo-inflight markers across session dirs ---
    duo_count=0
    duo_title=""
    sessions_root="$cwd/.claude/orchestra/sessions"
    if [ -d "$sessions_root" ]; then
        duo_count=$(find "$sessions_root" -maxdepth 2 -name ".duo-inflight" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$duo_count" -eq 1 ]; then
            duo_title=$(find "$sessions_root" -maxdepth 2 -name ".duo-inflight" 2>/dev/null \
                        -exec cat {} \; 2>/dev/null | head -c 30)
        fi
    fi

    # --- active-subagent indicator ---
    invlog="$cwd/.claude/orchestra/invocations.log"
    active_indicator=""
    if [ -f "$invlog" ]; then
        last_start_line=$(grep '"event":"start"' "$invlog" 2>/dev/null | tail -n 1)
        last_end_line=$(grep   '"event":"end"'   "$invlog" 2>/dev/null | tail -n 1)
        if [ -n "$last_start_line" ]; then
            IFS=$'\t' read -r last_start_ts active_stage active_subagent < <(
                echo "$last_start_line" | jq -r '[.ts // "", .stage // "", .subagent // ""] | @tsv'
            )
            last_end_ts=$(echo "$last_end_line" | jq -r '.ts // ""')
            if [ -n "$last_start_ts" ] && [ "$last_start_ts" \> "${last_end_ts:-}" ]; then
                active_indicator=$(printf "${ACTIVE_COLOR}▶ %s${RESET}" "$active_stage")
            fi
        fi
    fi

    # --- live cost approximation from telemetry-events.jsonl ---
    # When a /duo or /brain session is in flight, sum tokens recorded by the
    # T1 hook and multiply by parent-tier rates from pricing.yaml.
    # Approximate; finalised by T2 at session end.
    live_cost=""
    active_session_dir=""
    if [ "$duo_count" -gt 0 ]; then
        active_session_dir=$(find "$sessions_root" -maxdepth 2 -name ".duo-inflight" 2>/dev/null \
                            | head -n 1 | xargs -r dirname)
    elif [ -n "$orch_title" ] && [ -d "$cwd/.claude/orchestra/sessions" ]; then
        active_session_dir=$(find "$cwd/.claude/orchestra/sessions" -mindepth 1 -maxdepth 1 -type d \
                              -printf '%T@ %p\n' 2>/dev/null \
                            | sort -rn | head -n 1 | cut -d' ' -f2-)
        [ -f "$active_session_dir/telemetry.json" ] && active_session_dir=""
    fi
    if [ -n "$active_session_dir" ] && [ -f "$active_session_dir/telemetry-events.jsonl" ]; then
        # Sum input + output tokens from any usage objects present.
        tok_total=$(jq -s '
            [.[] | .usage // {} | (.input_tokens // 0) + (.output_tokens // 0) +
             (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)] | add // 0
        ' "$active_session_dir/telemetry-events.jsonl" 2>/dev/null || echo 0)
        # Use Sonnet rates as a parent-tier approximation ($3 input + $15 output blend ~= $9 / 1M).
        # Coarse on purpose; T2 supersedes at session end.
        if [ "${tok_total:-0}" -gt 0 ]; then
            live_cost=$(awk -v t="$tok_total" 'BEGIN { printf "~$%.2f", t * 9 / 1000000 }')
        fi
    fi

    # --- badge rendering (priority: duo > brain > plain subagent) ---
    if [ "$duo_count" -gt 0 ]; then
        if [ "$duo_count" -eq 1 ]; then
            duo_badge="orchestra -> plan ${duo_title}"
        else
            duo_badge="orchestra -> plan #${duo_count}"
        fi
        if [ -n "$active_indicator" ]; then
            status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET} %s%s" "$duo_badge" "$active_indicator" "${live_cost:+ $live_cost}")
        else
            status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET}%s" "$duo_badge" "${live_cost:+ $live_cost}")
        fi
    elif [ -n "$orch_title" ]; then
        badge="orchestra -> brain ${orch_title}"
        if [ -n "$active_indicator" ]; then
            status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET} %s%s" "$badge" "$active_indicator" "${live_cost:+ $live_cost}")
        else
            status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET}%s" "$badge" "${live_cost:+ $live_cost}")
        fi
    elif [ -n "$active_indicator" ]; then
        status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ orchestra${RESET} %s%s" "$active_indicator" "${live_cost:+ $live_cost}")
    fi

    # Subagent context-overflow warning: Brain context >180K risks truncation
    if [ "$tokens_used" -gt 180000 ]; then
        status_line+=$(printf " ${WARNING_COLOR}⚠ >200K${RESET}")
    fi
fi

# ORCHESTRA_BLOCK_END
