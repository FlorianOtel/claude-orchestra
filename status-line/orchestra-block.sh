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

    # Strip CC-native fields 2 (20-seg bar+%) and 3 (↯ token count) — replaced by ctx+cost below.
    # Field 2: $bar is passed via %s arg to printf so BRACKET_COLOR stays as literal \033 (4 chars),
    # NOT a raw ESC byte. Use \\\\033 so bash→\\033, sed sees \\033 and matches literal \033.
    # PERCENTAGE_COLOR and RESET are in the format string → raw ESC → ${_ESC} anchor for the end.
    # Field 3: TOKEN_COLOR is in the format string → raw ESC → ${_ESC} anchor works directly.
    _ESC=$'\033'
    status_line=$(printf '%s' "$status_line" \
        | sed "s/ | \\\\033\[38;2;102;92;84m\[.*${_ESC}\[38;2;251;241;199m[0-9]*%${_ESC}\[0m//")
    status_line=$(printf '%s' "$status_line" \
        | sed "s/ | ${_ESC}\[38;2;224;175;104m[^${_ESC}]*${_ESC}\[0m//")

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
    # Self-fix: host status-line.sh may set tokens_used=0 when used_percentage=0
    # (CC reports 0% usage for non-Anthropic models even when tokens were consumed).
    # Fallback: derive tokens_used from total_input + total_output; then derive
    # used_percentage from tokens / context_window.
    _total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
    _total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
    _total=$((_total_input + _total_output))
    if { [ "$used_percentage" = "0" ] || [ "$used_percentage" = "null" ]; } && [ "$_total" -gt 0 ]; then
        tokens_used="$_total"
        if [ "$context_window_size" -gt 0 ]; then
            used_percentage=$(echo "scale=2; 100 * $_total / $context_window_size" | bc)
        fi
    fi
    # Round to integer — ctx-segment.sh validates used_percentage with ^[0-9]+$ (integers only)
    used_percentage=$(printf "%.0f" "$used_percentage")
    model_id=$(echo "$input" | jq -r '.model.id // .model.display_name // ""' 2>/dev/null)
    # DEBUG: uncomment to capture input JSON for troubleshooting model_id extraction
    # echo "$input" > "$HOME/.claude/orchestra/logs/status-line-input-debug.json" 2>/dev/null || true
    ctx_seg=$(~/.claude/scripts/ctx-segment.sh "${used_percentage:-0}" "${tokens_used:-0}" "${context_window_size:-200000}" "${model_id:-}" 2>/dev/null || true)

    # --- live cost from SoHoAI (orchestra sessions + native session JSONL fallback) ---
    live_cost=""
    if [ -n "$live_session_id" ]; then
        if [ -n "$active_session_dir" ]; then
            cost_cache="${active_session_dir}/.live-cost-sohoai"
            started_at=$(stat -c %Y "$active_session_dir" 2>/dev/null || echo "0")
            live_cost=$(~/.claude/scripts/sohoai-live-cost.sh \
                "$live_session_id" "$started_at" "$cost_cache" 2>/dev/null || true)
        elif [[ "$live_session_id" == native-* ]]; then
            _lck="$HOME/.claude/active-sessions/${live_session_id}.lck"
            _started_raw=$(grep '^started_at=' "$_lck" 2>/dev/null | cut -d= -f2-)
            # lck stores ISO 8601 (e.g. 2026-05-11T15:31:19Z); convert to Unix epoch
            [[ "$_started_raw" == *T* ]] \
                && _started=$(date -d "$_started_raw" +%s 2>/dev/null || echo "0") \
                || _started="${_started_raw:-0}"
            cost_cache="$HOME/.claude/active-sessions/${live_session_id}.cost-cache"
            live_cost=$(~/.claude/scripts/sohoai-live-cost.sh \
                "$live_session_id" "${_started:-0}" "$cost_cache" 2>/dev/null || true)
        fi
    fi

    # Insert ctx+cost at position 2: right after model field, before project/branch.
    # ${var/ | / | INSERT | } replaces only the FIRST ' | ' separator in $status_line.
    _insert=""
    [ -n "$ctx_seg"   ] && _insert="${ctx_seg}"
    [ -n "$live_cost" ] && { [ -n "$_insert" ] && _insert+=" | ${live_cost}" || _insert="${live_cost}"; }
    [ -n "$_insert"   ] && status_line="${status_line/ | / | ${_insert} | }"

    # --- badge rendering (priority: duo > brain > plain subagent) ---
    if [ "$duo_count" -gt 0 ]; then
        if [ "$duo_count" -eq 1 ]; then
            duo_badge="orchestra -> plan ${duo_title}"
        else
            duo_badge="orchestra -> plan #${duo_count}"
        fi
        if [ -n "$active_indicator" ]; then
            status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET} %s" "$duo_badge" "$active_indicator")
        else
            status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET}" "$duo_badge")
        fi
    elif [ -n "$orch_title" ]; then
        badge="orchestra -> brain ${orch_title}"
        if [ -n "$active_indicator" ]; then
            status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET} %s" "$badge" "$active_indicator")
        else
            status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ %s${RESET}" "$badge")
        fi
    elif [ -n "$active_indicator" ]; then
        status_line+=$(printf " | ${ORCHESTRA_COLOR}♪ orchestra${RESET} %s" "$active_indicator")
    fi
fi

# ORCHESTRA_BLOCK_END
