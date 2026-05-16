#!/usr/bin/env bash
# sohoai-live-cost.sh — Orchestra + native session cost/tokens via SoHoAI usage_events
#
# Usage: sohoai-live-cost.sh <session_id> <started_at_unix> <cache_file> [model_filter] [output_mode]
#
#   session_id       — Session ID (orchestra dir name, or native-<uuid>)
#   started_at_unix  — Unix epoch start time (from .lck or session dir ctime)
#   cache_file       — Path to TTL cache file
#   model_filter     — Model name filter (e.g. "kimi-k2.6") for native sessions
#   output_mode      — "cost" (default) prints "~$X.YZ"; "tokens" prints raw int
#
# Prints requested value and exits 0 in all cases (any failure → empty output).
# Cache-hit path is very fast (<50ms). SoHoAI query has <2s timeout (SQLite direct or HTTP).

TTL=8
PYTHON3="${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3"

session_id="${1:-}"
started_at_unix="${2:-}"
cache_file="${3:-}"
model_filter="${4:-}"
output_mode="${5:-cost}"

# Guard: required args
if [ -z "$session_id" ] || [ -z "$started_at_unix" ] || [ -z "$cache_file" ]; then
    exit 0
fi

# ── A. Cache check (JSON: {"cost":"~$X.YZ","tokens":123456}) ────────────────
stale_val=""
stale_tokens=""
if [ -f "$cache_file" ]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo "0")
    age=$((now - mtime))
    # Read once before branching
    _cached=$(cat "$cache_file" 2>/dev/null || true)
    if [ "$age" -le "$TTL" ]; then
        if [ "$output_mode" = "tokens" ]; then
            _tok=$(printf '%s' "$_cached" | "$PYTHON3" -c "import json,sys; print(json.load(sys.stdin).get('tokens',0))")
            [ -n "$_tok" ] && printf '%s' "$_tok" || true
        else
            _cst=$(printf '%s' "$_cached" | "$PYTHON3" -c "import json,sys; print(json.load(sys.stdin).get('cost',''))")
            [ -n "$_cst" ] && printf '%s' "$_cst" || true
        fi
        exit 0
    fi
    # Stash stale values for fallback
    stale_val=$(printf '%s' "$_cached" | "$PYTHON3" -c "import json,sys; print(json.load(sys.stdin).get('cost',''))")
    stale_tokens=$(printf '%s' "$_cached" | "$PYTHON3" -c "import json,sys; print(json.load(sys.stdin).get('tokens',0))")
fi

# ── B. Query SoHoAI usage_events (SQLite direct → HTTP fallback) ──────────────
# Returns: "<cost_float> <token_int>" on stdout, one line
result=$("$PYTHON3" - "$session_id" "$started_at_unix" "$cache_file" "$model_filter" <<'PYEOF' 2>/dev/null
import sys, os, time, sqlite3, importlib.util, json
from pathlib import Path

session_id  = sys.argv[1]
started_at  = float(sys.argv[2])
cache_file  = sys.argv[3]
model_filter = sys.argv[4] if len(sys.argv) > 4 else ""
ended_at    = time.time()

result = {"cost": None, "tokens": 0}

# ── Try 1: SoHoAI SQLite DB (direct, accurate, no HTTP timeout) ─────────────
ts_path = os.path.expanduser("~/.claude/scripts/telemetry-summarize.py")
spec = importlib.util.spec_from_file_location("ts", ts_path)
ts   = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)

# Query the new dict-returning function
try:
    usage = ts.query_sohoai_usage(
        session_id=session_id,
        started_at_unix=started_at,
        ended_at_unix=ended_at,
        base_url=os.environ.get("ANTHROPIC_BASE_URL", "").rstrip("/"),
        timeout_s=1,
        model_filter=model_filter or None,
    )
    if usage:
        result["cost"] = usage.get("cost_usd", 0.0)
        # For the ctx bar we want latest per-request size (proxy for current
        # context), NOT cumulative tokens across all turns. latest_total_tokens
        # is the most recent request's input+output count.
        result["tokens"] = usage.get("latest_total_tokens", 0)
except Exception:
    pass

if result["cost"] is None:
    result["cost"] = 0.0

# ── Write JSON cache atomically ──────────────────────────────────────────────
if result["cost"] > 0 or result["tokens"] > 0:
    cache_tmp = cache_file + ".tmp"
    out = json.dumps({
        "cost": f'~${result["cost"]:.2f}',
        "tokens": result["tokens"],
        "ts": int(time.time()),
    })
    try:
        with open(cache_tmp, "w") as f:
            f.write(out)
        os.replace(cache_tmp, cache_file)
    except Exception:
        pass

# ── Print ────────────────────────────────────────────────────────────────────
print(f"{result['cost']:.4f} {result['tokens']}")
PYEOF
) || true

# ── C. Parse result line: "<cost> <tokens>" ───────────────────────────────────
cost_val=""
tokens_val=""
if [ -n "$result" ]; then
    cost_val=$(printf '%s' "$result" | awk '{print $1}')
    tokens_val=$(printf '%s' "$result" | awk '{print $2}')
fi

# ── D. Output based on mode ───────────────────────────────────────────────────
if [ "$output_mode" = "tokens" ]; then
    if [ -n "$tokens_val" ] && printf '%s' "$tokens_val" | grep -qE '^[0-9]+$'; then
        printf '%s' "$tokens_val"
        exit 0
    fi
    # stale fallback
    if [ -n "$stale_tokens" ]; then
        printf '%s*' "$stale_tokens"
        exit 0
    fi
else
    # cost mode
    if [ -n "$cost_val" ] && printf '%s' "$cost_val" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        if [ "$(printf '%.0f' "$cost_val")" != "0" ] 2>/dev/null; then
            LC_ALL=C printf '~$%.2f' "$cost_val"
            exit 0
        fi
    fi
    # stale fallback
    if [ -n "$stale_val" ]; then
        printf '%s*' "$stale_val"
        exit 0
    fi
fi

# All sources exhausted
exit 0
