#!/usr/bin/env bash
# sohoai-live-cost.sh — SoHoAI live cost query with cache+TTL+fallback
#
# Usage: sohoai-live-cost.sh <session_id> <started_at_unix> <cache_file>
#
# Prints a cost string and exits 0 in all cases (any failure → empty output).
# Cache-hit path is very fast (<50ms). SoHoAI query has 1s timeout.
#
# Output formats:
#   ~$X.YZ      — fresh SoHoAI result (cached)
#   ~$X.YZ*     — stale cached value (SoHoAI failed)
#   ~$X.YZ(est) — JSONL estimate fallback (SoHoAI + stale cache both failed)
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

# ── B. SoHoAI query ─────────────────────────────────────────────────────────
cost=""

if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    cost=$("$PYTHON3" - "$session_id" "$started_at_unix" <<'PYEOF' 2>/dev/null
import sys, os, time, importlib.util

session_id = sys.argv[1]
started_at = float(sys.argv[2])
ended_at = time.time()

# Import telemetry-summarize.py via importlib (hyphen in filename)
ts_path = os.path.expanduser("~/.claude/scripts/telemetry-summarize.py")
spec = importlib.util.spec_from_file_location("ts", ts_path)
ts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)

base_url = os.environ.get("ANTHROPIC_BASE_URL", "").rstrip("/")
r = ts.query_sohoai_cost(session_id, started_at, ended_at, base_url, timeout_s=1)
if r is not None and r > 0:
    print(f"{r:.4f}")
PYEOF
) || true
fi

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

# C3. JSONL estimate fallback (defence-in-depth; SoHoAI is primary for orchestra)
# Implemented for native-<UUID> sessions; orchestra sessions rely on SoHoAI.
jsonl_cost=$("$PYTHON3" - "$session_id" "$started_at_unix" <<'PYEOF' 2>/dev/null
import sys, os, time, importlib.util

session_id = sys.argv[1]
started_at = float(sys.argv[2])
ended_at = time.time()

# Only native sessions handled here; orchestra sessions rely on SoHoAI.
# (Orchestra sessions need the session_dir to read .transcript-uuid and
# walk subagents/agent-*.jsonl — the caller has that context.)
if not session_id.startswith("native-"):
    sys.exit(0)

uuid = session_id[len("native-"):]

# Import telemetry-summarize.py
ts_path = os.path.expanduser("~/.claude/scripts/telemetry-summarize.py")
spec = importlib.util.spec_from_file_location("ts", ts_path)
ts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)

# Locate transcript
jsonl_path = ts.get_transcript_path(uuid)
if not jsonl_path:
    sys.exit(0)

# Walk JSONL with a 1-hour lookback (same as native-session-finalize.py)
t2_model, t2_tokens, first_ts, _ = ts._walk_jsonl_for_tokens(
    jsonl_path, max(0.0, started_at - 3600), ended_at
)
if first_ts is None:
    sys.exit(0)

# Load pricing and compute cost
pricing_data = ts.load_pricing_yaml()
if not pricing_data or "models" not in pricing_data:
    sys.exit(0)

parent = {"model": t2_model, "tokens": t2_tokens}
warnings = []
t2_cost = ts.compute_cost(parent, [], pricing_data, warnings)
if t2_cost and t2_cost > 0:
    print(f"{t2_cost:.4f}")
PYEOF
) || true

if [ -n "$jsonl_cost" ] && printf '%s' "$jsonl_cost" | grep -qE '^[0-9]+\.?[0-9]*$'; then
    _atomic_cache_and_print "$jsonl_cost" "(est)"
    exit 0
fi

# All sources exhausted
exit 0
