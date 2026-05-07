#!/usr/bin/env bash
# bash-session-init.sh — sourced via BASH_ENV at start of every CC Bash tool call.
# Registers the CC session UUID so the Stop hook can find it for native telemetry.
#
# BASH_ENV is sourced by bash for non-interactive shells. CC Bash tool calls are
# non-interactive, so this runs automatically. CLAUDE_CODE_SESSION_ID is injected
# by CC for Bash tool calls but NOT for hooks — this bridges the two contexts.
#
# Written to: ~/.claude/active-sessions/uuid-<CC_MAIN_PID> (sidecar file)
# Read by:    orchestra-hook.sh stop (reads /proc/NODE_PID/stat to get CC main PID)

_uuid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$_uuid" ]; then return 0 2>/dev/null || exit 0; fi  # not a CC Bash call, skip

_cc_main_pid="$PPID"   # PPID of the Bash call = CC main process
_sessions_dir="${HOME}/.claude/active-sessions"
mkdir -p "$_sessions_dir" 2>/dev/null || return 0

_sidecar="${_sessions_dir}/uuid-${_cc_main_pid}"
if [ ! -f "$_sidecar" ]; then
    printf '%s\n' "$_uuid" > "${_sidecar}.tmp" 2>/dev/null \
        && mv -f "${_sidecar}.tmp" "$_sidecar" 2>/dev/null || true
fi
