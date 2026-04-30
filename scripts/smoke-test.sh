#!/usr/bin/env bash
# Telemetry smoke test verifier for /duo and /brain sessions.
# Run after a /duo or /brain invocation to verify T1 and T2 captured it.
#
# Usage: ./scripts/smoke-test.sh [session_dir]
#   If session_dir is omitted, uses the most recent session under
#   ${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions/ (or ./. claude/orchestra/sessions/ if unset).

set -euo pipefail

CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SESSIONS_ROOT="${CLAUDE_PROJECT_DIR}/.claude/orchestra/sessions"
PYTHON3="${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3"
GLOBAL_LOG="${HOME}/.claude/orchestra/telemetry.jsonl"

if [ -n "${1:-}" ]; then
    SESSION_DIR="$1"
else
    SESSION_DIR=$(ls -td "${SESSIONS_ROOT}"/*/  2>/dev/null | head -1)
    SESSION_DIR="${SESSION_DIR%/}"
fi

if [ -z "${SESSION_DIR:-}" ] || [ ! -d "${SESSION_DIR}" ]; then
    echo "ERROR: No session dir found under ${SESSIONS_ROOT}"
    echo "  Run /duo or /brain first, or pass the session dir as an argument."
    exit 1
fi

SESSION_ID="${SESSION_DIR##*/}"
echo "=== Smoke test: ${SESSION_ID} ==="

PASS=0

# --- T1: hook events ---
echo ""
echo "--- T1 (hook events: telemetry-events.jsonl) ---"
T1_FILE="${SESSION_DIR}/telemetry-events.jsonl"
if [ -f "${T1_FILE}" ]; then
    LINES=$(wc -l < "${T1_FILE}")
    echo "✓ telemetry-events.jsonl: ${LINES} event(s)"
    jq -r '"  " + .event + " | " + (.subagent // "?") + " | " + (.ts // "(no ts)")' \
        "${T1_FILE}" 2>/dev/null || cat "${T1_FILE}"
    # Check for null usage (T1 timing-only mode)
    NULL_USAGE=$(jq -s '[.[] | select(.usage == null)] | length' "${T1_FILE}" 2>/dev/null || echo 0)
    if [ "${NULL_USAGE:-0}" -gt 0 ]; then
        echo "  ⚠ ${NULL_USAGE} event(s) have usage=null — T1 is timing-only for this session (T2 is authoritative)"
    fi
    PASS=$((PASS + 1))
else
    echo "✗ telemetry-events.jsonl not found"
    echo "  T1 hook may not have fired (check PreToolUse hook in ~/.claude/settings.json)"
fi

# --- T2: transcript parse ---
echo ""
echo "--- T2 (transcript parse: telemetry.json) ---"
T2_FILE="${SESSION_DIR}/telemetry.json"
if [ -f "${T2_FILE}" ]; then
    echo "✓ telemetry.json found"
    "${PYTHON3}" - <<PYEOF
import json, sys
with open("${T2_FILE}") as f:
    d = json.load(f)
parent_tok = sum(d.get("parent", {}).get("tokens", {}).values())
sub_tok = sum(sum(s.get("tokens", {}).values()) for s in d.get("subagents", []))
total = parent_tok + sub_tok
print(f"  command:      {d.get('command', '?')}")
print(f"  outcome:      {d.get('outcome', '?')}")
print(f"  cost:         \${d.get('cost_usd_estimate', 0):.4f}")
print(f"  total_tokens: {total}")
print(f"  parent_model: {d.get('parent', {}).get('model', '?')}")
sub_types = [s.get('type', '?') for s in d.get('subagents', [])]
print(f"  subagents:    {sub_types}")
warnings = d.get("parser_warnings", [])
if warnings:
    for w in warnings:
        print(f"  ⚠ {w}")
else:
    print("  ✓ no parser_warnings (T1/T2 within 5%)")
cost = d.get("cost_usd_estimate", 0)
sys.exit(0 if cost and cost > 0 else 1)
PYEOF
    if [ $? -eq 0 ]; then
        PASS=$((PASS + 1))
    else
        echo "  ✗ cost_usd_estimate is 0 or missing — T2 parse may have failed"
        echo "  Run manually: ~/.claude/scripts/telemetry-summarize.sh \"${SESSION_DIR}\" duo pass \"\""
    fi
else
    echo "✗ telemetry.json not found"
    echo "  T2 pass has not run yet. Trigger manually:"
    echo "  ~/.claude/scripts/telemetry-summarize.sh \"${SESSION_DIR}\" duo pass \"\""
fi

# --- Global log ---
echo ""
echo "--- Global log (~/.claude/orchestra/telemetry.jsonl) ---"
if [ -f "${GLOBAL_LOG}" ]; then
    if grep -q "\"${SESSION_ID}\"" "${GLOBAL_LOG}" 2>/dev/null; then
        echo "✓ Session found in global log:"
        grep "\"${SESSION_ID}\"" "${GLOBAL_LOG}" | tail -1 | "${PYTHON3}" -m json.tool
        PASS=$((PASS + 1))
    else
        echo "✗ Session not found in global log (T2 may not have appended yet)"
    fi
else
    echo "✗ ${GLOBAL_LOG} does not exist"
fi

# --- Summary ---
echo ""
if [ "${PASS}" -eq 3 ]; then
    echo "✓ All checks passed (3/3)"
    exit 0
else
    echo "✗ ${PASS}/3 checks passed"
    exit 1
fi
