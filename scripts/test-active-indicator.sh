#!/usr/bin/env bash
# test-active-indicator.sh — regression tests for the active-subagent indicator and for the
# start/end pairing that feeds it.
#
# Run: bash scripts/test-active-indicator.sh    (exit 0 = all pass)
#
# Every scenario here was first run against the PRE-FIX code. Fixtures (c) and (d) failed
# then — (c) rendered a 60-minute-old start as active forever, (d) went dark while an agent
# was still running. A test that has not been watched failing is not evidence.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
INDICATOR="${REPO}/scripts/subagent-active-indicator.sh"
HOOK="${REPO}/scripts/orchestra-hook.sh"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

NOW="$(date -u -d '2026-09-22T15:00:00Z' +%s)"   # fixtures are written against this instant
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
want() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

line() { # event stage subagent logfile ts
  printf '{"event":"%s","stage":"%s","subagent":"%s","logfile":"%s","host":"h","pid":"1","session":"s","ts":"%s"}\n' "$@"
}

# ---------------------------------------------------------------------------------------
echo "1. Indicator fixtures (TTL=30, now=2026-09-22T15:00:00Z, cutoff 14:30)"
# ---------------------------------------------------------------------------------------
{ line start implement actor /log/A 20260922T145500Z
  line end   implement actor /log/A 20260922T145600Z; } > "$FIX/a.log"
{ line start review reviewer /log/B 20260922T145800Z; } > "$FIX/b.log"
{ line start research researcher /log/C 20260922T140000Z; } > "$FIX/c.log"
{ line start plan      planner /log/D1 20260922T145000Z
  line start implement actor   /log/D2 20260922T145100Z
  line end   implement actor   /log/D2 20260922T145200Z; } > "$FIX/d.log"
{ line start implement actor   "" 20260922T144000Z
  line end   implement actor   "" 20260922T144100Z
  line start review    reviewer /log/E 20260922T145700Z; } > "$FIX/e.log"

run() { bash "$INDICATOR" "$FIX/$1.log" 30 "$NOW"; }
want "a  matched pair -> inactive"                    ""        "$(run a)"
want "b  unmatched start inside TTL -> active"        "review"  "$(run b)"
want "c  unmatched start older than TTL -> reaped"    ""        "$(run c)"
want "d  concurrent, second ends first -> first still active" "plan" "$(run d)"
want "e  legacy empty-logfile pair ignored"           "review"  "$(run e)"

echo "   robustness"
want "   missing file"      "" "$(bash "$INDICATOR" "$FIX/nope.log" 30 "$NOW")"
printf 'garbage\n{"event":"start"\n' > "$FIX/junk.log"
want "   malformed lines"   "" "$(bash "$INDICATOR" "$FIX/junk.log" 30 "$NOW")"
: > "$FIX/empty.log"
want "   empty file"        "" "$(bash "$INDICATOR" "$FIX/empty.log" 30 "$NOW")"

# ---------------------------------------------------------------------------------------
echo
echo "2. Pending-marker invariant — unidentified ends must NOT consume a live marker"
# ---------------------------------------------------------------------------------------
# Claude Code's internal helper agents fire SubagentStop on a ~31s cadence, and jq-failure
# events arrive as subagent "unknown". Together they outnumber real agents ~5:1. If either
# reached the marker pop, it would retire a running agent's marker and the badge would go
# dark during live work — a worse failure than the one this fixes.
PROJ="$FIX/proj"; mkdir -p "$PROJ/.claude/orchestra/sessions/s1"
touch "$PROJ/.claude/orchestra/sessions/s1/.brain-inflight"
PENDING="$PROJ/.claude/orchestra/.pending-agents"

# The marker MUST be filed under the stage an unidentified end would look in, or this test
# passes for the wrong reason. `stage_for_subagent` maps anything unrecognised — including
# "unknown" — to "agent", so that is the bucket at risk. An earlier version of this test used
# "review", which unknown ends never search, and so it could not fail on the defect it names.
mkdir -p "$PENDING/agent"; printf '/log/LIVE\n' > "$PENDING/agent/1700000000000000000-999"
before="$(find "$PENDING" -type f | wc -l | tr -d ' ')"

for i in 1 2 3; do
  # helper shape: valid JSON, no agent_type -> hook must exit before the pop
  printf '{"session_id":"s"}' | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" end >/dev/null 2>&1 || true
done
after_helper="$(find "$PENDING" -type f | wc -l | tr -d ' ')"
want "3 helper-shaped ends leave the marker intact" "$before" "$after_helper"

# jq-failure shape: invalid JSON -> SUBAGENT becomes "unknown"
printf 'this is not json at all' | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" end >/dev/null 2>&1 || true
after_unknown="$(find "$PENDING" -type f | wc -l | tr -d ' ')"
want "unknown-subagent end leaves the marker intact" "$before" "$after_unknown"

# NB: `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` would emit "0\n0" and the
# assertion would fail on its own formatting rather than on the code. Use `|| true`.
unk_lines="$(grep -c '"subagent":"unknown"' "$PROJ/.claude/orchestra/invocations.log" 2>/dev/null || true)"
want "no unknown-subagent line written to invocations.log" "0" "${unk_lines:-0}"

# ---------------------------------------------------------------------------------------
echo
echo "3. Real hook, end-to-end pairing"
# ---------------------------------------------------------------------------------------
P2="$FIX/proj2"; mkdir -p "$P2/.claude/orchestra/sessions/s1"
touch "$P2/.claude/orchestra/sessions/s1/.brain-inflight"
LOG2="$P2/.claude/orchestra/invocations.log"

emit_start() { printf '{"tool_input":{"subagent_type":"%s","prompt":"p"},"session_id":"s"}' "$1" \
                 | CLAUDE_PROJECT_DIR="$P2" bash "$HOOK" start >/dev/null 2>&1 || true; }
emit_end()   { printf '{"agent_type":"%s","session_id":"s"}' "$1" \
                 | CLAUDE_PROJECT_DIR="$P2" bash "$HOOK" end   >/dev/null 2>&1 || true; }

emit_start actor; emit_start reviewer
emit_end   actor; emit_end   reviewer

starts="$(grep -c '"event":"start"' "$LOG2" 2>/dev/null || echo 0)"
ends="$(grep -c '"event":"end"'   "$LOG2" 2>/dev/null || echo 0)"
want "two starts recorded" "2" "$starts"
want "two ends recorded"   "2" "$ends"

paired="$(python3 - "$LOG2" <<'PY'
import json,sys
s=set(); e=set()
for l in open(sys.argv[1],errors='replace'):
    try: d=json.loads(l)
    except: continue
    lf=d.get('logfile') or ''
    if not lf: continue
    (s if d.get('event')=='start' else e).add(lf)
print(len(s & e))
PY
)"
want "both starts paired to their own end" "2" "$paired"

leftover="$(find "$P2/.claude/orchestra/.pending-agents" -type f 2>/dev/null | wc -l | tr -d ' ')"
want "no pending markers left behind" "0" "$leftover"

# after a clean run nothing should be rendered as active
want "indicator quiet after all agents ended" "" "$(bash "$INDICATOR" "$LOG2" 30 "$(date -u +%s)")"

# ---------------------------------------------------------------------------------------
echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
