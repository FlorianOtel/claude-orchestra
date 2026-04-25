#!/usr/bin/env bash
# scripts/runs-registry.sh
#
# CRUD helpers for the /brain run registry at .claude/orchestra/runs.jsonl.
# Each line is a JSON event: {"event":"<state>","run_id":"...",...,"ts":"..."}.
# Most-recent event per run_id defines current state.
#
# States: start → research_complete → plan_dispatched → done
#         (+ abandoned, error at any point)
#
# Usage:
#   runs-registry.sh start <run_id> <slug> <task> <window> <model>
#   runs-registry.sh transition <run_id> <event> [reason]
#   runs-registry.sh latest-state <run_id>            # prints state name
#   runs-registry.sh resolve <prefix>                  # prefix → run_id (stderr error if ambiguous)
#   runs-registry.sh list                              # human table of all runs
#   runs-registry.sh count-active                      # int: runs not in {done,abandoned,error}
#   runs-registry.sh by-state <state>                  # newline-separated run_ids in that state
#   runs-registry.sh field <run_id> <field>            # extract one field from start event (e.g. slug, window)
#
# Design reference: docs/design.md — /brain Phase 0 architecture.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ORCHESTRA_DIR="${PROJECT_DIR}/.claude/orchestra"
REGISTRY="${ORCHESTRA_DIR}/runs.jsonl"

mkdir -p "$ORCHESTRA_DIR" 2>/dev/null || true
touch "$REGISTRY" 2>/dev/null || true

ACTIVE_STATES=( "start" "research_complete" "plan_dispatched" "planning" "implementing" "reviewing" )
TERMINAL_STATES=( "done" "abandoned" "error" )

cmd="${1:-}"; shift || true

case "$cmd" in

  start)
    run_id="${1:?run_id required}"; slug="${2:?slug required}"; task="${3:?task required}"
    window="${4:?window required}"; model="${5:?model required}"
    ts="$(date -u +%FT%TZ)"
    jq -nc \
      --arg event "start" \
      --arg run_id "$run_id" --arg slug "$slug" --arg task "$task" \
      --arg window "$window" --arg model "$model" \
      --arg host "${HOSTNAME:-unknown}" --arg pid "$$" --arg ts "$ts" \
      '{event:$event, run_id:$run_id, slug:$slug, task:$task, window:$window, model:$model, host:$host, pid:($pid|tonumber), ts:$ts}' \
      >> "$REGISTRY"
    ;;

  transition)
    run_id="${1:?run_id required}"; event="${2:?event required}"; reason="${3:-}"
    ts="$(date -u +%FT%TZ)"
    if [ -n "$reason" ]; then
      jq -nc --arg event "$event" --arg run_id "$run_id" --arg reason "$reason" --arg ts "$ts" \
        '{event:$event, run_id:$run_id, reason:$reason, ts:$ts}' >> "$REGISTRY"
    else
      jq -nc --arg event "$event" --arg run_id "$run_id" --arg ts "$ts" \
        '{event:$event, run_id:$run_id, ts:$ts}' >> "$REGISTRY"
    fi
    ;;

  latest-state)
    run_id="${1:?run_id required}"
    jq -r --arg id "$run_id" 'select(.run_id==$id) | .event' < "$REGISTRY" 2>/dev/null | tail -1
    ;;

  resolve)
    prefix="${1:?prefix required}"
    # Prefix-match only — escape regex metachars in $prefix
    prefix_re="$(printf '%s' "$prefix" | sed 's/[][\.*^$()+?{}|/]/\\&/g')"
    matches="$(jq -r 'select(.event=="start") | .slug' < "$REGISTRY" 2>/dev/null | sort -u | grep -E "^${prefix_re}" || true)"
    count="$(printf '%s\n' "$matches" | grep -c . || true)"
    case "$count" in
      0) echo "no run matches: $prefix" >&2; exit 1 ;;
      1) ;;
      *) echo "ambiguous prefix: $prefix matches:" >&2; printf '%s\n' "$matches" >&2; exit 1 ;;
    esac
    # Find the run_id whose slug equals the matched slug (most recent if duplicates)
    matched_slug="$(printf '%s\n' "$matches" | head -1)"
    jq -r --arg slug "$matched_slug" 'select(.event=="start" and .slug==$slug) | .run_id' < "$REGISTRY" 2>/dev/null | tail -1
    ;;

  field)
    run_id="${1:?run_id required}"; field="${2:?field required}"
    jq -r --arg id "$run_id" --arg f "$field" 'select(.run_id==$id and .event=="start") | .[$f] // empty' < "$REGISTRY" 2>/dev/null | tail -1
    ;;

  list)
    # Human-readable table
    if [ ! -s "$REGISTRY" ]; then
      echo "(no runs registered yet)"
      exit 0
    fi
    printf '%-40s | %-20s | %-20s | age\n' "slug" "state" "started"
    printf '%-40s-+-%-20s-+-%-20s-+-%s\n' "$(printf '%.0s-' {1..40})" "$(printf '%.0s-' {1..20})" "$(printf '%.0s-' {1..20})" "$(printf '%.0s-' {1..10})"
    # All start events, then for each, look up latest event
    jq -r 'select(.event=="start") | [.run_id, .slug, .ts] | @tsv' < "$REGISTRY" \
      | while IFS=$'\t' read -r run_id slug start_ts; do
        latest_ev="$(jq -r --arg id "$run_id" 'select(.run_id==$id) | .event' < "$REGISTRY" | tail -1)"
        # Compute age from start_ts to now
        start_epoch="$(date -d "$start_ts" +%s 2>/dev/null || echo 0)"
        now_epoch="$(date -u +%s)"
        age_sec=$((now_epoch - start_epoch))
        if   [ "$age_sec" -lt 60 ];     then age="${age_sec}s"
        elif [ "$age_sec" -lt 3600 ];   then age="$((age_sec/60))m"
        elif [ "$age_sec" -lt 86400 ];  then age="$((age_sec/3600))h"
        else                                 age="$((age_sec/86400))d"
        fi
        printf '%-40s | %-20s | %-20s | %s\n' "$slug" "$latest_ev" "$start_ts" "$age"
      done
    ;;

  count-active)
    # Count runs whose latest state is NOT in TERMINAL_STATES
    if [ ! -s "$REGISTRY" ]; then echo 0; exit 0; fi
    n=0
    while IFS= read -r run_id; do
      [ -z "$run_id" ] && continue
      latest_ev="$(jq -r --arg id "$run_id" 'select(.run_id==$id) | .event' < "$REGISTRY" | tail -1)"
      case "$latest_ev" in
        done|abandoned|error) ;;
        *) n=$((n+1)) ;;
      esac
    done < <(jq -r 'select(.event=="start") | .run_id' < "$REGISTRY" | sort -u)
    echo "$n"
    ;;

  by-state)
    state="${1:?state required}"
    if [ ! -s "$REGISTRY" ]; then exit 0; fi
    while IFS= read -r run_id; do
      [ -z "$run_id" ] && continue
      latest_ev="$(jq -r --arg id "$run_id" 'select(.run_id==$id) | .event' < "$REGISTRY" | tail -1)"
      [ "$latest_ev" = "$state" ] && echo "$run_id"
    done < <(jq -r 'select(.event=="start") | .run_id' < "$REGISTRY" | sort -u)
    ;;

  *)
    echo "usage: $0 {start|transition|latest-state|resolve|field|list|count-active|by-state} ..." >&2
    exit 2
    ;;
esac

exit 0
