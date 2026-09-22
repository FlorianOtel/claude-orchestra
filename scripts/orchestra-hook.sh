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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

PROJECT_DIR="$(realpath "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$PWD}")"
ORCHESTRA_DIR="${PROJECT_DIR}/.claude/orchestra"
INVOCATIONS_LOG="${ORCHESTRA_DIR}/invocations.log"
LOGS_DIR="${ORCHESTRA_DIR}/logs"

mkdir -p "${LOGS_DIR}" 2>/dev/null || true
touch "${INVOCATIONS_LOG}" 2>/dev/null || true
find "${ORCHESTRA_DIR}" -maxdepth 1 -name ".last-logfile.*" -mmin +120 -delete 2>/dev/null || true
find "${LOGS_DIR}" -maxdepth 1 -name "*.log" -mtime +30 -delete 2>/dev/null || true
# Pending markers whose `end` never arrived (killed subagent, gated-off write). The display
# layer's TTL already ignores them; this stops the directory growing without bound.
find "${ORCHESTRA_DIR}/.pending-agents" -type f -mmin +1440 -delete 2>/dev/null || true
# invocations.log is append-only. Rare backstop so it cannot grow without limit; the size
# test is a single stat, and truncation is atomic.
if [ -n "$(find "${INVOCATIONS_LOG}" -maxdepth 0 -size +5M 2>/dev/null)" ]; then
    if tail -n 5000 "${INVOCATIONS_LOG}" > "${INVOCATIONS_LOG}.tmp" 2>/dev/null; then
        mv -f "${INVOCATIONS_LOG}.tmp" "${INVOCATIONS_LOG}" 2>/dev/null || true
    else
        rm -f "${INVOCATIONS_LOG}.tmp" 2>/dev/null || true
    fi
fi

stamp_fields() {
  printf '"host":"%s","pid":"%s","session":"%s","ts":"%s"' \
    "$STAMP_HOST" "$STAMP_PID" "$STAMP_SESSION" "$STAMP_TS"
}

# Find the most recent orchestra session_dir without a telemetry.json
# (i.e., still active or unfinalised). Among candidates lacking telemetry.json,
# prefer the first (most recent by mtime) that also has .brain-inflight or
# .duo-inflight; only if none carry a marker, fall back to the most recent one.
#
# This closes only the abandoned-before-any-marker case (session started but no
# marker written yet). It does NOT close the stale-marker case — a real example
# exists on disk at SoHoAI/.claude/orchestra/sessions/20260730T103150Z-4080513,
# carrying a .duo-inflight dated 2026-07-30 with no telemetry.json. The stale-marker
# case is closed by the session-identity gate in Step 8c below.
find_active_session_dir() {
  local sessions_root="${ORCHESTRA_DIR}/sessions"
  if [ ! -d "$sessions_root" ]; then
    return 0
  fi
  local _candidates=""
  _candidates="$(find "$sessions_root" -mindepth 1 -maxdepth 1 -type d \
                   -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)"
  if [ -z "$_candidates" ]; then
    return 0
  fi
  local _fallback=""
  local dir=""
  # Pass 1: newest-first; take the first unfinalised dir that carries an inflight
  # marker. Remember the newest unfinalised markerless dir as a fallback.
  while IFS= read -r dir; do
    if [ -n "$dir" ] && [ ! -f "$dir/telemetry.json" ]; then
      if [ -f "$dir/.brain-inflight" ] || [ -f "$dir/.duo-inflight" ]; then
        echo "$dir"
        return 0
      fi
      if [ -z "$_fallback" ]; then
        _fallback="$dir"
      fi
    fi
  done <<< "$_candidates"
  # Pass 2: no marker anywhere — behave as before.
  if [ -n "$_fallback" ]; then
    echo "$_fallback"
  fi
  return 0
}

stage_for_subagent() {
  case "$1" in
    planner)         echo "plan" ;;
    actor|actor-heavy) echo "implement" ;;
    reviewer)        echo "review" ;;
    Plan)            echo "plan" ;;
    Explore)         echo "research" ;;
    # researcher / researcher-deep previously fell through to "agent" — the same bucket
    # unidentified ends land in — so an `unknown` end could retire a live researcher's
    # pending marker. That is why researcher starts paired so badly (45 starts / 10 ends in
    # one measured project; docs/TODO.md records a stretch with 86 starts and zero ends).
    researcher|researcher-deep) echo "research" ;;
    general-purpose) echo "implement" ;;
    *)               echo "agent" ;;
  esac
}

# Session-identity gate: verify that CURRENT_SID belongs to the active session.
# Returns 0 if the event should be appended, 1 if it should be rejected.
# On ambiguous cases (missing .lck, empty SID), fails open and returns 0.
should_append_t1_event() {
  local active_session_dir="$1"
  local current_sid="$2"

  # Fail open if both SID sources are empty or unknown
  if [ -z "$current_sid" ] || [ "$current_sid" = "unknown" ]; then
    return 0
  fi

  local session_ids_file="${active_session_dir}/.transcript-session-ids"

  # Seed the file if it doesn't exist
  if [ ! -f "$session_ids_file" ]; then
    if [ -f "${active_session_dir}/.transcript-uuid" ]; then
      cat "${active_session_dir}/.transcript-uuid" > "$session_ids_file" 2>/dev/null || true
    else
      printf '%s\n' "$current_sid" > "$session_ids_file" 2>/dev/null || true
    fi
  fi

  # Check if CURRENT_SID is already in the file
  if grep -qxF "$current_sid" "$session_ids_file" 2>/dev/null; then
    return 0
  fi

  # SID not in file — check if the owning process is still alive via .lck
  local lck_file="${HOME}/.claude/active-sessions/$(basename "$active_session_dir").lck"
  if [ ! -f "$lck_file" ]; then
    # .lck missing: process is provably dead, reject this event.
    # (The .lck may have been pruned by another session's housekeeping.)
    return 1
  fi

  # Extract cc_pid from .lck and check if process is alive
  local cc_pid=""
  cc_pid="$(grep '^cc_pid=' "$lck_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
  if [ -z "$cc_pid" ]; then
    # Malformed .lck, fail open
    return 0
  fi

  # Check if process is alive
  if kill -0 "$cc_pid" 2>/dev/null; then
    # Process is alive: adopt the new SID and allow append
    printf '%s\n' "$current_sid" >> "$session_ids_file" 2>/dev/null || true
    return 0
  else
    # Process is dead: reject this event
    # (Bounded T1-only degradation; T2 walks all in-window JSONLs independently.)
    return 1
  fi
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

    # Remember this logfile so `end` can find it.
    #
    # One marker per pending dispatch, filed under its stage. The previous single-slot
    # sidecar ($LAST_LOGFILE_REF) was clobbered by any concurrent start before the first end
    # could read it; its PID-named fallback keyed on $$, which differs between the start and
    # end processes and so could never match at all.
    #
    # Name sorts chronologically: epoch-nanoseconds is fixed-width, so lexicographic order is
    # dispatch order. Stage-keying means an end can only ever consume a marker of its own kind.
    PENDING_DIR="${ORCHESTRA_DIR}/.pending-agents/${STAGE}"
    mkdir -p "$PENDING_DIR" 2>/dev/null || true
    printf '%s\n' "$LOGFILE" \
      > "${PENDING_DIR}/$(date -u +%s%N)-${STAMP_PID}" 2>/dev/null || true

    if has_active_orchestra_session; then
      printf '{"event":"start","stage":"%s","subagent":"%s","logfile":"%s",%s}\n' \
        "$STAGE" "$SUBAGENT" "$LOGFILE" "$(stamp_fields)" \
        >> "$INVOCATIONS_LOG" 2>/dev/null || true
    fi

    # Advisory orphan check — surfaces shell work left running by PREVIOUS subagents at the
    # moment a new one is dispatched. SubagentStop cannot serve here: the hook fires at
    # finalisation, and finalisation is exactly what an orphaned child blocks.
    #
    # Report only. A hook must never kill a process on its own initiative, and it must never
    # block a dispatch, hence `timeout`.
    if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/check-orphans.sh" ]; then
      _ORPHAN_OUT="$(timeout 5 bash "${SCRIPT_DIR}/check-orphans.sh" 2>/dev/null || true)"
      _ORPHAN_N="$(printf '%s' "$_ORPHAN_OUT" \
        | sed -n 's/^check-orphans: \([0-9][0-9]*\) orphan.*/\1/p' | head -n 1)"
      if [ -n "$_ORPHAN_N" ]; then
        printf '{"event":"orphans","count":"%s","stage":"%s",%s}\n' \
          "$_ORPHAN_N" "$STAGE" "$(stamp_fields)" \
          >> "$INVOCATIONS_LOG" 2>/dev/null || true
      fi
    fi

    # T1 telemetry: append start-event to active session's telemetry-events.jsonl
    ACTIVE_SESSION_DIR="$(find_active_session_dir)"
    # (8c) Session-identity gate: prefer payload's .session_id, else STAMP_SESSION
    CURRENT_SID="$(printf '%s' "$INPUT_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
    if [ -z "$CURRENT_SID" ]; then
      CURRENT_SID="$STAMP_SESSION"
    fi
    # Override STAMP_SESSION with the actual transcript UUID if available
    if [ -n "$ACTIVE_SESSION_DIR" ] && [ -f "${ACTIVE_SESSION_DIR}/.transcript-uuid" ]; then
        STAMP_SESSION="$(cat "${ACTIVE_SESSION_DIR}/.transcript-uuid" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [ -n "$ACTIVE_SESSION_DIR" ] && should_append_t1_event "$ACTIVE_SESSION_DIR" "$CURRENT_SID"; then
      printf '{"event":"start","subagent":"%s","stage":"%s",%s}\n' \
        "$SUBAGENT" "$STAGE" "$(stamp_fields)" \
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
    # (8a) Attribution cascade: documented field → sidecar fallback → unknown
    # (a) Documented top-level field — populated for real dispatched subagents.
    #     Capture jq's exit status separately: an empty result means "no agent_type"
    #     (an internal helper agent, safe to drop), but a NON-ZERO status means jq itself
    #     failed, and dropping a real subagent's event on a parse failure would lose
    #     telemetry silently. Those two cases must not be conflated.
    SUBAGENT="$(printf '%s' "$INPUT_JSON" | jq -r '.agent_type // empty' 2>/dev/null)"
    JQ_STATUS=$?

    # (b) Belt-and-braces: derive agent-<id>.meta.json from .agent_transcript_path and read
    #     its agentType — the same field telemetry-summarize.py reads for T2.
    if [ -z "$SUBAGENT" ]; then
      AGENT_TRANSCRIPT_PATH="$(printf '%s' "$INPUT_JSON" | jq -r '.agent_transcript_path // empty' 2>/dev/null || true)"
      if [ -n "$AGENT_TRANSCRIPT_PATH" ]; then
        META_PATH="$(dirname "$AGENT_TRANSCRIPT_PATH")/$(basename "$AGENT_TRANSCRIPT_PATH" .jsonl).meta.json"
        if [ -f "$META_PATH" ]; then
          SUBAGENT="$(jq -r '.agentType // empty' "$META_PATH" 2>/dev/null || true)"
        fi
      fi
    fi

    # (c) Neither the payload field nor the sidecar resolved a type. This is one of
    #     Claude Code's own internal helper agents (suggestion generator, or the
    #     per-background-task status describer), which fire SubagentStop on a ~31s
    #     cadence while a background task is alive, carry an empty agent_type, and
    #     have no agent-<id>.meta.json sidecar. They are not orchestra subagents.
    #     Drop the firing entirely rather than recording it as "unknown" — and do it
    #     HERE, before the $LAST_LOGFILE_REF sidecar below is read and deleted, so
    #     internal firings no longer consume another subagent's logfile reference.
    if [ -z "$SUBAGENT" ]; then
      if [ "$JQ_STATUS" -ne 0 ]; then
        # jq failed — record a visible event rather than dropping it silently, matching
        # the pre-2026-09-19 behaviour. A malformed payload is a real anomaly and must
        # remain observable.
        SUBAGENT="unknown"
      else
        # Genuine internal helper agent (see comment above) — drop the firing.
        exit 0
      fi
    fi
    STAGE="$(stage_for_subagent "$SUBAGENT")"

    # Consume a pending marker ONLY for an identified subagent.
    #
    # `unknown` reaches here when jq failed to read .agent_type (the empty-but-jq-succeeded
    # case already exited above as an internal helper). Such events outnumber real agents by
    # roughly 5:1 — 1784 of 2086 end events in one measured project — and previously they fell
    # through to the sidecar read and DELETED a live agent's logfile. That is the main reason
    # starts went unmatched, ahead of concurrency.
    LOGFILE=""
    if [ "$SUBAGENT" != "unknown" ]; then
      PENDING_DIR="${ORCHESTRA_DIR}/.pending-agents/${STAGE}"
      _MARKER="$(ls -1 "$PENDING_DIR" 2>/dev/null | sort | head -n 1)"
      if [ -n "$_MARKER" ] && [ -f "${PENDING_DIR}/${_MARKER}" ]; then
        LOGFILE="$(cat "${PENDING_DIR}/${_MARKER}" 2>/dev/null || true)"
        rm -f "${PENDING_DIR}/${_MARKER}" 2>/dev/null || true
      elif [ -f "$LAST_LOGFILE_REF" ]; then
        # Legacy fallback: this dispatch's `start` ran under pre-fix code (e.g. a deploy
        # landed mid-flight). Read the old single-slot sidecar rather than orphan the agent.
        LOGFILE="$(cat "$LAST_LOGFILE_REF" 2>/dev/null || true)"
        rm -f "$LAST_LOGFILE_REF" 2>/dev/null || true
      fi
    fi

    if [ -n "$LOGFILE" ] && [ -f "$LOGFILE" ]; then
      {
        echo ""
        echo "---"
        echo "## ✓ done — ${STAMP_TS}"
      } >> "$LOGFILE" 2>/dev/null || true
    fi

    # An unidentified end now resolves no logfile, so its line would carry no information at
    # all — stage "agent", subagent "unknown", empty logfile. Suppress it. This removes
    # 86-93% of invocations.log volume and is what makes a bounded tail read meaningful for
    # the status line. T1 telemetry below is unaffected and still records the event.
    if [ "$SUBAGENT" != "unknown" ] && has_active_orchestra_session; then
      printf '{"event":"end","stage":"%s","subagent":"%s","logfile":"%s",%s}\n' \
        "$STAGE" "$SUBAGENT" "$LOGFILE" "$(stamp_fields)" \
        >> "$INVOCATIONS_LOG" 2>/dev/null || true
    fi

    # T1 telemetry: append end-event to active session's telemetry-events.jsonl
    ACTIVE_SESSION_DIR="$(find_active_session_dir)"
    # (8c) Session-identity gate: prefer payload's .session_id, else STAMP_SESSION
    CURRENT_SID="$(printf '%s' "$INPUT_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
    if [ -z "$CURRENT_SID" ]; then
      CURRENT_SID="$STAMP_SESSION"
    fi
    # Override STAMP_SESSION with the actual transcript UUID if available
    if [ -n "$ACTIVE_SESSION_DIR" ] && [ -f "${ACTIVE_SESSION_DIR}/.transcript-uuid" ]; then
        STAMP_SESSION="$(cat "${ACTIVE_SESSION_DIR}/.transcript-uuid" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [ -n "$ACTIVE_SESSION_DIR" ] && should_append_t1_event "$ACTIVE_SESSION_DIR" "$CURRENT_SID"; then
      printf '{"event":"end","subagent":"%s","stage":"%s",%s}\n' \
        "$SUBAGENT" "$STAGE" "$(stamp_fields)" \
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
