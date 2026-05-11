#!/usr/bin/env bash
# native-subagent-cost.sh — sum cost of all subagent JSONLs for a native CC session.
#
# Usage: native-subagent-cost.sh <parent-uuid>
#
# Scans ~/.claude/projects/*/<parent-uuid>/subagents/agent-*.meta.json,
# walks each agent-*.jsonl, prices per model via pricing.yaml, prints total
# cost as a float (e.g. "0.3741"). Prints nothing on error or no-subagents.

PYTHON3="${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3"
parent_uuid="${1:-}"
[ -z "$parent_uuid" ] && exit 0

"$PYTHON3" - "$parent_uuid" <<'PYEOF' 2>/dev/null
import sys, os, glob, json, importlib.util, time
from pathlib import Path

parent_uuid = sys.argv[1]

ts_path = os.path.expanduser("~/.claude/scripts/telemetry-summarize.py")
spec = importlib.util.spec_from_file_location("ts", ts_path)
ts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)

projects_root = os.path.expanduser("~/.claude/projects")
hits = glob.glob(f"{projects_root}/*/{parent_uuid}/subagents")
if not hits:
    sys.exit(0)

pricing_data = ts.load_pricing_yaml()
if not pricing_data:
    sys.exit(0)

total = 0.0
for meta_path in sorted(Path(hits[0]).glob("agent-*.meta.json")):
    try:
        meta = json.loads(meta_path.read_text())
    except Exception:
        continue
    sub_jsonl = meta_path.with_suffix("").with_suffix(".jsonl")
    model, tokens, first_ts, _ = ts._walk_jsonl_for_tokens(sub_jsonl, 0.0, time.time())
    if first_ts is None:
        continue
    cost = ts.compute_cost({"model": model, "tokens": tokens}, [], pricing_data, [])
    if cost:
        total += cost

if total > 0:
    print(f"{total:.4f}")
PYEOF
