#!/usr/bin/env bash
# check-orphans.sh — find shell processes that outlived the subagent that spawned them.
#
# Why this exists: agent lifecycle and process lifecycle are not the same thing, and only
# the first is visible in the tooling. A subagent can report COMPLETED while a command it
# started keeps running — which both burns the box and holds the agent's harness row open,
# because the agent cannot finalise until every child exits.
#
# A subagent's own "I cleaned up" is the least-checked claim in its report, so this check
# is deliberately external to the agent.
#
# Usage:
#   check-orphans.sh                  # report only (default)
#   check-orphans.sh --kill           # report, then kill what was found
#   check-orphans.sh --min-seconds N  # only consider processes older than N (default 600)
#
# Exit status: 0 = clean, 1 = orphans found (whether or not --kill was passed).
#
# SAFETY — match the binary, never a pattern string.
#   A previous incident used `pgrep -f 'bfs -S dfs|find / -path /proc'`. That pattern appears
#   in the command line of the shell running it, so it matched and killed its own pipeline.
#   Here: `pgrep -x` matches the executable name exactly, and this script's own PIDs are
#   excluded explicitly. Never reintroduce a -f pattern match that feeds kill.

set -uo pipefail

DO_KILL=false
MIN_SECONDS=600

while [ $# -gt 0 ]; do
    case "$1" in
        --kill)        DO_KILL=true;        shift ;;
        --min-seconds) MIN_SECONDS="${2:-600}"; shift 2 ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "check-orphans.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# PIDs belonging to this check itself — the whole ancestor chain, not just the parent.
#
# $$ and $PPID are NOT enough. Invoked inside a command substitution, the shell that called
# this script is the GRANDparent, so a two-level guard leaves it exposed — and that shell is
# typically Claude Code's own Bash wrapper, whose command line contains `shell-snapshots`.
# A --kill run with a two-level guard would terminate the session that invoked it. That was
# observed, not theorised.
SELF_PIDS=" "

_ppid_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]'; }

_collect_ancestors() {
    local pid="$1" guard=0
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$guard" -lt 64 ]; do
        SELF_PIDS="${SELF_PIDS}${pid} "
        pid="$(_ppid_of "$pid")"
        guard=$(( guard + 1 ))
    done
}
_collect_ancestors "$$"

is_self() {
    case "$SELF_PIDS" in *" $1 "*) return 0 ;; esac
    return 1
}

# Snapshot ps ONCE, before any filtering runs. Filtering after the snapshot means the
# filter's own process cannot appear in the data it filters — the self-match trap.
PS_SNAPSHOT="$(ps -eo pid=,etimes=,args= 2>/dev/null || true)"

FOUND_PIDS=""
FOUND_REPORT=""

record() {
    # $1 = pid, $2 = elapsed seconds, $3... = command
    local pid="$1" secs="$2"; shift 2
    is_self "$pid" && return 0
    case " $FOUND_PIDS " in *" $pid "*) return 0 ;; esac
    FOUND_PIDS="${FOUND_PIDS}${pid} "
    FOUND_REPORT="${FOUND_REPORT}$(printf '  pid %-8s %5sm  %s\n' "$pid" "$(( secs / 60 ))" "$*")"$'\n'
}

# --- 1. Filesystem-walk binaries, matched by exact executable name ------------------------
# `find` on this host execs as `bfs`; check both names rather than assuming.
for binary in bfs find; do
    while read -r pid; do
        [ -n "$pid" ] || continue
        is_self "$pid" && continue
        line="$(printf '%s\n' "$PS_SNAPSHOT" | awk -v p="$pid" '$1==p {print; exit}')"
        [ -n "$line" ] || continue
        secs="$(printf '%s\n' "$line" | awk '{print $2}')"
        [ "${secs:-0}" -ge "$MIN_SECONDS" ] 2>/dev/null || continue
        record "$pid" "$secs" "$(printf '%s\n' "$line" | cut -d' ' -f3-)"
    done < <(pgrep -x "$binary" 2>/dev/null || true)
done

# --- 2. Anything long-running launched through a shell snapshot ---------------------------
# Claude Code runs Bash tool calls via ~/.claude/shell-snapshots/*. A process still carrying
# that path long after its agent finished is the shape we care about.
while read -r pid secs rest; do
    [ -n "${pid:-}" ] || continue
    is_self "$pid" && continue
    [ "${secs:-0}" -ge "$MIN_SECONDS" ] 2>/dev/null || continue
    record "$pid" "$secs" "$rest"
done < <(printf '%s\n' "$PS_SNAPSHOT" | grep 'shell-snapshots' 2>/dev/null || true)

# --- Report -------------------------------------------------------------------------------
if [ -z "$FOUND_PIDS" ]; then
    echo "check-orphans: clean (nothing older than ${MIN_SECONDS}s)"
    exit 0
fi

count="$(printf '%s' "$FOUND_PIDS" | wc -w | tr -d ' ')"
echo "check-orphans: ${count} orphan candidate(s) older than ${MIN_SECONDS}s:"
printf '%s' "$FOUND_REPORT"

if $DO_KILL; then
    echo "check-orphans: killing by PID (never by pattern)"
    for pid in $FOUND_PIDS; do
        is_self "$pid" && continue
        if kill -TERM "$pid" 2>/dev/null; then
            echo "  TERM $pid"
        else
            echo "  TERM $pid — failed or already gone"
        fi
    done
    sleep 2
    for pid in $FOUND_PIDS; do
        is_self "$pid" && continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null && echo "  KILL $pid"
        fi
    done
else
    echo "check-orphans: report only — pass --kill to terminate these"
fi

exit 1
