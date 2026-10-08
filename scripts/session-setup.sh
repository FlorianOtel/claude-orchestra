#!/usr/bin/env bash
# session-setup.sh — open a /duo or /brain session: create the session dir,
# write the inflight marker, record the transcript identity, register the .lck.
#
# Usage:  session-setup.sh <duo|brain> "<task description>"
#
# Why this is a script and not a bash block inside commands/*.md: a model that
# is handed a long block to retype will sometimes "shorten" it. That happened
# (AYA session 20261008T092158Z-3274438): the transcript-UUID step was dropped,
# the status line judged the .duo-inflight marker stale, and no badge appeared.
# Here the steps cannot be skipped, and the script checks its own invariants.
#
# Output (stdout), exactly one of:
#   REFUSE: ...         another /duo session is active (duo only) — stop
#   SETUP_FAILED: ...   an invariant did not hold; marker removed — stop
#   SETUP_OK            followed by session_dir=... and retention_days=...
set -u

MODE="${1:-}"
TASK="${2:-}"
case "$MODE" in
  duo|brain) ;;
  *) echo "SETUP_FAILED: usage: session-setup.sh <duo|brain> \"<task>\""; exit 0 ;;
esac

# Title for the marker: strip single quotes, printable characters only, 30 chars.
TITLE="$(printf '%s' "$TASK" | tr -d "'" | tr -cd '[:print:]' | cut -c1-30)"

# CLAUDE_PROJECT_DIR may be unset in Bash subprocesses — resolve it first.
CLAUDE_PROJECT_DIR="$(realpath "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$(pwd)}")"
SESSIONS_ROOT="${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions"
MARKER_NAME=".${MODE}-inflight"

# ── Refusal: one active /duo session per project ─────────────────────────────
if [ "$MODE" = "duo" ] && [ -d "$SESSIONS_ROOT" ]; then
  EXISTING="$(find "$SESSIONS_ROOT" -mindepth 2 -maxdepth 2 -name '.duo-inflight' 2>/dev/null | head -1)"
  if [ -n "$EXISTING" ]; then
    echo "REFUSE: an active /duo session already exists at:"
    echo "  $(dirname "$EXISTING")"
    echo "Run /duo-act to commit it, or /duo-abandon to cancel, before /duo-plan."
    exit 0
  fi
fi

# ── Retention window: per-project override > global default > 30 ─────────────
_parse_retention() {
  awk '
    /^housekeeping:/ { in_hk = 1; next }
    in_hk && /^[^ ]/ { in_hk = 0 }
    in_hk && /session_retention_days:/ {
      gsub(/[^0-9]/, "", $2); print $2; exit
    }
  ' "$1" 2>/dev/null
}
RETENTION_DAYS=$(_parse_retention "${CLAUDE_PROJECT_DIR}/.claude/orchestra/config.yaml")
[ -z "${RETENTION_DAYS}" ] && \
  RETENTION_DAYS=$(_parse_retention "${HOME}/.claude/orchestra/config.yaml")
RETENTION_DAYS="${RETENTION_DAYS:-30}"

# Lazy cleanup: drop session subdirs older than the retention window.
if [ -d "${SESSIONS_ROOT}" ]; then
  find "${SESSIONS_ROOT}" -mindepth 1 -maxdepth 1 -type d \
       -mtime +"${RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null
fi

# ── Session directory ────────────────────────────────────────────────────────
SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SESSION_DIR="${SESSIONS_ROOT}/${SESSION_ID}"
mkdir -p "${SESSION_DIR}" || { echo "SETUP_FAILED: cannot create ${SESSION_DIR}"; exit 0; }

_fail() {
  rm -f "${SESSION_DIR}/${MARKER_NAME}" "${SESSION_DIR}/${MARKER_NAME}.tmp" \
        "${HOME}/.claude/active-sessions/${SESSION_ID}.lck"
  echo "SETUP_FAILED: $1"
  exit 0
}

# ── Transcript identity ──────────────────────────────────────────────────────
# Written BEFORE the inflight marker: the status line treats a marker without a
# .transcript-uuid as stale, so a marker must never exist without one.
# Prefer the session id CC exports to Bash subprocesses; fall back to the newest
# transcript in the project's transcript dir (wrong if two CC sessions share it).
_MANGLED="$(printf '%s' "${CLAUDE_PROJECT_DIR}" | tr '/' '-')"
_TRANSCRIPTS="${HOME}/.claude/projects/${_MANGLED}"
_TRANSCRIPT_UUID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$_TRANSCRIPT_UUID" ] && [ -f "${_TRANSCRIPTS}/${_TRANSCRIPT_UUID}.jsonl" ]; then
  printf '%s\n' "${_TRANSCRIPTS}/${_TRANSCRIPT_UUID}.jsonl" > "${SESSION_DIR}/.transcript-path"
else
  _LATEST="$(ls -t "${_TRANSCRIPTS}"/*.jsonl 2>/dev/null | head -1)"
  if [ -n "$_LATEST" ]; then
    _TRANSCRIPT_UUID="$(basename "$_LATEST" .jsonl)"
    printf '%s\n' "$_LATEST" > "${SESSION_DIR}/.transcript-path"
  fi
fi
[ -n "$_TRANSCRIPT_UUID" ] || _fail "could not determine the session transcript UUID (looked in ${_TRANSCRIPTS})"
printf '%s\n' "$_TRANSCRIPT_UUID" > "${SESSION_DIR}/.transcript-uuid" \
  || _fail "cannot write .transcript-uuid"

# ── Inflight marker (atomic rename) ──────────────────────────────────────────
# Stays live until removed by /duo-act, /duo-abandon, the /brain cleanup block
# or /brain-abandon.
printf '%s' "$TITLE" > "${SESSION_DIR}/${MARKER_NAME}.tmp" \
  && mv -f "${SESSION_DIR}/${MARKER_NAME}.tmp" "${SESSION_DIR}/${MARKER_NAME}" \
  || _fail "cannot write ${MARKER_NAME}"

# brain: mode + title for the status-line badge.
if [ "$MODE" = "brain" ]; then
  mkdir -p "${CLAUDE_PROJECT_DIR}/.claude/orchestra"
  printf 'ORCHESTRA_MODE=brain\nORCHESTRA_TITLE=%s\n' "$TITLE" \
    >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"
fi

# ── Per-session lock file (otelHeadersHelper session attribution) ────────────
# cc_pid is the long-lived `claude` process, used only for liveness. $PPID is
# NOT it here (we run as a child of the Bash tool's shell), so walk up to it.
. "$(dirname "${BASH_SOURCE[0]}")/lib/os.sh"
_cc_pid="$PPID"
_p="$$"
for _ in 1 2 3 4 5 6 7 8; do
  _p="$(orchestra_pid_ppid "$_p")"
  [ -n "$_p" ] && [ "$_p" -gt 1 ] 2>/dev/null || break
  if [ "$(orchestra_pid_comm "$_p")" = "claude" ]; then _cc_pid="$_p"; break; fi
done
mkdir -p "${HOME}/.claude/active-sessions"
printf 'cc_pid=%s\n' "$_cc_pid" > "${HOME}/.claude/active-sessions/${SESSION_ID}.lck.tmp" \
  && mv -f "${HOME}/.claude/active-sessions/${SESSION_ID}.lck.tmp" \
           "${HOME}/.claude/active-sessions/${SESSION_ID}.lck" \
  || _fail "cannot write ${SESSION_ID}.lck"
# Housekeeping: remove lck files whose CC process is no longer running.
for _f in "${HOME}/.claude/active-sessions/"*.lck; do
  [ -f "$_f" ] || continue
  _pid="$(grep '^cc_pid=' "$_f" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
  kill -0 "$_pid" 2>/dev/null || rm -f "$_f"
done

# ── Self-verification: the invariants the status line depends on ─────────────
[ -f "${SESSION_DIR}/${MARKER_NAME}" ]                       || _fail "${MARKER_NAME} missing after write"
[ -s "${SESSION_DIR}/.transcript-uuid" ]                     || _fail ".transcript-uuid missing or empty"
[ -f "${HOME}/.claude/active-sessions/${SESSION_ID}.lck" ]   || _fail "${SESSION_ID}.lck missing after write"

echo "SETUP_OK"
echo "session_dir=${SESSION_DIR}"
echo "retention_days=${RETENTION_DAYS}"
