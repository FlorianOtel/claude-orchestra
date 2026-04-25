#!/usr/bin/env bash
# scripts/format-stream.sh
#
# Reads `claude -p --output-format stream-json --include-partial-messages` events
# from stdin (one JSON object per line) and emits human-readable terminal output
# to stdout, suitable for tailing in a tmux window or terminal split.
#
# Side effect: if env var RESULT_FILE is set, writes the final `result.result` text
# to that path when the result event arrives (via .tmp + atomic rename).
#
# Design reference: docs/design.md — live action feed Amendment 2026-04-26.
# test: 2026-04-25
# test: 2026-04-25T19:13

set -uo pipefail

# Colors (ANSI). Disabled if NO_COLOR or non-tty.
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_DIM=""; C_BOLD=""; C_RESET=""
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_PURPLE=""; C_CYAN=""
else
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_PURPLE=$'\033[35m'; C_CYAN=$'\033[36m'
fi

# State carried across events.
THINK_START_TS=""

truncate_str() {
  local s="$1" n="${2:-200}"
  if [ "${#s}" -gt "$n" ]; then
    printf '%s…' "${s:0:$n}"
  else
    printf '%s' "$s"
  fi
}

oneliner() {
  printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

while IFS= read -r line; do
  [ -z "$line" ] && continue
  TYPE="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)"
  [ -z "$TYPE" ] && continue

  case "$TYPE" in

    system)
      SUBTYPE="$(printf '%s' "$line" | jq -r '.subtype // empty' 2>/dev/null)"
      if [ "$SUBTYPE" = "init" ]; then
        MODEL="$(printf '%s' "$line" | jq -r '.model // "?"' 2>/dev/null)"
        PERM="$(printf '%s' "$line" | jq -r '.permissionMode // "?"' 2>/dev/null)"
        CWD="$(printf '%s' "$line" | jq -r '.cwd // "?"' 2>/dev/null)"
        printf '%s┌─ session start ───────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
        printf '%s│%s model: %s%s%s\n'      "$C_CYAN" "$C_RESET" "$C_BOLD" "$MODEL" "$C_RESET"
        printf '%s│%s perm:  %s%s%s%s\n'    "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_YELLOW" "$PERM" "$C_RESET"
        printf '%s│%s cwd:   %s%s%s\n'      "$C_CYAN" "$C_RESET" "$C_DIM"  "$CWD"  "$C_RESET"
        printf '%s└────────────────────────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
      fi
      ;;

    stream_event)
      EVENT_TYPE="$(printf '%s' "$line" | jq -r '.event.type // empty' 2>/dev/null)"
      case "$EVENT_TYPE" in

        content_block_start)
          BLOCK_TYPE="$(printf '%s' "$line" | jq -r '.event.content_block.type // empty' 2>/dev/null)"
          case "$BLOCK_TYPE" in
            thinking)
              THINK_START_TS="$(date +%s)"
              printf '%s💭 thinking%s' "$C_PURPLE$C_DIM" "$C_RESET"
              ;;
            text)
              : # text streaming begins; deltas will print
              ;;
            tool_use)
              : # printed when consolidated assistant.message arrives
              ;;
          esac
          ;;

        content_block_delta)
          DELTA_TYPE="$(printf '%s' "$line" | jq -r '.event.delta.type // empty' 2>/dev/null)"
          case "$DELTA_TYPE" in
            text_delta)
              TEXT="$(printf '%s' "$line" | jq -r '.event.delta.text // ""' 2>/dev/null)"
              printf '%s' "$TEXT"
              ;;
            thinking_delta)
              T="$(printf '%s' "$line" | jq -r '.event.delta.thinking // ""' 2>/dev/null)"
              printf '%s%s%s' "$C_PURPLE$C_DIM" "$T" "$C_RESET"
              ;;
            signature_delta)
              printf '%s.%s' "$C_PURPLE$C_DIM" "$C_RESET"
              ;;
            input_json_delta)
              : # accumulated server-side; consolidated assistant.message has the full input
              ;;
          esac
          ;;

        content_block_stop)
          if [ -n "$THINK_START_TS" ]; then
            NOW="$(date +%s)"
            ELAPSED=$((NOW - THINK_START_TS))
            printf ' %s(%ss)%s\n' "$C_DIM" "$ELAPSED" "$C_RESET"
            THINK_START_TS=""
          fi
          ;;

        message_start|message_delta|message_stop)
          : # consolidated assistant.message event handles the payload
          ;;
      esac
      ;;

    assistant)
      # Each tool_use content block, one compact JSON object per line.
      printf '%s' "$line" \
        | jq -c '.message.content[]? | select(.type=="tool_use")' 2>/dev/null \
        | while IFS= read -r tool_obj; do
            [ -z "$tool_obj" ] && continue
            toolname="$(printf '%s' "$tool_obj" | jq -r '.name // "?"' 2>/dev/null)"
            toolinput="$(printf '%s' "$tool_obj" | jq -c '.input // {}' 2>/dev/null)"
            case "$toolname" in
              Edit|Write|MultiEdit)
                FILE_PATH="$(printf '%s' "$toolinput" | jq -r '.file_path // .path // ""' 2>/dev/null)"
                printf '\n%s▸ %s%s %s%s%s\n' "$C_BLUE" "$toolname" "$C_RESET" "$C_BOLD" "$FILE_PATH" "$C_RESET"
                ;;
              Bash)
                CMD="$(printf '%s' "$toolinput" | jq -r '.command // ""' 2>/dev/null)"
                printf '\n%s▸ %s%s %s%s%s\n' "$C_BLUE" "$toolname" "$C_RESET" "$C_BOLD" "$(truncate_str "$(oneliner "$CMD")" 200)" "$C_RESET"
                ;;
              Read|Grep|Glob)
                P="$(printf '%s' "$toolinput" | jq -r '.file_path // .path // .pattern // ""' 2>/dev/null)"
                printf '\n%s▸ %s%s %s\n' "$C_DIM" "$toolname" "$C_RESET" "$P"
                ;;
              *)
                ARGS="$(truncate_str "$(oneliner "$toolinput")" 160)"
                printf '\n%s▸ %s%s %s\n' "$C_BLUE" "$toolname" "$C_RESET" "$ARGS"
                ;;
            esac
          done
      ;;

    user)
      # tool_result messages emitted after each tool execution
      TR_CONTENT="$(printf '%s' "$line" | jq -r '.message.content[]? | select(.type=="tool_result") | .content // ""' 2>/dev/null | head -c 500)"
      IS_ERR="$(printf '%s' "$line" | jq -r '.message.content[]? | select(.type=="tool_result") | .is_error // false' 2>/dev/null | head -1)"
      STDOUT="$(printf '%s' "$line" | jq -r '.tool_use_result.stdout // empty' 2>/dev/null)"
      STDERR="$(printf '%s' "$line" | jq -r '.tool_use_result.stderr // empty' 2>/dev/null)"

      if [ -n "$TR_CONTENT" ] || [ -n "$STDOUT" ] || [ -n "$STDERR" ]; then
        if [ "$IS_ERR" = "true" ]; then
          PREFIX="${C_RED}↳ error${C_RESET}"
        else
          PREFIX="${C_GREEN}↳ ok${C_RESET}"
        fi
        if [ -n "$STDOUT" ] || [ -n "$STDERR" ]; then
          [ -n "$STDOUT" ] && printf '  %s %s\n' "$PREFIX" "$(truncate_str "$(oneliner "$STDOUT")" 240)"
          [ -n "$STDERR" ] && printf '  %s%s%s\n'  "$C_RED" "$(truncate_str "$(oneliner "$STDERR")" 240)" "$C_RESET"
        else
          printf '  %s %s\n' "$PREFIX" "$(truncate_str "$(oneliner "$TR_CONTENT")" 240)"
        fi
      fi
      ;;

    result)
      RESULT_TEXT="$(printf '%s' "$line" | jq -r '.result // ""' 2>/dev/null)"
      DURATION="$(printf '%s' "$line" | jq -r '.duration_ms // 0' 2>/dev/null)"
      COST="$(printf '%s' "$line" | jq -r '.total_cost_usd // 0' 2>/dev/null)"
      IS_ERR="$(printf '%s' "$line" | jq -r '.is_error // false' 2>/dev/null)"

      ERR_TAG=""
      [ "$IS_ERR" = "true" ] && ERR_TAG=" ${C_RED}(error)${C_RESET}"

      printf '\n%s└─ done%s — %sms, $%s%s\n' \
        "$C_CYAN" "$C_RESET" "$DURATION" "$COST" "$ERR_TAG"

      if [ -n "${RESULT_FILE:-}" ]; then
        TMP="${RESULT_FILE}.tmp.$$"
        printf '%s\n' "$RESULT_TEXT" > "$TMP" 2>/dev/null && mv -f "$TMP" "$RESULT_FILE" 2>/dev/null || true
      fi
      ;;

    *)
      : # unknown event types ignored for forward compatibility
      ;;
  esac
done

exit 0
