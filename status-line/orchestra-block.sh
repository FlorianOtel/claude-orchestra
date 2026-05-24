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
    # Staleness check: a .duo-inflight is live only when the CC session that
    # created it is still running. Each session dir holds .transcript-uuid
    # (the CC session UUID written atomically with .duo-inflight); we verify
    # liveness by checking for native-<uuid>.lck in active-sessions. The Stop
    # hook cleans up dead .lck files, so a missing .lck means a dead session.
    duo_count=0
    duo_title=""
    _live_duo_dir=""
    sessions_root="$cwd/.claude/orchestra/sessions"
    if [ -d "$sessions_root" ]; then
        while IFS= read -r _inf; do
            [ -z "$_inf" ] && continue
            _sess_dir=$(dirname "$_inf")
            _tuuid=$(cat "${_sess_dir}/.transcript-uuid" 2>/dev/null | tr -d '[:space:]')
            # Missing .transcript-uuid or no live .lck → stale, skip.
            [ -z "$_tuuid" ] && continue
            [ ! -f "$HOME/.claude/active-sessions/native-${_tuuid}.lck" ] && continue
            duo_count=$(( duo_count + 1 ))
            if [ "$duo_count" -eq 1 ]; then
                duo_title=$(head -c 30 "$_inf" 2>/dev/null || true)
                _live_duo_dir="$_sess_dir"
            fi
        done < <(find "$sessions_root" -maxdepth 2 -name ".duo-inflight" 2>/dev/null)
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
        active_session_dir="$_live_duo_dir"
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

    # Restore [1m] suffix when settings.json configures a 1M model but the API
    # response strips it. [1m] is CC-local routing — the Anthropic API returns
    # the plain model ID (e.g., "claude-sonnet-4-6") regardless of the context
    # tier, so ctx-segment.sh's forced_1m branch never fires after the first
    # API call unless we re-inject it here.
    _settings_model=""
    for _sf in "$cwd/.claude/settings.json" "$HOME/.claude/settings.json"; do
        if [ -f "$_sf" ]; then
            _sm=$(jq -r '.model // ""' "$_sf" 2>/dev/null)
            if [ -n "$_sm" ]; then
                _settings_model="$_sm"
                break
            fi
        fi
    done
    if [[ "$_settings_model" == *"[1m]"* ]] && [[ "$model_id" != *"[1m]"* ]] && [[ -n "$model_id" ]]; then
        _settings_base=$(echo "$_settings_model" | sed 's/\[1m\]//g; s/\[.*\]//g')
        case "$_settings_base" in
            sonnet) _settings_base="claude-sonnet-4-6" ;;
            opus)   _settings_base="claude-opus-4-7"   ;;
            haiku)  _settings_base="claude-haiku-4-5"  ;;
        esac
        if [[ "$model_id" == "$_settings_base" ]] || [[ "$model_id" == "$_settings_base"-* ]]; then
            model_id="${model_id}[1m]"
        fi
    fi

    # Recalculate used_percentage against 1M denominator when [1m] is in model_id.
    # CC reports used_pct relative to the 200K window (the API always strips [1m]
    # from its response, causing CC to revert to 200K after the first API call).
    # Without this re-derivation the bar fill and label are ~5× inflated relative
    # to the real 1M window. Removed accidentally in 385c011; restored here.
    if [[ "$model_id" == *"[1m]"* ]] && [ "${tokens_used:-0}" -gt 0 ]; then
        used_percentage=$(echo "scale=2; 100 * $tokens_used / 1000000" | bc)
        used_percentage=$(printf "%.0f" "$used_percentage")
    fi

    ctx_seg=$(~/.claude/scripts/ctx-segment.sh "${used_percentage:-0}" "${tokens_used:-0}" "${context_window_size:-200000}" "${model_id:-}" 2>/dev/null || true)

    # Fix model display name: when [1m] was restored above, CC's display_name
    # no longer says "(1M context)". Re-inject it via literal text substitution
    # on status_line. model_name is in scope from the host script (status-line.sh).
    if [[ "$model_id" == *"[1m]"* ]] && [[ -n "${model_name:-}" ]] && [[ "$model_name" != *"(1M"* ]]; then
        status_line="${status_line/✦ ${model_name}/✦ ${model_name} (1M context)}"
    fi

    # --- live cost (section-based state model) ---
    # State file: ~/.claude/active-sessions/<UUID>.section
    # Four KEY=VALUE fields (sourceable by bash, atomic-rename on all writes):
    #   SECTION_ID   — current section identifier
    #   CC_BASE      — cost.total_cost_usd at section start
    #   SUB_BASE     — native-subagent-cost.sh total at section start
    #   LAST_NONZERO — last display cost > 0 in this section (transient-zero guard)
    live_cost=""
    if [ -n "$live_session_id" ]; then
        _parent_uuid=$(echo "$input" | jq -r '.session_id // ""' 2>/dev/null)
        _state_file="$HOME/.claude/active-sessions/${_parent_uuid}.section"

        # 1. Determine current section_id
        #    Orchestra: active_session_dir is set (live /brain or /duo).
        #    Native: native:<last-orch-id-or-initial>
        if [ -n "$active_session_dir" ]; then
            _current_section_id=$(basename "$active_session_dir")
        else
            _last_orch_id=""
            if [ -d "$sessions_root" ]; then
                while IFS= read -r _sd; do
                    [ -f "$_sd/telemetry.json" ] || continue
                    _suuid=$(cat "$_sd/.transcript-uuid" 2>/dev/null | tr -d '[:space:]')
                    [ "$_suuid" = "$_parent_uuid" ] || continue
                    _last_orch_id=$(basename "$_sd")
                done < <(find "$sessions_root" -mindepth 1 -maxdepth 1 -type d \
                    -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')
            fi
            _current_section_id="native:${_last_orch_id:-initial}"
        fi

        # 2. Read stored state (defaults to empty if file missing)
        _stored_section_id=""
        _cc_base="0"
        _sub_base="0"
        _last_nonzero="0"
        if [ -f "$_state_file" ]; then
            _stored_section_id=$(grep '^SECTION_ID=' "$_state_file" 2>/dev/null | cut -d= -f2-)
            _cc_base=$(grep '^CC_BASE=' "$_state_file" 2>/dev/null | cut -d= -f2-)
            _sub_base=$(grep '^SUB_BASE=' "$_state_file" 2>/dev/null | cut -d= -f2-)
            _last_nonzero=$(grep '^LAST_NONZERO=' "$_state_file" 2>/dev/null | cut -d= -f2-)
        fi

        # 3. Read current raw costs
        _cc_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)

        # Subagent costs — TTL-cached 30 s
        _sub_cache="$HOME/.claude/active-sessions/${_parent_uuid}.subcost-cache"
        _sub_age=$(( $(date +%s) - $(stat -c %Y "$_sub_cache" 2>/dev/null || echo 0) ))
        if [ "$_sub_age" -gt 30 ]; then
            _sub_cost=$(~/.claude/scripts/native-subagent-cost.sh "$_parent_uuid" 2>/dev/null || echo "")
            printf '%s' "${_sub_cost:-0}" > "$_sub_cache.tmp" 2>/dev/null \
                && mv -f "$_sub_cache.tmp" "$_sub_cache" 2>/dev/null || true
        else
            _sub_cost=$(cat "$_sub_cache" 2>/dev/null || echo "")
        fi
        _sub_cost="${_sub_cost:-0}"

        # 4. Section transition: rewrite state file when section_id changes
        if [ "$_current_section_id" != "$_stored_section_id" ]; then
            printf 'SECTION_ID=%s\nCC_BASE=%s\nSUB_BASE=%s\nLAST_NONZERO=0\n' \
                "$_current_section_id" "${_cc_cost:-0}" "${_sub_cost:-0}" \
                > "$_state_file.tmp" 2>/dev/null \
                && mv -f "$_state_file.tmp" "$_state_file" 2>/dev/null || true
            _cc_base="${_cc_cost:-0}"
            _sub_base="${_sub_cost:-0}"
            _last_nonzero="0"
        fi

        # 5. Compute display cost by section type
        _display_cost=""
        if [ -n "$active_session_dir" ]; then
            # Orchestra: SoHoAI subagent cost + CC parent delta
            cost_cache="${active_session_dir}/.live-cost-sohoai"
            started_at=$(stat -c %Y "$active_session_dir" 2>/dev/null || echo "0")
            _sohoai_str=$(~/.claude/scripts/sohoai-live-cost.sh \
                "$live_session_id" "$started_at" "$cost_cache" 2>/dev/null || true)
            if [ -n "$_sohoai_str" ]; then
                _sohoai_num=$(printf '%s' "$_sohoai_str" | grep -oE '[0-9]+\.[0-9]+' | head -1)
                if [ -n "$_sohoai_num" ] \
                   && [ "$(printf '%.0f' "$_sohoai_num" 2>/dev/null || echo 0)" != "0" ]; then
                    _display_cost=$(${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3 \
                        -c "s=float('${_sohoai_num:-0}');cc=float('${_cc_cost:-0}');cb=float('${_cc_base:-0}');print(f'{s+max(0.0,cc-cb):.4f}')" \
                        2>/dev/null || echo "")
                fi
            fi
            # SoHoAI returned nothing or zero: show LAST_NONZERO (or 0)
            if [ -z "$_display_cost" ]; then
                if [ -n "$_last_nonzero" ] && \
                   printf '%s' "$_last_nonzero" | grep -qE '^[0-9]+\.?[0-9]*$' && \
                   [ "$(printf '%.0f' "$_last_nonzero" 2>/dev/null || echo 0)" != "0" ]; then
                    _display_cost="$_last_nonzero"
                else
                    _display_cost="0.00"
                fi
            fi
        else
            # Native: delta from baselines
            _display_cost=$(${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3 \
                -c "cc=float('${_cc_cost:-0}');sub=float('${_sub_cost:-0}');cb=float('${_cc_base:-0}');sb=float('${_sub_base:-0}');print(f'{max(0.0,cc-cb)+max(0.0,sub-sb):.4f}')" \
                2>/dev/null || echo "0.0000")
            # Transient-zero guard: if delta is 0 but LAST_NONZERO > 0, show cached
            if [ "$(printf '%.0f' "$_display_cost" 2>/dev/null || echo 0)" = "0" ]; then
                if [ -n "$_last_nonzero" ] && \
                   printf '%s' "$_last_nonzero" | grep -qE '^[0-9]+\.?[0-9]*$' && \
                   [ "$(printf '%.0f' "$_last_nonzero" 2>/dev/null || echo 0)" != "0" ]; then
                    _display_cost="$_last_nonzero"
                fi
            fi
        fi

        # 6. Update LAST_NONZERO in state file if display cost > 0
        if printf '%s' "$_display_cost" | grep -qE '^[0-9]+\.?[0-9]*$' && \
           [ "$(printf '%.0f' "$_display_cost" 2>/dev/null || echo 0)" != "0" ]; then
            printf 'SECTION_ID=%s\nCC_BASE=%s\nSUB_BASE=%s\nLAST_NONZERO=%s\n' \
                "$_current_section_id" "${_cc_base:-0}" "${_sub_base:-0}" "$_display_cost" \
                > "$_state_file.tmp" 2>/dev/null \
                && mv -f "$_state_file.tmp" "$_state_file" 2>/dev/null || true
        fi

        # 7. Format for display
        if printf '%s' "$_display_cost" | grep -qE '^[0-9]+\.?[0-9]*$'; then
            live_cost=$(LC_ALL=C printf '~$%.2f' "$_display_cost" 2>/dev/null || true)
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
