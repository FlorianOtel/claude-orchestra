#!/usr/bin/env bash
# subagent-active-indicator.sh — decide whether a subagent is genuinely running right now.
#
# Prints the stage name of the most recent genuinely-active dispatch, or nothing.
# ALWAYS exits 0 — this feeds the status line and must never break a prompt render.
#
# Usage: subagent-active-indicator.sh <invocations_log> [ttl_minutes] [now_epoch]
#
# What "active" means here:
#   a `start` whose `logfile` appears in no `end`'s `logfile`, AND whose `ts` is inside the
#   TTL window.
#
# Why not the previous rule. The old logic compared the newest start's timestamp against the
# newest end's timestamp, with no per-agent identity and no notion of staleness. Two failures
# followed, both reproduced against fixtures before this script was written:
#   - an unmatched start rendered as active FOREVER (nothing ever cleared it);
#   - with two agents in flight, the second one's end made the display go dark while the
#     first was still running — a false negative, which is the worse direction.
#
# The TTL is the guarantee. Pairing (below, and in orchestra-hook.sh) improves accuracy, but
# a subagent that is killed, or whose end write is gated off, never produces an end at all —
# only a clock can retire those.
#
# Timestamps are `%Y%m%dT%H%M%SZ`: fixed-width, so lexicographic order IS chronological and
# the cutoff can be compared as a string. That keeps this to one `date` call rather than one
# per line, which matters because the status line renders on every prompt.

set -uo pipefail

LOG="${1:-}"
TTL_MINUTES="${2:-30}"
NOW_EPOCH="${3:-$(date -u +%s)}"

[ -n "$LOG" ] && [ -f "$LOG" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

case "$TTL_MINUTES" in (''|*[!0-9]*) TTL_MINUTES=30 ;; esac
case "$NOW_EPOCH"   in (''|*[!0-9]*) NOW_EPOCH="$(date -u +%s)" ;; esac

CUTOFF="$(date -u -d "@$(( NOW_EPOCH - TTL_MINUTES * 60 ))" +%Y%m%dT%H%M%SZ 2>/dev/null || echo "")"
[ -n "$CUTOFF" ] || exit 0

# Bounded read. Safe only because unidentified `end` events are no longer written — they were
# 86-93% of this file's volume, and 500 lines of that is almost entirely noise.
tail -n 500 "$LOG" 2>/dev/null \
  | jq -R 'fromjson? // empty' 2>/dev/null \
  | jq -rs --arg cutoff "$CUTOFF" '
      # Every logfile an end has claimed. Empty ones can never match and are dropped.
      ( [ .[] | select(.event == "end" and ((.logfile // "") != "")) | .logfile ] ) as $ended
      | [ .[]
          | select(.event == "start")
          | select((.logfile // "") != "")
          | select((.ts // "") >= $cutoff)
          | select((.logfile | IN($ended[])) | not)
        ]
      | last
      | if . == null then empty else (.stage // "") end
    ' 2>/dev/null \
  | tail -n 1

exit 0
