#!/usr/bin/env bash
# orchestra-cleanup.sh — single-call session cleanup for /brain and /duo.
#
# Consolidates all end-of-session steps so the LLM cannot shortcut by running
# only a subset of cleanup actions. Either the whole script runs and all
# artifacts are produced, or nothing is produced.
#
# Usage: orchestra-cleanup.sh <session_dir> <outcome>
#   session_dir: absolute path to the orchestra session subdirectory
#   outcome:     pass | fix-loop | block | abandoned | partial
#
# Steps (ordered, all mandatory):
#   1. Write .outcome (atomic rename) — mtime bounds T2 time window
#   2. Remove active-sessions lck — stops otelHeadersHelper header injection
#   3. Auto-detect command type (brain vs duo) from inflight marker presence
#   4. Run telemetry-summarize.sh (before removing inflight marker)
#   5. Verify telemetry.json exists; retry once if not; log .cleanup-error on failure
#   6. Remove inflight marker (.brain-inflight or .duo-inflight)
#   7. Append ORCHESTRA_MODE=default to the OWNING project's state.env (clears its badge)

set -euo pipefail

SESSION_DIR="${1:?Usage: orchestra-cleanup.sh <session_dir> <outcome>}"
OUTCOME="${2:?Usage: orchestra-cleanup.sh <session_dir> <outcome>}"
# CLAUDE_PROJECT_DIR may be unset when called from a Bash tool call in a later turn.
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The badge belongs to the project that OWNS the session, which is not necessarily the
# project this script is invoked from. Deriving it from CLAUDE_PROJECT_DIR meant a cleanup
# run from a second project wrote the clear into that project's state.env and left the
# owning project's badge stuck on ORCHESTRA_MODE=brain indefinitely. Observed 2026-09-22
# closing a /brain session from a fork that had moved to a different project.
#
# Session dirs are always <project>/.claude/orchestra/sessions/<id>, so strip that suffix.
SESSION_PROJECT_DIR="${SESSION_DIR%/.claude/orchestra/sessions/*}"
if [ "$SESSION_PROJECT_DIR" = "$SESSION_DIR" ] || [ ! -d "${SESSION_PROJECT_DIR}/.claude/orchestra" ]; then
  # Non-standard layout — fall back rather than write somewhere unexpected.
  SESSION_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
fi

# Validate outcome value.
case "$OUTCOME" in
  pass|fix-loop|block|abandoned|partial) ;;
  *) echo "orchestra-cleanup.sh: unknown outcome '${OUTCOME}'" >&2; exit 1 ;;
esac

# Step 1: Write .outcome (atomic rename). Mtime bounds the T2 transcript window.
printf '%s' "$OUTCOME" > "${SESSION_DIR}/.outcome.tmp"
mv -f "${SESSION_DIR}/.outcome.tmp" "${SESSION_DIR}/.outcome"

# Step 2: Remove active-sessions lck so otelHeadersHelper stops injecting the header.
rm -f "${HOME}/.claude/active-sessions/$(basename "${SESSION_DIR}").lck"

# Step 3: Auto-detect command type from inflight marker.
COMMAND="brain"
INFLIGHT_FILE="${SESSION_DIR}/.brain-inflight"
if [ -f "${SESSION_DIR}/.duo-inflight" ]; then
  COMMAND="duo"
  INFLIGHT_FILE="${SESSION_DIR}/.duo-inflight"
fi

# Step 4: Run telemetry summariser BEFORE removing inflight marker so telemetry.json
# is guaranteed present when the next status-line render detects the section transition
# (accumulator reconciles against cost_usd_estimate).
TRANSCRIPT_ID="$(cat "${SESSION_DIR}/.transcript-uuid" 2>/dev/null || true)"
"${SCRIPT_DIR}/telemetry-summarize.sh" \
  "$SESSION_DIR" "$COMMAND" "$OUTCOME" "$TRANSCRIPT_ID" 2>&1 | tail -n 1

# Step 5: Verify telemetry.json was written; retry once if not.
if [ ! -f "${SESSION_DIR}/telemetry.json" ]; then
  echo "WARN: telemetry.json missing after first summariser run — retrying" >&2
  "${SCRIPT_DIR}/telemetry-summarize.sh" \
    "$SESSION_DIR" "$COMMAND" "$OUTCOME" "$TRANSCRIPT_ID" 2>&1 | tail -n 1
  if [ ! -f "${SESSION_DIR}/telemetry.json" ]; then
    echo "ERROR: telemetry.json still missing — writing .cleanup-error" >&2
    printf 'telemetry.json missing after two summariser attempts at %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${SESSION_DIR}/.cleanup-error"
  fi
fi

# Step 6: Remove inflight marker. Badge clears on next status-line render.
rm -f "$INFLIGHT_FILE"

# Step 7: Clear the pipeline badge in the OWNING project's state.env.
printf 'ORCHESTRA_MODE=default\nORCHESTRA_TITLE=\n' \
  >> "${SESSION_PROJECT_DIR}/.claude/orchestra/state.env"

# Name the project the badge was cleared in. When it differs from where the script was
# invoked, say so — silence is what let the original mismatch go unnoticed.
if [ "$(realpath "$SESSION_PROJECT_DIR" 2>/dev/null)" != "$(realpath "$CLAUDE_PROJECT_DIR" 2>/dev/null)" ]; then
  echo "cleanup: note — session is owned by $(basename "${SESSION_PROJECT_DIR}"), invoked from $(basename "${CLAUDE_PROJECT_DIR}"); badge cleared in the owner"
fi

echo "cleanup: ${COMMAND} outcome=${OUTCOME} session=$(basename "${SESSION_DIR}") project=$(basename "${SESSION_PROJECT_DIR}")"
