#!/usr/bin/env bash
# scripts/run-tier.sh
#
# Spawns a `claude -p` subprocess for a pipeline tier (planner / actor / reviewer)
# with explicit model + permission mode + system prompt, streams its stream-json
# output through format-stream.sh (in tmux: a dedicated window; outside tmux: a
# logfile that VSCode users tail).
#
# Usage:
#   run-tier.sh <stage> <model> <agent-name> <perm-mode> <prompt-file> [extra-flags...]
#
# Args:
#   stage        plan | implement | review
#   model        claude-sonnet-4-6 | claude-haiku-4-5-20251001 | etc.
#   agent-name   planner | actor | reviewer  (resolved to .stripped/<name>.md)
#   perm-mode    default | acceptEdits | bypassPermissions | plan
#   prompt-file  absolute path to file containing the user prompt for this tier
#   extra-flags  optional extra flags forwarded to `claude -p` (e.g. --allowedTools "...")
#
# Exits with the path to the result file on stdout. Caller polls until result
# file exists and is non-empty, then reads its contents.
#
# Design reference: docs/design.md — Option A subprocess Amendment 2026-04-26.

set -uo pipefail

STAGE="${1:-}"
MODEL="${2:-}"
AGENT_NAME="${3:-}"
PERM_MODE="${4:-default}"
PROMPT_FILE="${5:-}"
shift 5 2>/dev/null || true
EXTRA_FLAGS=("$@")

if [ -z "$STAGE" ] || [ -z "$MODEL" ] || [ -z "$AGENT_NAME" ] || [ -z "$PROMPT_FILE" ]; then
  echo "usage: run-tier.sh <stage> <model> <agent-name> <perm-mode> <prompt-file> [extra-flags...]" >&2
  exit 2
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "run-tier.sh: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ORCHESTRA_DIR="${PROJECT_DIR}/.claude/orchestra"
LOGS_DIR="${ORCHESTRA_DIR}/logs"
mkdir -p "$LOGS_DIR" 2>/dev/null || true

STAMP_TS="$(date -u +%Y%m%dT%H%M%SZ)"
STAMP_HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
STAMP_PID=$$

LOGFILE="${LOGS_DIR}/${STAGE}-${STAMP_TS}-${STAMP_HOST}-${STAMP_PID}.log"
RESULT_FILE="${ORCHESTRA_DIR}/${STAGE}-result-${STAMP_TS}-${STAMP_PID}.txt"

# Stripped agent file (frontmatter removed); produced by deploy.sh.
STRIPPED_AGENT="${HOME}/.claude/agents/.stripped/${AGENT_NAME}.md"
if [ ! -f "$STRIPPED_AGENT" ]; then
  echo "run-tier.sh: stripped agent file not found: $STRIPPED_AGENT" >&2
  echo "  (run ./deploy.sh to generate stripped agent files)" >&2
  exit 2
fi

# Optional CLAUDE.md files; --bare skips auto-discovery so we inject explicitly.
GLOBAL_CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
PROJECT_CLAUDE_MD="${PROJECT_DIR}/CLAUDE.md"

# Build the claude -p command argv as an array for safe quoting.
CLAUDE_ARGS=(
  -p
  --bare
  --model "$MODEL"
  --append-system-prompt-file "$STRIPPED_AGENT"
  --output-format stream-json
  --include-partial-messages
  --verbose
  --permission-mode "$PERM_MODE"
  --no-session-persistence
)

if [ -f "$GLOBAL_CLAUDE_MD" ]; then
  CLAUDE_ARGS+=( --append-system-prompt-file "$GLOBAL_CLAUDE_MD" )
fi
if [ -f "$PROJECT_CLAUDE_MD" ]; then
  CLAUDE_ARGS+=( --append-system-prompt-file "$PROJECT_CLAUDE_MD" )
fi

# Forward extras (e.g. --allowedTools, --add-dir).
for arg in "${EXTRA_FLAGS[@]}"; do
  CLAUDE_ARGS+=( "$arg" )
done

# Update live-feed pointers so a single `tail -f live.log` follows the pipeline.
printf 'ACTIVE_LOGFILE=%s\n' "$LOGFILE" > "${ORCHESTRA_DIR}/live-stage.env" 2>/dev/null || true
ln -sfn "$LOGFILE" "${ORCHESTRA_DIR}/live.log" 2>/dev/null || true

# Build the command string the subprocess will run. Quote everything carefully.
# We need: claude <args> < <prompt-file> | RESULT_FILE=... format-stream.sh | tee -a <logfile>
quote_args() {
  local out=""
  local a
  for a in "$@"; do
    out+=" $(printf '%q' "$a")"
  done
  printf '%s' "$out"
}

CLAUDE_CMD_STR="claude$(quote_args "${CLAUDE_ARGS[@]}")"
PROMPT_FILE_Q="$(printf '%q' "$PROMPT_FILE")"
RESULT_FILE_Q="$(printf '%q' "$RESULT_FILE")"
LOGFILE_Q="$(printf '%q' "$LOGFILE")"
FORMATTER="${HOME}/.claude/scripts/format-stream.sh"
FORMATTER_Q="$(printf '%q' "$FORMATTER")"

# Compose the pipeline. Note: stderr is merged into stdout so errors appear in the feed.
# After the pipeline exits, clear live-stage.env so post-tier hooks no-op (otherwise
# subsequent Bash calls in the parent session would keep appending to this stage's log).
LIVE_ENV_Q="$(printf '%q' "${ORCHESTRA_DIR}/live-stage.env")"
PIPELINE="${CLAUDE_CMD_STR} < ${PROMPT_FILE_Q} 2>&1 | RESULT_FILE=${RESULT_FILE_Q} ${FORMATTER_Q} | tee -a ${LOGFILE_Q}; rm -f ${LIVE_ENV_Q}"

# Branch on tmux availability.
if [ -n "${TMUX:-}" ] && [ -z "${CLAUDE_ORCHESTRA_DISABLE_TMUX:-}" ]; then
  # Compute next available window name (handles concurrent tier_1, tier_2 etc.)
  WINDOW_BASE="$STAGE"
  EXISTING="$(tmux list-windows -F '#W' 2>/dev/null | grep -cE "^${WINDOW_BASE}(_[0-9]+)?( ✓)?$" 2>/dev/null || echo 0)"
  EXISTING="${EXISTING//[^0-9]/}"
  EXISTING="${EXISTING:-0}"
  if [ "$EXISTING" -eq 0 ] 2>/dev/null; then
    WINDOW_NAME="$WINDOW_BASE"
  else
    WINDOW_NAME="${WINDOW_BASE}_${EXISTING}"
  fi

  # Wrap so the window persists briefly after completion to show the final summary.
  WRAPPED="${PIPELINE}; echo; echo '── window will close in 120s — Ctrl-b & to close now ──'; sleep 120"
  tmux new-window -d -n "$WINDOW_NAME" "bash -c $(printf '%q' "$WRAPPED")" 2>/dev/null || true
else
  # No tmux: run pipeline detached, output goes to logfile via tee; user tails live.log.
  nohup bash -c "$PIPELINE" </dev/null >/dev/null 2>&1 &
fi

# Print the result file path so the caller can poll it.
printf '%s\n' "$RESULT_FILE"
exit 0
