#!/usr/bin/env bash
# native-session-report.sh — cost report for all Claude Code sessions (not just orchestra).
#
# Usage:
#   native-session-report.sh [--last N] [--since YYYY-MM-DD] [--month YYYY-MM]
#                            [--project PATH] [--tier] [--json] [--min-cost X]
#                            [--exclude-orchestra]
#
# Invokes the venv-wrapped Python parser.

set -uo pipefail

VENV="${HOME}/Gin-AI/.Gin-AI-python-3.12"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="${SCRIPT_DIR}/native-session-report.py"

if [ ! -d "$VENV" ]; then
    echo "native-session-report.sh: venv not found at $VENV" >&2
    exit 1
fi

if [ ! -f "$PY_SCRIPT" ]; then
    echo "native-session-report.sh: parser not found at $PY_SCRIPT" >&2
    exit 1
fi

"${VENV}/bin/python3" "$PY_SCRIPT" "$@"
