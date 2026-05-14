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

PROJECT_DIR="$(realpath "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$PWD}")"
ORCHESTRA_DIR="${PROJECT_DIR}/.claude/orchestra"
INVOCATIONS_LOG="${ORCHESTRA_DIR}/invocations.log"
LOGS_DIR="${ORCHESTRA_DIR}/logs"

mkdir -p "${LOGS_DIR}" 2>/dev/null || true
touch "${INVOCATIONS_LOG}" 2>/dev/null || true
find "${ORCHESTRA_DIR}" -maxdepth 1 -name ".last-logfile.*" -mmin +120 -delete 2>/dev/null || true
find "${LOGS_DIR}" -maxdepth 1 -name "*.log" -mtime +30 -delete 2>/dev/null || true

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

# Returns 0 if a /brain or /duo session is currently in-flight.
has_active_orchestra_session() {
  find "${ORCHESTRA_DIR}/sessions" -maxdepth 2 \
    \( -name ".brain-inflight" -o -name ".duo-inflight" \) \
    2>/dev/null | grep -q .
}

# Sidecar so `end` can find what `start` created.
# Prefer session-relative path (shared by start and end); fall back to PID-named
# file when no active session dir exists yet.
_EARLY_SESSION_DIR="$(find_active_session_dir)"
if [ -n "$_EARLY_SESSION_DIR" ]; then
    LAST_LOGFILE_REF="${_EARLY_SESSION_DIR}/.last-logfile"
else
    LAST_LOGFILE_REF="${ORCHESTRA_DIR}/.last-logfile.${STAMP_PID}"
fi

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

    if has_active_orchestra_session; then
      printf '{"event":"start","stage":"%s","subagent":"%s","logfile":"%s",%s}\n' \
        "$STAGE" "$SUBAGENT" "$LOGFILE" "$(stamp_fields)" \
        >> "$INVOCATIONS_LOG" 2>/dev/null || true
    fi

    # T1 telemetry: append start-event to active session's telemetry-events.jsonl
    ACTIVE_SESSION_DIR="$(find_active_session_dir)"
    # Override STAMP_SESSION with the actual transcript UUID if available
    if [ -n "$ACTIVE_SESSION_DIR" ] && [ -f "${ACTIVE_SESSION_DIR}/.transcript-uuid" ]; then
        STAMP_SESSION="$(cat "${ACTIVE_SESSION_DIR}/.transcript-uuid" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
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

    # Derive subagent type from logfile name when SubagentStop JSON omits it
    if [ "$SUBAGENT" = "unknown" ] && [ -n "$LOGFILE" ]; then
        case "$(basename "$LOGFILE")" in
            plan-*)      SUBAGENT="planner"  ;;
            implement-*) SUBAGENT="actor"    ;;
            review-*)    SUBAGENT="reviewer" ;;
            research-*)  SUBAGENT="Explore"  ;;
        esac
        STAGE="$(stage_for_subagent "$SUBAGENT")"
    fi

    if [ -n "$LOGFILE" ] && [ -f "$LOGFILE" ]; then
      {
        echo ""
        echo "---"
        echo "## ✓ done — ${STAMP_TS}"
      } >> "$LOGFILE" 2>/dev/null || true
    fi

    if has_active_orchestra_session; then
      printf '{"event":"end","stage":"%s","subagent":"%s","logfile":"%s",%s}\n' \
        "$STAGE" "$SUBAGENT" "$LOGFILE" "$(stamp_fields)" \
        >> "$INVOCATIONS_LOG" 2>/dev/null || true
    fi

    # T1 telemetry: append end-event to active session's telemetry-events.jsonl
    ACTIVE_SESSION_DIR="$(find_active_session_dir)"
    # Override STAMP_SESSION with the actual transcript UUID if available
    if [ -n "$ACTIVE_SESSION_DIR" ] && [ -f "${ACTIVE_SESSION_DIR}/.transcript-uuid" ]; then
        STAMP_SESSION="$(cat "${ACTIVE_SESSION_DIR}/.transcript-uuid" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
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
    STATE_ENV="${ORCHESTRA_DIR}/state.env"
    if [ -d "$SESSIONS_ROOT" ]; then
      find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | while read -r dir; do
            # Skip already-finalised sessions.
            [ -f "$dir/telemetry.json" ] && continue
            # Skip sessions still in-progress (inflight marker present).
            # The Stop hook fires at the end of every response turn, not only
            # on process exit. Removing the marker here would destroy the
            # status-line badge and cause NO_SESSION errors on the next
            # refinement turn. Badge and session-discovery clear when
            # /duo-act, /duo-abandon, or /brain-abandon explicitly removes the
            # marker as part of their own cleanup.
            [ -f "$dir/.duo-inflight" ]   && continue
            [ -f "$dir/.brain-inflight" ] && continue
            # Safety-net: finalise sessions where inflight markers were already
            # removed (by /duo-act//duo-abandon//brain cleanup) but
            # telemetry-summarize.sh failed to write telemetry.json.
            # Only process dirs that have at least one pipeline artefact.
            HAS_ARTEFACT=false
            for marker in PLAN.md RESEARCH.md telemetry-events.jsonl; do
              if [ -e "$dir/$marker" ]; then HAS_ARTEFACT=true; break; fi
            done
            $HAS_ARTEFACT || continue
            # Inflight markers are always absent here (guarded above). CMD
            # defaults to brain; /duo sessions reach this path only when
            # /duo-act cleanup removed .duo-inflight but telemetry failed.
            CMD="brain"
            # Determine outcome marker. If .outcome doesn't exist, write
            # "abandoned" to disk before invoking the summariser so its mtime
            # bounds the T2 ended_at_unix window (else the parser falls back
            # to time.time() and re-runs would expand the window).
            if [ -f "$dir/.outcome" ]; then
              OUTCOME="$(cat "$dir/.outcome" 2>/dev/null || echo "abandoned")"
            else
              OUTCOME="abandoned"
              printf '%s' "$OUTCOME" > "$dir/.outcome.tmp" 2>/dev/null \
                && mv -f "$dir/.outcome.tmp" "$dir/.outcome" 2>/dev/null || true
            fi
            # Invoke summariser; pass empty transcript-id to let it self-discover.
            SUMMARISER="${HOME}/.claude/scripts/telemetry-summarize.sh"
            [ -x "$SUMMARISER" ] && "$SUMMARISER" "$dir" "$CMD" "$OUTCOME" "" 2>/dev/null || true
            # Reset state.env if we just finalised a /brain session. The
            # /brain command body's cleanup block does this from in-session,
            # but Phase-0-only abandonments and dispatch-skip bugs can leave
            # state.env stuck on ORCHESTRA_MODE=brain. /duo's badge keys on
            # .duo-inflight (not state.env), so this only matters for brain.
            # Note: in multi-Claude-Code-session concurrency, this can clear
            # the badge of a still-active /brain in another session — same
            # flavour as the existing concurrency caveat (E4) in design.md.
            if [ "$CMD" = "brain" ] && [ -f "$STATE_ENV" ]; then
              printf 'ORCHESTRA_MODE=default\nORCHESTRA_TITLE=\n' \
                >> "$STATE_ENV" 2>/dev/null || true
            fi
          done
    fi

    # Finalise dead native sessions (those whose CC process has ended).
    ACTIVE_SESSIONS_DIR="${HOME}/.claude/active-sessions"
    NATIVE_SESSIONS_DIR="${HOME}/.claude/native-sessions"
    mkdir -p "${NATIVE_SESSIONS_DIR}" "${ACTIVE_SESSIONS_DIR}" 2>/dev/null || true

    # Registration is handled by bash-session-init.sh (sourced via BASH_ENV).
    # It writes native-<UUID>.lck on the first Bash tool call of each native session,
    # using the session UUID as the primary key and cc_pid for liveness only.
    NATIVE_FINALIZER="${HOME}/.claude/scripts/native-session-finalize.py"
    NATIVE_VENV="${HOME}/Gin-AI/.Gin-AI-python-3.12"
    for _lck in "${ACTIVE_SESSIONS_DIR}/native-"*.lck; do
        [ -f "$_lck" ] || continue
        _pid="$(grep '^cc_pid=' "$_lck" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
        # Skip if process still alive.
        kill -0 "$_pid" 2>/dev/null && continue
        _sid="$(grep '^session_id='  "$_lck" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
        _sat="$(grep '^started_at=' "$_lck" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
        _uuid="$(grep '^session_uuid=' "$_lck" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
        _eat="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [ -f "$NATIVE_FINALIZER" ] && [ -d "$NATIVE_VENV" ] && [ -n "$_sid" ]; then
            "${NATIVE_VENV}/bin/python3" "$NATIVE_FINALIZER" \
                "$_sid" "$_pid" "$_sat" "$_eat" \
                ${_uuid:+--session-uuid "$_uuid"} \
                >> "${ORCHESTRA_DIR}/invocations.log" 2>/dev/null || true
        fi
        rm -f "$_lck"
    done

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
