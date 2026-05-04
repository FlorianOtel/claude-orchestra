#!/usr/bin/env bash
# telemetry-summarize.sh — wrapper that activates the project venv and runs the Python parser.
# Usage: telemetry-summarize.sh <session_dir> <command> <outcome> [transcript_session_id]
#
# Designed to be invoked from /duo Phase 4 cleanup, /brain Phase 3 cleanup, and
# orchestra-hook.sh stop mode.
#
# chmod +x me after deploy

set -uo pipefail

VENV="${HOME}/Gin-AI/.Gin-AI-python-3.12"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="${SCRIPT_DIR}/telemetry-summarize.py"

if [ ! -d "$VENV" ]; then
    echo "telemetry-summarize.sh: venv not found at $VENV — skipping" >&2
    exit 0
fi

if [ ! -f "$PY_SCRIPT" ]; then
    echo "telemetry-summarize.sh: parser not found at $PY_SCRIPT — skipping" >&2
    exit 0
fi

# Pass through CLAUDE_SESSION_ID if not explicitly given as 4th arg
TRANSCRIPT_ID="${4:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"

# Belt-and-suspenders: fall back to UUID captured at session creation
if [ -z "$TRANSCRIPT_ID" ] && [ -n "${1:-}" ] && [ -f "$1/.transcript-uuid" ]; then
    TRANSCRIPT_ID="$(cat "$1/.transcript-uuid" 2>/dev/null || true)"
fi

"${VENV}/bin/python3" "$PY_SCRIPT" "$1" "$2" "$3" "$TRANSCRIPT_ID"
