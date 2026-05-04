#!/usr/bin/env bash
# ~/.claude/scripts/orchestra-hook.sh
#
# Claude Orchestra hook dispatcher (subagents architecture).
#
# Wired in settings.json hooks.PreToolUse(Agent), SubagentStop, PreCompact.
# All output to .claude/orchestra/{invocations.log, logs/, brain-state.md}.
#
# Modes:
#   start    — PreToolUse(Agent): record a subagent dispatch (subagent_type,
#              prompt excerpt, timestamp). Creates logs/<stage>-<ts>-…log.
#   end      — SubagentStop: append a "done" marker to the matching logfile;
#              record completion event in invocations.log.
#   compact  — PreCompact: write brain-state.md snapshot pointing at the most
#              recent session subdir's artifacts.
#
# Headless-architecture features deleted in the subagents revert:
#   - "tool" mode (live tool-call append on Edit/Write/Bash)
#   - tmux window creation / rename / scheduled kill
#   - live-stage.env and live.log symlink
#   - state.env LAST_WINDOW_/LAST_LOGFILE_ tracking
#
# Design reference: docs/design.md (in this repo)

set -uo pipefail  # NOT -e: a failing jq call must never block Claude

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

mkdir -p "${LOGS_DIR}" 2>/dev/null || true
touch "${INVOCATIONS_LOG}" 2>/dev/null || true

stamp_fields() {
  printf '"host":"%s","pid":"%s","session":"%s","ts":"%s"' \
    "$STAMP_HOST" "$STAMP_PID" "$STAMP_SESSION" "$STAMP_TS"
}

# Find the most recent orchestra session_dir without a telemetry.json
# (i.e., still active or unfinalised). Prefer one with .duo-inflight or
# an in-flight ORCHESTRA_TITLE in state.env. Echoes the path or empty.
find_active_session_dir() {
  local sessions_root="${ORCHESTRA_DIR}/sessions"
  [ -d "$sessions_root" ] || return 0
  # Pick the most recently modified subdir that lacks telemetry.json
  find "$sessions_root" -mindepth 1 -maxdepth 1 -type d \
       -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn \
    | while read -r _ts dir; do
        if [ ! -f "$dir/telemetry.json" ]; then
          echo "$dir"
          break
        fi
      done
}

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

# Stable per-PID logfile name so `end` can find what `start` created.
LAST_LOGFILE_REF="${ORCHESTRA_DIR}/.last-logfile.${STAMP_PID}"

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

    # Remember this logfile so `end` can find it
    printf '%s\n' "$LOGFILE" > "$LAST_LOGFILE_REF" 2>/dev/null || true

    printf '{"event":"start","stage":"%s","subagent":"%s","logfile":"%s",%s}\n' \
      "$STAGE" "$SUBAGENT" "$LOGFILE" "$(stamp_fields)" \
      >> "$INVOCATIONS_LOG" 2>/dev/null || true

    # T1 telemetry: append start-event to active session's telemetry-events.jsonl
    ACTIVE_SESSION_DIR="$(find_active_session_dir)"
    if [ -n "$ACTIVE_SESSION_DIR" ]; then
      USAGE_JSON="$(printf '%s' "$INPUT_JSON" \
        | jq -c '.tool_input.usage // .params.usage // null' 2>/dev/null \
        || echo "null")"
      printf '{"event":"start","subagent":"%s","stage":"%s","usage":%s,%s}\n' \
        "$SUBAGENT" "$STAGE" "$USAGE_JSON" "$(stamp_fields)" \
        >> "${ACTIVE_SESSION_DIR}/telemetry-events.jsonl" 2>/dev/null || true
      # Capture transcript path using CLAUDE_PROJECT_DIR (reliable in hook env)
      if [ ! -f "${ACTIVE_SESSION_DIR}/.transcript-path" ]; then
        _HOOK_MANGLED="$(printf '%s' "${PROJECT_DIR}" | tr '/' '-')"
        _HOOK_TRANSCRIPTS="${HOME}/.claude/projects/${_HOOK_MANGLED}"
        if [ -d "$_HOOK_TRANSCRIPTS" ]; then
          _HOOK_LATEST="$(ls -t "$_HOOK_TRANSCRIPTS"/*.jsonl 2>/dev/null | head -1)"
          if [ -n "$_HOOK_LATEST" ]; then
            printf '%s\n' "$_HOOK_LATEST" \
              > "${ACTIVE_SESSION_DIR}/.transcript-path" 2>/dev/null || true
            printf '%s\n' "$(basename "$_HOOK_LATEST" .jsonl)" \
              > "${ACTIVE_SESSION_DIR}/.transcript-uuid" 2>/dev/null || true
          fi
        fi
      fi
    fi
    ;;

  end)
    SUBAGENT="$(printf '%s' "$INPUT_JSON" \
      | jq -r '.subagent_type // .tool_input.subagent_type // .agent // "unknown"' 2>/dev/null \
      || echo "unknown")"
    STAGE="$(stage_for_subagent "$SUBAGENT")"

    LOGFILE=""
    if [ -f "$LAST_LOGFILE_REF" ]; then
      LOGFILE="$(cat "$LAST_LOGFILE_REF" 2>/dev/null || true)"
      rm -f "$LAST_LOGFILE_REF" 2>/dev/null || true
    fi

    if [ -n "$LOGFILE" ] && [ -f "$LOGFILE" ]; then
      {
        echo ""
        echo "---"
        echo "## ✓ done — ${STAMP_TS}"
      } >> "$LOGFILE" 2>/dev/null || true
    fi

    printf '{"event":"end","stage":"%s","subagent":"%s","logfile":"%s",%s}\n' \
      "$STAGE" "$SUBAGENT" "$LOGFILE" "$(stamp_fields)" \
      >> "$INVOCATIONS_LOG" 2>/dev/null || true

    # T1 telemetry: append end-event to active session's telemetry-events.jsonl
    ACTIVE_SESSION_DIR="$(find_active_session_dir)"
    if [ -n "$ACTIVE_SESSION_DIR" ]; then
      USAGE_JSON="$(printf '%s' "$INPUT_JSON" \
        | jq -c '.usage // .tool_input.usage // .params.usage // null' 2>/dev/null \
        || echo "null")"
      printf '{"event":"end","subagent":"%s","stage":"%s","usage":%s,%s}\n' \
        "$SUBAGENT" "$STAGE" "$USAGE_JSON" "$(stamp_fields)" \
        >> "${ACTIVE_SESSION_DIR}/telemetry-events.jsonl" 2>/dev/null || true
    fi
    ;;

  compact)
    BRAIN_STATE="${ORCHESTRA_DIR}/brain-state.md"
    TMPFILE="${BRAIN_STATE}.tmp.${STAMP_PID}"

    # Find the most recent session subdir (if any)
    LATEST_SESSION_DIR=""
    if [ -d "${ORCHESTRA_DIR}/sessions" ]; then
      LATEST_SESSION_DIR="$(find "${ORCHESTRA_DIR}/sessions" -mindepth 1 -maxdepth 1 -type d \
                             -printf '%T@ %p\n' 2>/dev/null \
                           | sort -rn | head -1 | cut -d' ' -f2-)"
    fi

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
      echo "Read-only forensic snapshot taken just before context compaction. The"
      echo "subagents architecture has no /brain-resume; this file is for audit only."
      echo ""
      if [ -n "$LATEST_SESSION_DIR" ]; then
        echo "## Most recent session: ${LATEST_SESSION_DIR}"
        echo ""
        for f in RESEARCH.md PLAN.md TASKS.json review-comments.md; do
          if [ -f "${LATEST_SESSION_DIR}/${f}" ]; then
            echo "- ${f} — $(wc -c < "${LATEST_SESSION_DIR}/${f}" 2>/dev/null || echo '?') bytes"
          fi
        done
      else
        echo "## No session subdirs present"
      fi
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

  stop)
    # Claude Code session ending. Finalise any orchestra session_dirs that
    # don't have telemetry.json yet. Best-effort; never blocks Claude.
    SESSIONS_ROOT="${ORCHESTRA_DIR}/sessions"
    if [ -d "$SESSIONS_ROOT" ]; then
      find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | while read -r dir; do
            if [ ! -f "$dir/telemetry.json" ] && [ -f "$dir/PLAN.md" ]; then
              # Determine command from presence of .duo-inflight (legacy) or RESEARCH.md (brain).
              CMD="brain"
              [ -f "$dir/.duo-inflight" ] && CMD="duo"
              # Determine outcome marker
              OUTCOME="$(cat "$dir/.outcome" 2>/dev/null || echo "abandoned")"
              # Invoke summariser; pass empty transcript-id to let it self-discover.
              SUMMARISER="${HOME}/.claude/scripts/telemetry-summarize.sh"
              [ -x "$SUMMARISER" ] && "$SUMMARISER" "$dir" "$CMD" "$OUTCOME" "" 2>/dev/null || true
            fi
          done
    fi
    printf '{"event":"stop",%s}\n' "$(stamp_fields)" \
      >> "$INVOCATIONS_LOG" 2>/dev/null || true
    ;;

  *)
    printf '{"event":"error","message":"unknown mode %s",%s}\n' \
      "${MODE:-<empty>}" "$(stamp_fields)" \
      >> "$INVOCATIONS_LOG" 2>/dev/null || true
    ;;

esac

exit 0
