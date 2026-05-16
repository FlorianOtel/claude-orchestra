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
    # Native session: session_id from CC JSON is always the current session's UUID.
    # No .lck check needed — .lck is for finalization, not cost display. Removing
    # the .lck gate fixes: (a) resumed sessions before first Bash call (Stop hook
    # removes the old lck at end of prior turn; no new lck until bash-session-init
    # runs), (b) any render that fires before the first Bash tool call.
    if [ -z "$live_session_id" ]; then
        _json_sid=$(echo "$input" | jq -r '.session_id // ""' 2>/dev/null)
        [ -n "$_json_sid" ] && live_session_id="native-${_json_sid}"
    fi

    # --- started_at for native sessions (needed for SoHoAI time-scoped queries) ---
    _real_started_at=""
    if [[ "$live_session_id" == native-* ]]; then
        _lck="$HOME/.claude/active-sessions/${live_session_id}.lck"
        if [ -f "$_lck" ]; then
            _sat_raw=$(grep '^started_at=' "$_lck" 2>/dev/null | cut -d= -f2-)
            if [ -n "$_sat_raw" ]; then
                _real_started_at=$(date -d "$_sat_raw" +%s 2>/dev/null || echo "")
            fi
        fi
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

    # Non-Anthropic models (claude-code-*, local/*) — CC gives no token counts.
    # Soften forced-zero cost: only local/qwen3* models are truly $0.
    _is_non_anthropic=false
    case "$model_id" in
        local/qwen3*|claude-code-qwen3*)
            _is_non_anthropic=true ;;
        claude-code-*)
            _is_non_anthropic=true ;;
    esac

    # --- SoHoAI live token fallback for non-Anthropic models ---
    # When CC reports zero tokens, reach into SoHoAI telemetry.  Scope by
    # .lck started_at so concurrent sessions with the same model don't collide.
    if [ "$_is_non_anthropic" = true ] && [ "$_total" -eq 0 ] \
       && [ -n "$live_session_id" ] && [ -n "$_real_started_at" ]; then
        _sohoai_cache="$HOME/.claude/active-sessions/${live_session_id}.sohoai"
        # Derive bare model name from CC model_id for SoHoAI LIKE query
        _model_filter="${model_id#claude-code-}"
        if [ -z "$_model_filter" ]; then
            _model_filter="${model_id#local/}"
        fi
        [ -z "$_model_filter" ] && _model_filter="$model_id"

        _sohoai_tok=$(~/.claude/scripts/sohoai-live-cost.sh \
            "$live_session_id" "$_real_started_at" "$_sohoai_cache" \
            "$_model_filter" "tokens" 2>/dev/null || echo "")

        # sohoai-live-cost returns latest_total_tokens (most recent request's
        # input+output), not cumulative. latest_total_tokens is inherently
        # monotonic (context only grows), and the 8-second TTL in the .sohoai
        # cache prevents jitter. No separate .max-tokens cache needed.
        if [ -n "$_sohoai_tok" ] && [ "$_sohoai_tok" -gt 0 ] 2>/dev/null; then
            tokens_used="$_sohoai_tok"
            if [ "$context_window_size" -gt 0 ]; then
                used_percentage=$(echo "scale=2; 100 * $_sohoai_tok / $context_window_size" | bc)
            fi
            used_percentage=$(printf "%.0f" "$used_percentage")
        fi
    fi

    ctx_seg=$(~/.claude/scripts/ctx-segment.sh "${used_percentage:-0}" "${tokens_used:-0}" "${context_window_size:-200000}" "${model_id:-}" 2>/dev/null || true)

    # --- live cost ---
    # Orchestra sessions: query SoHoAI (has per-subagent attribution).
    # Native sessions: CC provides cost.total_cost_usd directly in JSON — precise,
    # always current, no SoHoAI query or JSONL parsing needed.
    live_cost=""
    if [ -n "$live_session_id" ]; then
        if [ -n "$active_session_dir" ]; then
            cost_cache="${active_session_dir}/.live-cost-sohoai"
            started_at=$(stat -c %Y "$active_session_dir" 2>/dev/null || echo "0")
            live_cost=$(~/.claude/scripts/sohoai-live-cost.sh \
                "$live_session_id" "$started_at" "$cost_cache" 2>/dev/null || true)
        elif [[ "$live_session_id" == native-* ]]; then
            # Prefer authoritative telemetry.json from the most recent completed
            # orchestra session, but only when it was written AFTER this native
            # session started (.lck mtime is the session-start lower bound).
            # Guard: _lck_mtime > 0 ensures .lck exists; _tel_mtime > _lck_mtime
            # ensures the orchestra session ended during this session, not before.
            # This eliminates false positives for new sessions opened after a
            # pipeline ends in the same project.
            if [ -d "$sessions_root" ]; then
                _recent_dir=$(find "$sessions_root" -mindepth 1 -maxdepth 1 -type d \
                    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)
                _tel_file="${_recent_dir}/telemetry.json"
                if [ -f "$_tel_file" ]; then
                    _lck_mtime=$(stat -c %Y \
                        "$HOME/.claude/active-sessions/${live_session_id}.lck" \
                        2>/dev/null || echo 0)
                    _tel_mtime=$(stat -c %Y "$_tel_file" 2>/dev/null || echo 0)
                    if [ "$_lck_mtime" -gt 0 ] && [ "$_tel_mtime" -gt "$_lck_mtime" ]; then
                        _tel_cost=$(jq -r '.cost_usd_estimate // empty' \
                            "$_tel_file" 2>/dev/null || true)
                        if printf '%s' "$_tel_cost" | grep -qE '^[0-9]+\.?[0-9]*$'; then
                            live_cost=$(LC_ALL=C printf '~$%.2f' "$_tel_cost" 2>/dev/null || true)
                        fi
                    fi
                fi
            fi
            if [ -z "$live_cost" ]; then
            _cc_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)
            if [ "$_is_non_anthropic" = true ]; then
                _cc_cost=0
            fi

            # Subagent costs — walk agent JSONLs, TTL-cached 30 s
            _parent_uuid="${live_session_id#native-}"
            _sub_cache="$HOME/.claude/active-sessions/${live_session_id}.subcost-cache"
            _sub_age=$(( $(date +%s) - $(stat -c %Y "$_sub_cache" 2>/dev/null || echo 0) ))
            if [ "$_sub_age" -gt 30 ]; then
                _sub_cost=$(~/.claude/scripts/native-subagent-cost.sh \
                    "$_parent_uuid" 2>/dev/null || echo "")
                printf '%s' "${_sub_cost:-0}" > "$_sub_cache.tmp" 2>/dev/null \
                    && mv -f "$_sub_cache.tmp" "$_sub_cache" 2>/dev/null || true
            else
                _sub_cost=$(cat "$_sub_cache" 2>/dev/null || echo "")
            fi

            # Combine parent + subagent costs and format
            _total=$(${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3 \
                -c "print(f'{float(\"${_cc_cost:-0}\")+float(\"${_sub_cost:-0}\"):.4f}')" \
                2>/dev/null || echo "${_cc_cost:-0}")

            # Cache last non-zero total; fall back to it when CC reports 0 at turn boundaries
            # (CC resets cost.total_cost_usd to 0 briefly after each tool-call completes).
            # Skip cache read for non-Anthropic models — cost is intentionally $0 for them.
            _cost_cache="$HOME/.claude/active-sessions/${live_session_id}.cost-cache"
            if printf '%s' "$_total" | grep -qE '^[0-9]+\.?[0-9]*$' \
               && [ "$(printf '%.0f' "$_total" 2>/dev/null || echo 0)" != "0" ]; then
                printf '%s' "$_total" > "$_cost_cache.tmp" 2>/dev/null \
                    && mv -f "$_cost_cache.tmp" "$_cost_cache" 2>/dev/null || true
            elif [ "$_is_non_anthropic" != true ] && [ -f "$_cost_cache" ]; then
                _total=$(cat "$_cost_cache" 2>/dev/null || echo "${_total:-0}")
            fi

            # Always show cost (including ~$0.00 at session start) so the field is
            # visible from the first render as a live-display sanity check.
            if printf '%s' "$_total" | grep -qE '^[0-9]+\.?[0-9]*$'; then
                live_cost=$(LC_ALL=C printf '~$%.2f' "$_total" 2>/dev/null || true)
            fi
            fi  # telemetry fallback
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
