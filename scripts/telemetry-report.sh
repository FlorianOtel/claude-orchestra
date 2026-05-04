#!/usr/bin/env bash
# telemetry-smoke-test-2026-05-04
# telemetry-report.sh — on-demand summary of recent telemetry sessions.
#
# Usage:
#   telemetry-report.sh [--last N] [--tier]
#
#   --last N   Show the last N sessions (default 20).
#   --tier     Show per-tier cost breakdown (Brain / Planner / Actor / Reviewer).
#              Reads per-session telemetry.json from:
#                ${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions/   (if set)
#                $(pwd)/.claude/orchestra/sessions/                   (fallback)
#              Run from your project directory when using --tier.
#
# chmod +x me after deploy

set -uo pipefail

# --- arg parsing ---
LAST_N=20
SHOW_TIER=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --last)  LAST_N="${2:-20}"; shift 2 ;;
        --tier)  SHOW_TIER=true;    shift   ;;
        [0-9]*)  LAST_N="$1";       shift   ;;
        *)        shift ;;
    esac
done

TELEMETRY_JSONL="${HOME}/.claude/orchestra/telemetry.jsonl"
SESSIONS_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/orchestra/sessions"
PYTHON3="${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3"
PRICING_FILE="${HOME}/.claude/orchestra/pricing.yaml"

if [ ! -f "$TELEMETRY_JSONL" ]; then
    echo "(no telemetry yet — run /duo or /brain first)"
    exit 0
fi

# --- pricing staleness check ---
if [ -f "$PRICING_FILE" ]; then
    LAST_UPDATED=$(grep "^last_updated:" "$PRICING_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    if [ -n "$LAST_UPDATED" ]; then
        LAST_UPDATED_EPOCH=$(date -d "$LAST_UPDATED" +%s 2>/dev/null || echo 0)
        TODAY_EPOCH=$(date -d "$(date +%Y-%m-%d)" +%s 2>/dev/null || echo 0)
        DAYS_AGO=$(( (TODAY_EPOCH - LAST_UPDATED_EPOCH) / 86400 ))
        if [ "$DAYS_AGO" -gt 90 ]; then
            echo "⚠ pricing.yaml last updated $LAST_UPDATED ($DAYS_AGO days ago)."
            echo "  Verify against https://docs.anthropic.com/en/docs/about-claude/models/all-models"
            echo "  and bump last_updated when current."
            echo ""
        fi
    fi
fi

if ! command -v jq &> /dev/null; then
    echo "jq required — install it first"
    exit 1
fi

# =============================================================================
# --tier mode: per-tier cost breakdown from individual telemetry.json files
# =============================================================================
if $SHOW_TIER; then
    echo "Per-tier cost breakdown"
    echo "Sessions root: ${SESSIONS_ROOT}"
    echo ""

    # Write Python scripts to temp files
    TIER_PY=$(mktemp /tmp/telemetry-tier-XXXXXX.py)
    CUMUL_PY=$(mktemp /tmp/telemetry-cumul-XXXXXX.py)
    trap 'rm -f "$TIER_PY" "$CUMUL_PY"' EXIT

    cat > "$TIER_PY" << 'PYEOF'
import json, yaml, re, sys
from pathlib import Path

tf = Path(sys.argv[1])
pf = Path(sys.argv[2]) if len(sys.argv) > 2 else None

t = json.load(tf.open())
rates = yaml.safe_load(pf.read_text())["models"] if pf and pf.exists() else {}

def norm(m): return re.sub(r"-\d{8}$", "", m or "")

def cost(tok, model):
    r = rates.get(norm(model), {})
    if not r:
        return 0.0
    return sum(tok.get(k, 0) * r.get(k, 0)
               for k in ["input", "output", "cache_creation", "cache_read"]) / 1_000_000

ORDER = {"brain": 0, "planner": 1, "actor": 2, "reviewer": 3}
tiers = [("brain", t["parent"]["model"], t["parent"]["tokens"])]
for s in t.get("subagents", []):
    tiers.append((s["type"], s.get("model", "?"), s["tokens"]))
tiers.sort(key=lambda x: ORDER.get(x[0], 4))

grand_tok  = sum(sum(tok.values()) for _, _, tok in tiers)
grand_cost = sum(cost(tok, m)      for _, m, tok in tiers)

date = t["started_at"][:10]
dur  = t.get("duration_s", 0)
print(f"  {date}  {t['command']:<6}  {dur}s  outcome={t['outcome']:<10}  total=${grand_cost:.4f}")
print(f"    {'Tier':<12} {'Model':<22} {'Tokens':>10}  {'%tok':>5}  {'Cost':>8}  {'%cost':>6}")
print(f"    {'-'*64}")
for tier, model, tok in tiers:
    t_ = sum(tok.values())
    c  = cost(tok, model)
    pct_tok  = t_ / grand_tok  * 100 if grand_tok  else 0
    pct_cost = c  / grand_cost * 100 if grand_cost else 0
    print(f"    {tier:<12} {norm(model):<22} {t_:>10,}  {pct_tok:>4.1f}%  ${c:>7.4f}  {pct_cost:>5.1f}%")
print(f"    {'-'*64}")
print(f"    {'TOTAL':<12} {'':<22} {grand_tok:>10,}         ${grand_cost:>7.4f}")

reported = t.get("cost_usd_estimate", 0)
if abs(grand_cost - reported) > 0.001:
    print(f"    (T2 log reported: ${reported:.4f} — delta ${grand_cost - reported:+.4f})")
print()
PYEOF

    # Cumulative analysis: aggregate tokens+cost by (tier, model) across all sessions.
    # argv: pricing_file tf1 tf2 ...
    cat > "$CUMUL_PY" << 'PYEOF'
import json, yaml, re, sys
from pathlib import Path
from collections import defaultdict

pricing_file = Path(sys.argv[1]) if len(sys.argv) > 1 else None
tf_paths = sys.argv[2:]
rates = yaml.safe_load(pricing_file.read_text())["models"] if pricing_file and pricing_file.exists() else {}

def norm(m): return re.sub(r"-\d{8}$", "", m or "")
def cost(tok, model):
    r = rates.get(norm(model), {})
    return sum(tok.get(k,0)*r.get(k,0)
               for k in ["input","output","cache_creation","cache_read"]) / 1e6 if r else 0.0

accum = defaultdict(lambda: {"tokens": defaultdict(int), "cost": 0.0})
n = 0
for tf_path in tf_paths:
    try:
        t = json.load(open(tf_path))
    except Exception:
        continue
    n += 1
    key = ("brain", norm(t["parent"]["model"]))
    for k, v in t["parent"]["tokens"].items():
        accum[key]["tokens"][k] += v
    accum[key]["cost"] += cost(t["parent"]["tokens"], t["parent"]["model"])
    for s in t.get("subagents", []):
        key = (s["type"], norm(s.get("model", "?")))
        for k, v in s["tokens"].items():
            accum[key]["tokens"][k] += v
        accum[key]["cost"] += cost(s["tokens"], s.get("model", "?"))

if n == 0:
    sys.exit(0)

ORDER = {"brain": 0, "planner": 1, "actor": 2, "reviewer": 3}
items = sorted(accum.items(), key=lambda x: ORDER.get(x[0][0], 4))
grand_tok  = sum(sum(v["tokens"].values()) for _, v in items)
grand_cost = sum(v["cost"]                 for _, v in items)

print(f"--- Cumulative totals ({n} session(s)) ---")
print(f"  {'Tier':<12} {'Model':<22} {'Tokens':>12}  {'%tok':>5}  {'Cost':>9}  {'%cost':>6}")
print(f"  {'-'*68}")
for (tier, model), v in items:
    t_ = sum(v["tokens"].values()); c = v["cost"]
    print(f"  {tier:<12} {model:<22} {t_:>12,}  {t_/grand_tok*100:>4.1f}%  ${c:>8.4f}  {c/grand_cost*100:>5.1f}%")
print(f"  {'-'*68}")
print(f"  {'TOTAL':<12} {'':<22} {grand_tok:>12,}          ${grand_cost:>8.4f}")
PYEOF

    # Process each session (process substitution keeps VALID_TFS in scope)
    VALID_TFS=()
    while IFS= read -r line; do
        SID=$(printf '%s' "$line" | jq -r '.session_id')
        TF="${SESSIONS_ROOT}/${SID}/telemetry.json"
        if [ ! -f "$TF" ]; then
            DATE=$(printf '%s' "$line" | jq -r '.started_at | split("T")[0]')
            CMD=$(printf '%s' "$line" | jq -r '.command')
            COST=$(printf '%s' "$line" | jq -r '.cost_usd_estimate')
            echo "  $DATE  $CMD  total=\$$COST  (no session dir — log total only)"
            echo ""
        else
            VALID_TFS+=("$TF")
            "${PYTHON3}" "$TIER_PY" "$TF" "$PRICING_FILE"
        fi
    done < <(tail -n "$LAST_N" "$TELEMETRY_JSONL")

    # Cumulative summary across all sessions that had session dirs
    if [ ${#VALID_TFS[@]} -gt 0 ]; then
        "${PYTHON3}" "$CUMUL_PY" "$PRICING_FILE" "${VALID_TFS[@]}"
    fi

# =============================================================================
# default mode: tabular session summary
# =============================================================================
else
    {
        printf "Date\tCommand\tOutcome\tCost\tTokens\tDuration\tNote\n"
        tail -n "$LAST_N" "$TELEMETRY_JSONL" | jq -r '
            [
              (.started_at | split("T")[0]),
              .command,
              .outcome,
              ("$" + (.cost_usd_estimate | tostring)),
              (.total_tokens | tostring),
              ((.duration_s | tostring) + "s"),
              (if .regret_flag then "⚑ regret" else "" end)
            ] | @tsv
        '
    } | column -t -s$'\t' 2>/dev/null \
      || tail -n "$LAST_N" "$TELEMETRY_JSONL" | \
         jq -r '[.started_at, .command, .outcome, .cost_usd_estimate, .total_tokens, .duration_s] | @tsv'
fi

# =============================================================================
# aggregates (always shown)
# =============================================================================
echo ""
echo "--- Aggregates (last $LAST_N sessions in log) ---"
tail -n "$LAST_N" "$TELEMETRY_JSONL" | jq -s '
{
  sessions:    length,
  total_cost:  (map(.cost_usd_estimate) | add // 0 | . * 10000 | round / 10000),
  total_tokens:(map(.total_tokens)       | add // 0),
  mean_cost:   (map(.cost_usd_estimate) | add / length | . * 10000 | round / 10000),
  regret_rate_pct: ((map(select(.regret_flag == true)) | length) / length * 100 | . * 10 | round / 10),
  by_command:  (group_by(.command) | map({
      command: .[0].command,
      count:   length,
      cost:    (map(.cost_usd_estimate) | add // 0 | . * 10000 | round / 10000)
    }) | sort_by(.command))
}
' 2>/dev/null | jq '.' || echo "Failed to compute aggregates"
