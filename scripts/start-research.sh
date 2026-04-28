#!/usr/bin/env bash
# scripts/start-research.sh
#
# Spawn the Phase 0 RESEARCH dialogue session for /brain. Each invocation creates
# a new run with its own state subdir and registers it in runs.jsonl.
#
# Usage:
#   start-research.sh <task>
#
# Output (stdout, single line): RUN_ID=<run_id>
# (Caller — brain.md launcher — parses this and prints user-facing instructions.)
#
# Behaviour:
#   - In tmux: spawns `tmux new-window -e ENV=VAL ...` running interactive
#     `claude --bare --model … --append-system-prompt-file <prepared-prompt>`
#   - Outside tmux (VSCode etc.): writes /tmp/brain-launch-<run_id>.sh; caller
#     instructs user to run it manually in a terminal split.
#
# Design reference: docs/design.md — /brain Phase 0 Amendment.

set -uo pipefail

TASK="${1:-}"
if [ -z "$TASK" ]; then
  echo "usage: $0 <task>" >&2
  exit 2
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ORCHESTRA_DIR="${PROJECT_DIR}/.claude/orchestra"
REGISTRY_SH="${HOME}/.claude/scripts/runs-registry.sh"
RESEARCHER_SYSTEM_PROMPT="${HOME}/.claude/agents/.stripped/researcher.md"
GLOBAL_CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
PROJECT_CLAUDE_MD="${PROJECT_DIR}/CLAUDE.md"

if [ ! -f "$RESEARCHER_SYSTEM_PROMPT" ]; then
  echo "researcher.md not deployed (run ./deploy.sh first)" >&2
  exit 2
fi
if [ ! -x "$REGISTRY_SH" ]; then
  echo "runs-registry.sh not deployed (run ./deploy.sh first)" >&2
  exit 2
fi

# ---------- Slug + run_id derivation ----------
slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-60
}
SLUG="$(slug "$TASK")"
[ -z "$SLUG" ] && SLUG="task"
TS_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="${TS_UTC}-${SLUG}"
RUN_DIR="${ORCHESTRA_DIR}/runs/${RUN_ID}"

# ---------- Per-run state dir ----------
mkdir -p "${RUN_DIR}/logs"

# ---------- Per-run system prompt (substitute placeholders) ----------
PERRUN_PROMPT="${RUN_DIR}/researcher-prompt.txt"
sed -e "s|{{RUN_ID}}|${RUN_ID}|g" \
    -e "s|{{RUN_DIR}}|${RUN_DIR}|g" \
    -e "s|{{SLUG}}|${SLUG}|g" \
    "$RESEARCHER_SYSTEM_PROMPT" > "$PERRUN_PROMPT"

# ---------- Build the claude command argv ----------
CLAUDE_ARGS=(
  --bare
  --model claude-opus-4-7
  --permission-mode bypassPermissions
  --append-system-prompt-file "$PERRUN_PROMPT"
)
[ -f "$GLOBAL_CLAUDE_MD"  ] && CLAUDE_ARGS+=( --append-system-prompt-file "$GLOBAL_CLAUDE_MD" )
[ -f "$PROJECT_CLAUDE_MD" ] && CLAUDE_ARGS+=( --append-system-prompt-file "$PROJECT_CLAUDE_MD" )

# Initial user-message: the task itself, framed so the spawned session knows
# what's being interrogated. Piped via stdin (interactive claude reads stdin
# as the first user message).
INITIAL_PROMPT_FILE="${RUN_DIR}/initial-prompt.txt"
cat > "$INITIAL_PROMPT_FILE" <<EOF
The user typed in the launcher chat panel:

    /brain ${TASK}

Begin Phase 0 — RESEARCH. Interrogate this request per your system prompt.
Do NOT immediately produce a plan or code; ask clarifying questions and push
back on framing first.
EOF

# Quote helper for safe shell composition
qt() { printf '%q' "$1"; }

CLAUDE_CMD="claude"
for a in "${CLAUDE_ARGS[@]}"; do CLAUDE_CMD+=" $(qt "$a")"; done

# ---------- Register start event ----------
WINDOW_NAME="$SLUG"
"$REGISTRY_SH" start "$RUN_ID" "$SLUG" "$TASK" "$WINDOW_NAME" "claude-opus-4-7"

# ---------- Spawn (branch on tmux) ----------
if [ -n "${TMUX:-}" ] && [ -z "${CLAUDE_ORCHESTRA_DISABLE_TMUX:-}" ]; then
  # Avoid clobber if a window with the same slug already exists in this tmux session
  WIN_BASE="$WINDOW_NAME"
  i=1
  while tmux list-windows -F '#W' 2>/dev/null | grep -qE "^${WIN_BASE}$"; do
    WINDOW_NAME="${WIN_BASE}_${i}"; i=$((i+1))
  done

  TMUX_ENV_ARGS=()
  [ -n "${ANTHROPIC_API_KEY:-}" ] && TMUX_ENV_ARGS+=( -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" )
  TMUX_ENV_ARGS+=( -e "CLAUDE_PROJECT_DIR=$PROJECT_DIR" )
  TMUX_ENV_ARGS+=( -e "CLAUDE_BRAIN_RUN_ID=$RUN_ID" )
  TMUX_ENV_ARGS+=( -e "CLAUDE_BRAIN_RUN_DIR=$RUN_DIR" )
  [ -n "${HOME:-}" ] && TMUX_ENV_ARGS+=( -e "HOME=$HOME" )
  [ -n "${PATH:-}" ] && TMUX_ENV_ARGS+=( -e "PATH=$PATH" )

  # Wrap claude in a stdin-fed initial-prompt + a sentinel marker on exit.
  WRAPPED="${CLAUDE_CMD} < $(qt "$INITIAL_PROMPT_FILE")"
  tmux new-window -d -n "$WINDOW_NAME" "${TMUX_ENV_ARGS[@]}" "bash -lc $(qt "$WRAPPED")" 2>/dev/null || {
    echo "tmux new-window failed; falling back to non-tmux launcher script" >&2
    LAUNCH_SCRIPT="/tmp/brain-launch-${RUN_ID}.sh"
    write_launcher_script() {
      cat > "$LAUNCH_SCRIPT" <<LAUNCHER
#!/usr/bin/env bash
# Generated launcher for /brain run: $RUN_ID
export CLAUDE_PROJECT_DIR=$(qt "$PROJECT_DIR")
export CLAUDE_BRAIN_RUN_ID=$(qt "$RUN_ID")
export CLAUDE_BRAIN_RUN_DIR=$(qt "$RUN_DIR")
exec ${CLAUDE_CMD} < $(qt "$INITIAL_PROMPT_FILE")
LAUNCHER
      chmod +x "$LAUNCH_SCRIPT"
      CLIPBOARD_TOOL=""
      if   command -v wl-copy  >/dev/null 2>&1; then CLIPBOARD_TOOL="wl-copy"
      elif command -v xclip    >/dev/null 2>&1; then CLIPBOARD_TOOL="xclip"
      elif command -v pbcopy   >/dev/null 2>&1; then CLIPBOARD_TOOL="pbcopy"
      fi
      if [ -n "$CLIPBOARD_TOOL" ]; then
        case "$CLIPBOARD_TOOL" in
          wl-copy) printf '%s' "bash $LAUNCH_SCRIPT" | wl-copy 2>/dev/null || CLIPBOARD_TOOL="" ;;
          xclip)   printf '%s' "bash $LAUNCH_SCRIPT" | xclip -selection clipboard -l 1 2>/dev/null || CLIPBOARD_TOOL="" ;;
          pbcopy)  printf '%s' "bash $LAUNCH_SCRIPT" | pbcopy 2>/dev/null || CLIPBOARD_TOOL="" ;;
        esac
      fi
      if [ -n "$CLIPBOARD_TOOL" ]; then
        echo "CLIPBOARD=$CLIPBOARD_TOOL"
      else
        echo "CLIPBOARD=no"
      fi
    }
    write_launcher_script
    echo "RUN_ID=$RUN_ID"
    echo "MODE=manual"
    echo "LAUNCH_SCRIPT=$LAUNCH_SCRIPT"
    exit 0
  }

  echo "RUN_ID=$RUN_ID"
  echo "MODE=tmux"
  echo "WINDOW=$WINDOW_NAME"
else
  # Non-tmux: write a manual launcher script the user runs in a terminal split
  LAUNCH_SCRIPT="/tmp/brain-launch-${RUN_ID}.sh"
  cat > "$LAUNCH_SCRIPT" <<LAUNCHER
#!/usr/bin/env bash
# Generated launcher for /brain run: $RUN_ID
# Open a terminal split (Ctrl+\` in VSCode) and run: bash $LAUNCH_SCRIPT
export CLAUDE_PROJECT_DIR=$(qt "$PROJECT_DIR")
export CLAUDE_BRAIN_RUN_ID=$(qt "$RUN_ID")
export CLAUDE_BRAIN_RUN_DIR=$(qt "$RUN_DIR")
exec ${CLAUDE_CMD} < $(qt "$INITIAL_PROMPT_FILE")
LAUNCHER
  chmod +x "$LAUNCH_SCRIPT"

  CLIPBOARD_TOOL=""
  if   command -v wl-copy  >/dev/null 2>&1; then CLIPBOARD_TOOL="wl-copy"
  elif command -v xclip    >/dev/null 2>&1; then CLIPBOARD_TOOL="xclip"
  elif command -v pbcopy   >/dev/null 2>&1; then CLIPBOARD_TOOL="pbcopy"
  fi
  if [ -n "$CLIPBOARD_TOOL" ]; then
    case "$CLIPBOARD_TOOL" in
      wl-copy) printf '%s' "bash $LAUNCH_SCRIPT" | wl-copy 2>/dev/null || CLIPBOARD_TOOL="" ;;
      xclip)   printf '%s' "bash $LAUNCH_SCRIPT" | xclip -selection clipboard -l 1 2>/dev/null || CLIPBOARD_TOOL="" ;;
      pbcopy)  printf '%s' "bash $LAUNCH_SCRIPT" | pbcopy 2>/dev/null || CLIPBOARD_TOOL="" ;;
    esac
  fi
  if [ -n "$CLIPBOARD_TOOL" ]; then
    echo "CLIPBOARD=$CLIPBOARD_TOOL"
  else
    echo "CLIPBOARD=no"
  fi

  echo "RUN_ID=$RUN_ID"
  echo "MODE=manual"
  echo "LAUNCH_SCRIPT=$LAUNCH_SCRIPT"
fi

exit 0
