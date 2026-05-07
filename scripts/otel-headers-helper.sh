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
printf '{}\n'
