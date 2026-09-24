#!/usr/bin/env bash
# session-report.sh — unified cost report: native + orchestra sessions.
# Usage: session-report.sh [--last N] [--since DATE] [--month YYYY-MM] [--source native|orchestra|all]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/os.sh"
VENV="$(orchestra_venv_dir)"
PY_SCRIPT="${SCRIPT_DIR}/session-report.py"

if [ ! -d "$VENV" ]; then
    echo "session-report.sh: venv not found at $VENV" >&2
    exit 1
fi

if [ ! -f "$PY_SCRIPT" ]; then
    echo "session-report.sh: script not found at $PY_SCRIPT" >&2
    exit 1
fi

"${VENV}/bin/python3" "$PY_SCRIPT" "$@"
