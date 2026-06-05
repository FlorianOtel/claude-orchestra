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
#   7. Append ORCHESTRA_MODE=default to state.env (clears status-line badge)

set -euo pipefail

SESSION_DIR="${1:?Usage: orchestra-cleanup.sh <session_dir> <outcome>}"
OUTCOME="${2:?Usage: orchestra-cleanup.sh <session_dir> <outcome>}"
# CLAUDE_PROJECT_DIR may be unset when called from a Bash tool call in a later turn.
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Step 7: Clear the pipeline badge in state.env.
printf 'ORCHESTRA_MODE=default\nORCHESTRA_TITLE=\n' \
  >> "${CLAUDE_PROJECT_DIR}/.claude/orchestra/state.env"

echo "cleanup: ${COMMAND} outcome=${OUTCOME} session=$(basename "${SESSION_DIR}")"
