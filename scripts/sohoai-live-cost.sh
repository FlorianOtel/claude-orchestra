#!/usr/bin/env bash
# sohoai-live-cost.sh — Orchestra session cost via SoHoAI usage_events (SQLite→HTTP) with cache+TTL+fallback
#
# Usage: sohoai-live-cost.sh <session_id> <started_at_unix> <cache_file>
#
# Prints a cost string and exits 0 in all cases (any failure → empty output).
# Cache-hit path is very fast (<50ms). SoHoAI query has <2s timeout (SQLite direct or HTTP).
#
# Output formats:
#   ~$X.YZ      — fresh result from SoHoAI usage_events (SQLite direct or HTTP)
#   ~$X.YZ*     — stale cached value (all sources failed)
#   (empty)     — all sources exhausted

TTL=8
PYTHON3="${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3"

session_id="${1:-}"
started_at_unix="${2:-}"
cache_file="${3:-}"

# Guard: all args required
if [ -z "$session_id" ] || [ -z "$started_at_unix" ] || [ -z "$cache_file" ]; then
    exit 0
fi

# ── A. Cache check ──────────────────────────────────────────────────────────
stale_val=""
if [ -f "$cache_file" ]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo "0")
    age=$((now - mtime))
    if [ "$age" -le "$TTL" ]; then
        cat "$cache_file" 2>/dev/null || true
        exit 0
    fi
    # Stale: stash for fallback
    stale_val=$(cat "$cache_file" 2>/dev/null || true)
fi

# ── B. Cost from SoHoAI usage_events (SQLite direct → HTTP fallback) ──────────
#
# Started_at: use .transcript-path mtime — it's written once at session init,
# giving a reliable lower bound regardless of the session dir's ever-changing mtime.
cost=""
_tp_file="$(dirname "$cache_file")/.transcript-path"
_real_started_at="$started_at_unix"
if [ -f "$_tp_file" ]; then
    _real_started_at=$(stat -c %Y "$_tp_file" 2>/dev/null || echo "$started_at_unix")
fi

cost=$("$PYTHON3" - "$session_id" "$_real_started_at" "$cache_file" <<'PYEOF' 2>/dev/null
import sys, os, time, sqlite3, importlib.util
from pathlib import Path

session_id  = sys.argv[1]
started_at  = float(sys.argv[2])
cache_file  = sys.argv[3]
ended_at    = time.time()

# ── Try 1: SoHoAI SQLite DB (direct, accurate, no HTTP timeout) ──────────────
ts_path = os.path.expanduser("~/.claude/scripts/telemetry-summarize.py")
spec = importlib.util.spec_from_file_location("ts", ts_path)
ts   = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)

cfg     = ts._load_sohoai_config()
db_path = os.environ.get("SOHOAI_DB_PATH", "") or cfg.get("db_path", "")

if db_path and Path(db_path).exists():
    try:
        uri = Path(db_path).as_uri() + "?mode=ro"
        with sqlite3.connect(uri, uri=True) as conn:
            row = conn.execute(
                "SELECT SUM(cost_usd) FROM usage_events WHERE orchestra_session_id=?",
                (session_id,)
            ).fetchone()
            if row and row[0] and float(row[0]) > 0:
                print(f"{float(row[0]):.4f}")
                sys.exit(0)
    except Exception:
        pass

# ── Try 2: SoHoAI HTTP API (fallback; started_at already corrected above) ────
base_url = os.environ.get("ANTHROPIC_BASE_URL", "").rstrip("/")
if base_url:
    r = ts.query_sohoai_cost(session_id, started_at, ended_at, base_url, timeout_s=1)
    if r is not None and r > 0:
        print(f"{r:.4f}")
PYEOF
) || true

# ── C. Result handling ──────────────────────────────────────────────────────

# Helper: atomic cache write + print
_atomic_cache_and_print() {
    local val="$1"
    local suffix="${2:-}"
    formatted=$(LC_ALL=C printf '~$%.2f' "$val")
    cache_tmp="${cache_file}.tmp"
    if printf '%s' "$formatted" > "$cache_tmp" 2>/dev/null; then
        mv -f "$cache_tmp" "$cache_file" 2>/dev/null || true
    fi
    printf '%s%s' "$formatted" "$suffix"
}

# C1. Fresh SoHoAI result
if [ -n "$cost" ] && printf '%s' "$cost" | grep -qE '^[0-9]+\.?[0-9]*$'; then
    _atomic_cache_and_print "$cost" ""
    exit 0
fi

# C2. Stale cache fallback
if [ -n "$stale_val" ]; then
    printf '%s' "${stale_val}*"
    exit 0
fi

# All sources exhausted
exit 0
