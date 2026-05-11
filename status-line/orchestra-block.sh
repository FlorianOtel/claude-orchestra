#!/usr/bin/env bash
# orchestra-block.sh — status-line additions for Claude Orchestra (subagents)
#
# USAGE: deploy.sh injects this block into ~/.claude/scripts/status-line.sh
# just before the final `echo -e "$status_line"` line.
#
# Prerequisites — the host script must already have:
#   - $cwd          (from: cwd=$(echo "$input" | jq -r '.workspace.current_dir'))
#   - $tokens_used  (from your existing token-usage calculation)
#   - $status_line  (the running status string to append to)
#   - $RESET        (ANSI reset code)
#   - $input        (JSON for model_id extraction via jq)
#   - $used_percentage (Ctx segment: fill percentage 0-100)
#   - $context_window_size (Ctx segment: model's context window in tokens)

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

    # --- live session ID resolution (orchestra + native fallback) ---
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

    live_session_id=""
    if [ -n "$active_session_dir" ]; then
        live_session_id=$(basename "$active_session_dir")
    fi
    # Native session fallback (when no orchestra session active)
    if [ -z "$live_session_id" ] && [ -d "$HOME/.claude/active-sessions" ]; then
        for lck in "$HOME/.claude/active-sessions/native-"*.lck; do
            [ -f "$lck" ] || continue
            lck_pid=$(grep '^cc_pid=' "$lck" 2>/dev/null | cut -d= -f2-)
            if [ -n "$lck_pid" ] && kill -0 "$lck_pid" 2>/dev/null; then
                live_session_id=$(basename "$lck" .lck)
                break
            fi
        done
    fi

    # --- ctx segment (model context window + token usage bar) ---
    # $used_percentage, $tokens_used, $context_window_size are set by the host script.
    model_id=$(echo "$input" | jq -r '.model.id // .model.display_name // ""' 2>/dev/null)
    # DEBUG: uncomment to capture input JSON for troubleshooting model_id extraction
    # echo "$input" > "$HOME/.claude/orchestra/logs/status-line-input-debug.json" 2>/dev/null || true
    ctx_seg=$(~/.claude/scripts/ctx-segment.sh "${used_percentage:-0}" "${tokens_used:-0}" "${context_window_size:-200000}" "${model_id:-}" 2>/dev/null || true)
    [ -n "$ctx_seg" ] && status_line+=$(printf " | %s" "$ctx_seg")

    # --- live cost from SoHoAI (with JSONL fallback) ---
    live_cost=""
    if [ -n "$live_session_id" ] && [ -n "$active_session_dir" ]; then
        cost_cache="${active_session_dir}/.live-cost-sohoai"
        started_at=$(stat -c %Y "$active_session_dir" 2>/dev/null || echo "0")
        live_cost=$(~/.claude/scripts/sohoai-live-cost.sh \
            "$live_session_id" "$started_at" "$cost_cache" 2>/dev/null || true)
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
fi

# ORCHESTRA_BLOCK_END
