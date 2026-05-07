#!/usr/bin/env bash
# bash-session-init.sh — sourced via BASH_ENV on every CC Bash tool call.
# Registers the native session .lck on first call, using UUID as primary key.
# cc_pid (stable CC main process) is stored for liveness checking only.

_uuid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$_uuid" ]; then return 0 2>/dev/null || exit 0; fi

_sessions_dir="${HOME}/.claude/active-sessions"
_lck="${_sessions_dir}/native-${_uuid}.lck"
[ -f "$_lck" ] && return 0   # already registered this session

# Skip if inside an active orchestra session (avoid double-counting with orchestra telemetry).
find "${HOME}/.claude/orchestra/sessions" \
    \( -name ".brain-inflight" -o -name ".duo-inflight" \) \
    2>/dev/null | grep -q . && return 0

# Find stable CC main PID (top-level 'claude' process, not ephemeral node subprocesses).
# Normal case: PPID is the claude process directly.
# Ephemeral case: PPID is a transient node subprocess whose parent is claude.
_cc_main_pid=$PPID
_ppid_comm=$(cat /proc/$PPID/comm 2>/dev/null)
if [ "$_ppid_comm" != "claude" ]; then
    _parent=$(awk '{print $4}' /proc/$PPID/stat 2>/dev/null)
    _parent_comm=$(cat /proc/$_parent/comm 2>/dev/null)
    [ "$_parent_comm" = "claude" ] && _cc_main_pid=$_parent
fi

mkdir -p "$_sessions_dir" "${HOME}/.claude/native-sessions" 2>/dev/null || return 0

_sat="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_sid="native-${_uuid}"

printf 'cc_pid=%s\nsession_id=%s\nstarted_at=%s\nsession_uuid=%s\n' \
    "$_cc_main_pid" "$_sid" "$_sat" "$_uuid" \
    > "${_lck}.tmp" 2>/dev/null \
    && mv -f "${_lck}.tmp" "$_lck" 2>/dev/null || true

printf '{"session_id":"%s","cc_pid":%s,"started_at":"%s"}\n' \
    "$_sid" "$_cc_main_pid" "$_sat" \
    >> "${HOME}/.claude/native-sessions/sessions.jsonl" 2>/dev/null || true
