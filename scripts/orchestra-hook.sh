#!/usr/bin/env bash
# ~/.claude/scripts/orchestra-hook.sh
#
# Claude Orchestra hook dispatcher. Called by Claude Code on:
#   PreToolUse (matcher: Agent)           -> mode "start"
#   PreToolUse (matchers: Edit/Write/Bash) -> mode "tool"
#   SubagentStop                           -> mode "end"
#   PreCompact                             -> mode "compact"
#
# Design reference: docs/design.md (in this repo)
# Change log:       docs/design-history.md (in this repo)

set -uo pipefail  # note: NOT -e; a failing jq or tmux call must never block Claude

MODE="${1:-}"
INPUT_JSON="$(cat 2>/dev/null || true)"

STAMP_HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
STAMP_PID=$$
STAMP_SESSION="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-unknown}}"
STAMP_TS="$(date -u +%Y%m%dT%H%M%SZ)"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ORCHESTRA_DIR="${PROJECT_DIR}/.claude/orchestra"

INVOCATIONS_LOG="${ORCHESTRA_DIR}/invocations.log"
LOGS_DIR="${ORCHESTRA_DIR}/logs"
STATE_ENV="${ORCHESTRA_DIR}/state.env"
LIVE_ENV="${ORCHESTRA_DIR}/live-stage.env"

mkdir -p "${LOGS_DIR}" 2>/dev/null || true
touch "${INVOCATIONS_LOG}" 2>/dev/null || true
touch "${STATE_ENV}" 2>/dev/null || true

stamp_fields() {
  printf '"host":"%s","pid":"%s","session":"%s","ts":"%s"' \
    "$STAMP_HOST" "$STAMP_PID" "$STAMP_SESSION" "$STAMP_TS"
}

# Map subagent_type -> pipeline stage (Sequential Phase Architecture name)
stage_for_subagent() {
  case "$1" in
    planner)         echo "plan" ;;
    actor)           echo "implement" ;;
    reviewer)        echo "review" ;;
    Plan)            echo "plan" ;;
    Explore)         echo "research" ;;
    general-purpose) echo "implement" ;;
    *)               echo "agent" ;;
  esac
}

# Find next available tmux window name matching "<base>" or "<base>_N"
next_window_name() {
  local base="$1"
  if [ -z "${TMUX:-}" ] || [ -n "${CLAUDE_ORCHESTRA_DISABLE_TMUX:-}" ]; then
    echo "$base"
    return
  fi
  # grep -c always emits one line with the count; swallow all errors via subshell
  local existing
  existing=$(
    { tmux list-windows -F '#W' 2>/dev/null \
      | grep -cE "^${base}(_[0-9]+)?( ✓)?$" 2>/dev/null ; } || true
  )
  # Keep digits only (defence against multi-line or error leakage)
  existing="${existing//[^0-9]/}"
  existing="${existing:-0}"
  if [ "$existing" -eq 0 ] 2>/dev/null; then
    echo "$base"
  else
    echo "${base}_${existing}"
  fi
}

# In-tmux detection respects a user opt-out env var
in_tmux() {
  [ -n "${TMUX:-}" ] && [ -z "${CLAUDE_ORCHESTRA_DISABLE_TMUX:-}" ]
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
case "$MODE" in

  start)
    SUBAGENT="$(printf '%s' "$INPUT_JSON" \
      | jq -r '.tool_input.subagent_type // .params.subagent_type // "unknown"' 2>/dev/null \
      || echo "unknown")"
    PROMPT="$(printf '%s' "$INPUT_JSON" \
      | jq -r '.tool_input.prompt // .params.prompt // ""' 2>/dev/null \
      | head -c 2000 \
      || echo "")"
    STAGE="$(stage_for_subagent "$SUBAGENT")"
    LOGFILE="${LOGS_DIR}/${STAGE}-${STAMP_TS}-${STAMP_HOST}-${STAMP_PID}.log"

    {
      echo "# ${STAGE} — subagent=${SUBAGENT}"
      echo "# host=${STAMP_HOST} pid=${STAMP_PID} session=${STAMP_SESSION} ts=${STAMP_TS}"
      echo ""
      echo "## Prompt (first 2000 chars):"
      echo ""
      printf '%s\n' "${PROMPT}"
      echo ""
      echo "---"
      echo "## Subagent running..."
    } > "$LOGFILE" 2>/dev/null || true

    printf '{"event":"start","stage":"%s","subagent":"%s","logfile":"%s",%s}\n' \
      "$STAGE" "$SUBAGENT" "$LOGFILE" "$(stamp_fields)" \
      >> "$INVOCATIONS_LOG" 2>/dev/null || true

    # Live-feed: stable pointer to the active logfile (works in tmux and VSCode)
    printf 'ACTIVE_LOGFILE=%s\n' "$LOGFILE" > "$LIVE_ENV" 2>/dev/null || true
    ln -sfn "$LOGFILE" "${ORCHESTRA_DIR}/live.log" 2>/dev/null || true

    if in_tmux; then
      WINDOW_NAME="$(next_window_name "$STAGE")"
      tmux new-window -d -n "$WINDOW_NAME" "tail -f '$LOGFILE'" 2>/dev/null || true
      # Remember this window for the matching end event (per-stage last-known)
      STAGE_UPPER="$(printf '%s' "$STAGE" | tr '[:lower:]-' '[:upper:]_')"
      printf 'LAST_WINDOW_%s=%s\n' "$STAGE_UPPER" "$WINDOW_NAME" >> "$STATE_ENV"
      printf 'LAST_LOGFILE_%s=%s\n' "$STAGE_UPPER" "$LOGFILE"    >> "$STATE_ENV"
    fi
    ;;

  end)
    # SubagentStop hook payload schema may vary; try a few extraction paths
    SUBAGENT="$(printf '%s' "$INPUT_JSON" \
      | jq -r '.subagent_type // .tool_input.subagent_type // .agent // "unknown"' 2>/dev/null \
      || echo "unknown")"
    STAGE="$(stage_for_subagent "$SUBAGENT")"

    WINDOW_NAME=""
    LOGFILE=""
    if [ -f "$STATE_ENV" ]; then
      # shellcheck disable=SC1090
      . "$STATE_ENV" 2>/dev/null || true
      STAGE_UPPER="$(printf '%s' "$STAGE" | tr '[:lower:]-' '[:upper:]_')"
      WINDOW_VAR="LAST_WINDOW_${STAGE_UPPER}"
      LOGFILE_VAR="LAST_LOGFILE_${STAGE_UPPER}"
      WINDOW_NAME="${!WINDOW_VAR:-}"
      LOGFILE="${!LOGFILE_VAR:-}"
    fi

    if [ -n "$LOGFILE" ] && [ -f "$LOGFILE" ]; then
      {
        echo ""
        echo "---"
        echo "## ✓ done — ${STAMP_TS}"
      } >> "$LOGFILE" 2>/dev/null || true
    fi

    # Clear the live-feed pointer so tool hooks no-op after the subagent finishes
    rm -f "$LIVE_ENV" 2>/dev/null || true

    printf '{"event":"end","stage":"%s","subagent":"%s","window":"%s",%s}\n' \
      "$STAGE" "$SUBAGENT" "$WINDOW_NAME" "$(stamp_fields)" \
      >> "$INVOCATIONS_LOG" 2>/dev/null || true

    if in_tmux && [ -n "$WINDOW_NAME" ]; then
      tmux rename-window -t "$WINDOW_NAME" "${WINDOW_NAME} ✓" 2>/dev/null || true
      # Schedule kill-window 120 s from now in a detached subshell
      ( sleep 120 && tmux kill-window -t "${WINDOW_NAME} ✓" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    fi
    ;;

  compact)
    BRAIN_STATE="${ORCHESTRA_DIR}/brain-state.md"
    TMPFILE="${BRAIN_STATE}.tmp.${STAMP_PID}"

    {
      echo "---"
      echo "title: \"Brain state snapshot (pre-compact)\""
      echo "saved_at: ${STAMP_TS}"
      echo "saved_by: orchestra pre-compact hook"
      echo "host: ${STAMP_HOST}"
      echo "pid: ${STAMP_PID}"
      echo "session: ${STAMP_SESSION}"
      echo "---"
      echo ""
      echo "# Brain state snapshot"
      echo ""
      echo "v1 payload: minimal — points at the state files Brain should re-read on resume."
      echo ""
      echo "## State files present in this project"
      for f in PLAN.md TASKS.json review-comments.md; do
        if [ -f "${ORCHESTRA_DIR}/${f}" ]; then
          echo "- ${f} — $(wc -c < "${ORCHESTRA_DIR}/${f}" 2>/dev/null || echo '?') bytes"
        fi
      done
      echo ""
      echo "## Recent orchestra invocations (last 20)"
      echo ""
      echo '```'
      tail -n 20 "$INVOCATIONS_LOG" 2>/dev/null || echo "(no invocations log)"
      echo '```'
    } > "$TMPFILE" 2>/dev/null

    mv -f "$TMPFILE" "$BRAIN_STATE" 2>/dev/null || true

    printf '{"event":"compact","brain_state":"%s",%s}\n' \
      "$BRAIN_STATE" "$(stamp_fields)" \
      >> "$INVOCATIONS_LOG" 2>/dev/null || true
    ;;

  tool)
    # Fire on PreToolUse(Edit|Write|Bash) — append a live tool-call line to the active logfile.
    # No-ops silently if no subagent is currently running (live-stage.env absent).
    [ -f "$LIVE_ENV" ] || exit 0
    ACTIVE_LOGFILE=""
    # shellcheck disable=SC1090
    . "$LIVE_ENV" 2>/dev/null || true
    [ -n "$ACTIVE_LOGFILE" ] && [ -f "$ACTIVE_LOGFILE" ] || exit 0

    TOOL_NAME="$(printf '%s' "$INPUT_JSON" \
      | jq -r '.tool_name // "TOOL"' 2>/dev/null || echo "TOOL")"
    TOOL_PARAM="$(printf '%s' "$INPUT_JSON" \
      | jq -r '.tool_input.file_path // .tool_input.command // .tool_input.path // ""' 2>/dev/null \
      | head -c 120 \
      || echo "")"

    printf '[%s] %s %s\n' \
      "$(date -u +%H:%M:%S)" \
      "${TOOL_NAME^^}" \
      "$TOOL_PARAM" \
      >> "$ACTIVE_LOGFILE" 2>/dev/null || true
    ;;

  *)
    printf '{"event":"error","message":"unknown mode %s",%s}\n' \
      "${MODE:-<empty>}" "$(stamp_fields)" \
      >> "$INVOCATIONS_LOG" 2>/dev/null || true
    ;;

esac

exit 0
