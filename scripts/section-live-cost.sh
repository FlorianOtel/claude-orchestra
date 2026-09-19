#!/usr/bin/env bash
# section-live-cost.sh — total cost since SECTION_START_UNIX for a CC session.
#
# Usage: section-live-cost.sh <parent_uuid> <section_id> <section_start_unix> <cache_file>
#
# Parent term:  JSONL+pricing.yaml on ~/.claude/projects/*/<parent_uuid>.jsonl
#               with time window [section_start_unix, now]. Same code path
#               telemetry-summarize.py uses at session close for parent cost.
# Subagent term:
#   - Orchestra section (section_id is an orchestra dir basename, e.g.
#     "20260525T113420Z-526645"): SoHoAI query keyed by session_id, 5 s
#     timeout. Matches telemetry's session-end subagent source exactly
#     (cost_source="sohoai_api+t2_parent").
#   - Native section (section_id starts with "native:" or "native-"): walk
#     agent-*.jsonl files under <parent_uuid>/subagents with the time
#     window. Matches native-session-finalize.py's cost source
#     (cost_source="pricing_yaml").
#
# Cache (8 s TTL) is rewritten on every refresh, including when the result
# is 0/empty, so a stale value cannot survive past one TTL window. Caller
# (orchestra-block.sh) uses LAST_NONZERO in the section state file as the
# transient-zero fallback during the first refresh after activity ends.

TTL=8
PYTHON3="${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3"

parent_uuid="${1:-}"
section_id="${2:-}"
section_start_unix="${3:-}"
cache_file="${4:-}"

if [ -z "$parent_uuid" ] || [ -z "$section_id" ] || [ -z "$section_start_unix" ] || [ -z "$cache_file" ]; then
    exit 0
fi

# ── A. Cache check ──────────────────────────────────────────────────────────
if [ -f "$cache_file" ]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo "0")
    age=$((now - mtime))
    if [ "$age" -le "$TTL" ]; then
        cat "$cache_file" 2>/dev/null
        exit 0
    fi
fi

# ── B. Compute ──────────────────────────────────────────────────────────────
"$PYTHON3" - "$parent_uuid" "$section_id" "$section_start_unix" "$cache_file" <<'PYEOF' 2>/dev/null
import sys, os, glob, time, importlib.util
from pathlib import Path

parent_uuid = sys.argv[1]
section_id = sys.argv[2]
section_start_unix = float(sys.argv[3])
cache_file = sys.argv[4]
ended_at_unix = time.time()

ts_path = os.path.expanduser("~/.claude/scripts/telemetry-summarize.py")
spec = importlib.util.spec_from_file_location("ts", ts_path)
ts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)

pricing_data = ts.load_pricing_yaml()
projects_root = os.path.expanduser("~/.claude/projects")

# ── Parent transcript: always JSONL+pricing.yaml (the T2 path) ──────────────
parent_cost = 0.0
if pricing_data:
    parent_hits = glob.glob(f"{projects_root}/*/{parent_uuid}.jsonl")
    if parent_hits:
        model, tokens, first_ts, _ = ts._walk_jsonl_for_tokens(
            Path(parent_hits[0]), section_start_unix, ended_at_unix
        )
        if first_ts is not None and model:
            parent_cost = ts.compute_cost(
                {"model": model, "tokens": tokens}, [], pricing_data, []
            ) or 0.0

# ── Subagent term: dispatch by section type ─────────────────────────────────
# Native section IDs are stored as "native:<orch-or-initial>" by
# orchestra-block.sh; SoHoAI's own native session header (when injected) is
# "native-<UUID>". Accept either prefix for the native branch.
is_native = section_id.startswith("native:") or section_id.startswith("native-")

subagent_cost = 0.0
if is_native:
    # JSONL path — same as native-session-finalize.py
    if pricing_data:
        sub_dir_hits = glob.glob(f"{projects_root}/*/{parent_uuid}/subagents")
        if sub_dir_hits:
            for meta_path in sorted(Path(sub_dir_hits[0]).glob("agent-*.meta.json")):
                sub_jsonl = meta_path.with_suffix("").with_suffix(".jsonl")
                model, tokens, first_ts, _ = ts._walk_jsonl_for_tokens(
                    sub_jsonl, section_start_unix, ended_at_unix
                )
                if first_ts is None or not model:
                    continue
                c = ts.compute_cost(
                    {"model": model, "tokens": tokens}, [], pricing_data, []
                )
                if c:
                    subagent_cost += c
else:
    # Orchestra session: 3-tier cascade for subagent cost (mirrors telemetry-summarize.py).
    # Tier 1: SoHoAI query (same source as orchestra session-end telemetry,
    #         5 s timeout to avoid stale cache from busy DB).
    try:
        usage = ts.query_sohoai_usage(
            session_id=section_id,
            started_at_unix=section_start_unix,
            ended_at_unix=ended_at_unix,
            base_url=os.environ.get("ANTHROPIC_BASE_URL", "").rstrip("/"),
            timeout_s=5,
            model_filter=None,
        )
        if usage and usage.get("cost_usd"):
            subagent_cost = float(usage["cost_usd"])
    except Exception:
        pass

    # Tier 2: litellm (if Tier 1 failed or returned None/0)
    # NOTE: Script stdout is cost-only; cascading warnings suppressed.
    if subagent_cost == 0.0:
        sub_dir_hits = glob.glob(f"{projects_root}/*/{parent_uuid}/subagents")
        if sub_dir_hits:
            # Build subagents list from agent-*.jsonl files (same walk as is_native branch)
            subagents_list = []
            for meta_path in sorted(Path(sub_dir_hits[0]).glob("agent-*.meta.json")):
                sub_jsonl = meta_path.with_suffix("").with_suffix(".jsonl")
                model, tokens, first_ts, _ = ts._walk_jsonl_for_tokens(
                    sub_jsonl, section_start_unix, ended_at_unix
                )
                if first_ts is None or not model:
                    continue
                subagents_list.append({"model": model, "tokens": tokens})

            # Try litellm (no parent in this context; warnings suppressed)
            litellm_cost = None
            if subagents_list:
                try:
                    litellm_cost = ts.query_litellm_cost({"model": None, "tokens": {}}, subagents_list, [])
                    if litellm_cost is not None:
                        subagent_cost = litellm_cost
                except Exception:
                    pass

            # Tier 3: pricing.yaml fallback (only if Tier 2 returned None, not if it returned 0.0)
            if litellm_cost is None and subagents_list and pricing_data:
                try:
                    subagent_cost = ts.compute_cost({"model": None, "tokens": {}}, subagents_list, pricing_data, []) or 0.0
                except Exception:
                    pass

total = parent_cost + subagent_cost
out = f"{total:.4f}"

# Always rewrite cache (even on zero) so stale values cannot persist past TTL.
try:
    tmp = cache_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(out)
    os.replace(tmp, cache_file)
except Exception:
    pass

print(out)
PYEOF
