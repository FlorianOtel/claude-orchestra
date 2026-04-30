#!/usr/bin/env bash
# telemetry-report.sh — on-demand summary of recent telemetry sessions.
# Usage: telemetry-report.sh [--last N]
#
# Reads ~/.claude/orchestra/telemetry.jsonl, prints tabular summary of the last N sessions,
# and aggregates. Checks pricing.yaml staleness and warns if > 90 days old.
#
# chmod +x me after deploy

set -uo pipefail

LAST_N="${1:-20}"
if [[ "$LAST_N" == "--last" ]]; then
    LAST_N="${2:-20}"
fi

TELEMETRY_JSONL="${HOME}/.claude/orchestra/telemetry.jsonl"

if [ ! -f "$TELEMETRY_JSONL" ]; then
    echo "(no telemetry yet)"
    exit 0
fi

# Find pricing.yaml
PRICING_FILE=""
for candidate in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/pricing.yaml" \
    "${HOME}/.claude/orchestra/pricing.yaml"; do
    if [ -f "$candidate" ]; then
        PRICING_FILE="$candidate"
        break
    fi
done

# Check pricing staleness
if [ -n "$PRICING_FILE" ]; then
    LAST_UPDATED=$(grep "^last_updated:" "$PRICING_FILE" | head -1 | awk '{print $2}' | tr -d '"')
    if [ -n "$LAST_UPDATED" ]; then
        TODAY=$(date +%Y-%m-%d)
        LAST_UPDATED_EPOCH=$(date -d "$LAST_UPDATED" +%s 2>/dev/null || echo 0)
        TODAY_EPOCH=$(date -d "$TODAY" +%s 2>/dev/null || echo 0)
        DAYS_AGO=$(( (TODAY_EPOCH - LAST_UPDATED_EPOCH) / 86400 ))

        if [ "$DAYS_AGO" -gt 90 ]; then
            echo "⚠ pricing.yaml last updated $LAST_UPDATED ($DAYS_AGO days ago)."
            echo "  Verify against https://docs.anthropic.com/en/docs/about-claude/models/all-models"
            echo "  and bump last_updated when current."
            echo ""
        fi
    fi
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Install jq for full telemetry-report.sh output"
    exit 1
fi

# Extract last N sessions
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
          (if .regret_flag then "regret" else "" end)
        ] | @tsv
    '
} | column -t -s$'\t' 2>/dev/null \
  || tail -n "$LAST_N" "$TELEMETRY_JSONL" | jq -r '[.started_at, .command, .outcome, .cost_usd_estimate, .total_tokens, .duration_s] | @tsv'

# Aggregates
echo ""
echo "--- Aggregates (all sessions) ---"
jq -s '
{
  total_sessions: length,
  total_cost: (map(.cost_usd_estimate) | add // 0),
  total_tokens: (map(.total_tokens) | add // 0),
  mean_cost: (map(.cost_usd_estimate) | add / length),
  regret_rate: ((map(select(.regret_flag == true)) | length) / length * 100),
  by_command: (group_by(.command) | map({command: .[0].command, count: length, cost: (map(.cost_usd_estimate) | add // 0)}) | sort_by(.command))
}
' "$TELEMETRY_JSONL" 2>/dev/null | jq '.' || echo "Failed to compute aggregates"
