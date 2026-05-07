#!/usr/bin/env bash
# otelHeadersHelper — injects X-Orchestra-Session-ID for active orchestra sessions.
# Registered as otelHeadersHelper in ~/.claude/settings.json.
# Claude Code calls this per API request (debounced); output must be valid JSON.
#
# Each active session writes ~/.claude/active-sessions/<session-id>.lck
# containing cc_pid=<PID> where PID is the Claude Code process PID ($PPID from
# any Bash tool call in that session). This script finds its own session's lck
# file by matching $PPID against the cc_pid= value in each lck file.
SESSIONS_DIR="${HOME}/.claude/active-sessions"
if [ -d "${SESSIONS_DIR}" ]; then
    for f in "${SESSIONS_DIR}"/*.lck; do
        [ -f "$f" ] || continue
        stored_pid="$(grep '^cc_pid=' "$f" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
        if [ "${stored_pid}" = "${PPID}" ]; then
            session_id="$(basename "${f%.lck}")"
            printf '{"X-Orchestra-Session-ID": "%s"}\n' "${session_id}"
            exit 0
        fi
    done
fi

# No orchestra .lck for this PPID — auto-create native session entry.
mkdir -p "${HOME}/.claude/native-sessions"
_native_lck="${SESSIONS_DIR}/native-${PPID}.lck"
if [ ! -f "${_native_lck}" ]; then
    _session_ts="$(date -u +%Y%m%dT%H%M%SZ)"
    _session_id="native-${_session_ts}-${PPID}"
    _started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cc_pid=%s\nsession_id=%s\nstarted_at=%s\n' \
        "${PPID}" "${_session_id}" "${_started_at}" \
        > "${_native_lck}.tmp"
    mv -f "${_native_lck}.tmp" "${_native_lck}"
    # Append to persistent session registry.
    printf '{"session_id":"%s","cc_pid":%s,"started_at":"%s"}\n' \
        "${_session_id}" "${PPID}" "${_started_at}" \
        >> "${HOME}/.claude/native-sessions/sessions.jsonl"
fi
_session_id="$(grep '^session_id=' "${_native_lck}" 2>/dev/null \
    | cut -d= -f2 | tr -d '[:space:]')"
if [ -n "${_session_id}" ]; then
    printf '{"X-Orchestra-Session-ID": "%s"}\n' "${_session_id}"
else
    printf '{}\n'
fi
