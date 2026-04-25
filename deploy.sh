#!/usr/bin/env bash
# deploy.sh — install or update Claude Orchestra into a Claude Code config dir
#
# Usage:
#   ./deploy.sh --global              — deploy to ~/.claude/ (system-wide)
#   ./deploy.sh --local               — deploy to $PWD/.claude/ (current project only)
#   ./deploy.sh --global --dry-run    — preview global deploy without writing
#   ./deploy.sh --local  --diff       — show unified diff for local deploy
#
# --global and --local are mutually exclusive and required.
# --dry-run and --diff are additive modifiers; both can be combined with either target.
#
# Idempotent: safe to re-run after any change in the repo.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=""
DRY_RUN=false
SHOW_DIFF=false

info()  { printf "\033[36m  •\033[0m %s\n" "$*"; }
ok()    { printf "\033[32m  ✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m  !\033[0m %s\n" "$*"; }
die()   { printf "\033[31m  ✗\033[0m %s\n" "$*"; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --global)  TARGET="global" ;;
        --local)   TARGET="local"  ;;
        --dry-run) DRY_RUN=true    ;;
        --diff)    SHOW_DIFF=true  ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "Usage: ./deploy.sh --global|--local [--dry-run] [--diff]"
    echo ""
    echo "  --global   Deploy to ~/.claude/  (system-wide)"
    echo "  --local    Deploy to \$PWD/.claude/  (current project only)"
    echo "  --dry-run  Show what would change without writing anything"
    echo "  --diff     Show unified diff of every file that would change"
    exit 1
fi

if [ "$TARGET" = "global" ]; then
    CLAUDE="${HOME}/.claude"
else
    CLAUDE="${CLAUDE_PROJECT_DIR:-$PWD}/.claude"
fi

copy_file() {
    local src="$1" dst="$2"
    if $SHOW_DIFF && [ -f "$dst" ]; then
        diff -u "$dst" "$src" && true
        return
    fi
    if $DRY_RUN; then
        if [ -f "$dst" ]; then
            diff -q "$src" "$dst" >/dev/null 2>&1 && info "unchanged: $dst" || info "would update: $dst"
        else
            info "would create: $dst"
        fi
        return
    fi
    if [ -f "$dst" ] && diff -q "$src" "$dst" >/dev/null 2>&1; then
        ok "unchanged: $(basename "$dst")"
    else
        cp -f "$src" "$dst"
        ok "deployed: $(basename "$dst")"
    fi
}

echo ""
echo "Claude Orchestra — deploy"
echo "  repo:   $REPO"
echo "  target: $CLAUDE  (--$TARGET)"
$DRY_RUN  && echo "  mode:   DRY RUN (no writes)"
$SHOW_DIFF && echo "  mode:   DIFF (no writes)"
echo ""

# ── 1. Prerequisite checks ────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || die "jq is required (sudo apt install jq)"

# ── 2. Create target directories ─────────────────────────────────────────────
for dir in agents commands scripts orchestra; do
    $DRY_RUN || mkdir -p "$CLAUDE/$dir"
done
$DRY_RUN || mkdir -p "$CLAUDE/orchestra/logs"

# ── 3. Subagent definitions ───────────────────────────────────────────────────
echo "Agents:"
for f in "$REPO"/agents/*.md; do
    copy_file "$f" "$CLAUDE/agents/$(basename "$f")"
done

# ── 4. Slash commands ─────────────────────────────────────────────────────────
echo "Commands:"
for f in "$REPO"/commands/*.md; do
    copy_file "$f" "$CLAUDE/commands/$(basename "$f")"
done

# ── 5. Hook script ────────────────────────────────────────────────────────────
echo "Scripts:"
copy_file "$REPO/scripts/orchestra-hook.sh" "$CLAUDE/scripts/orchestra-hook.sh"
$DRY_RUN || chmod +x "$CLAUDE/scripts/orchestra-hook.sh"

# ── 6. Orchestra config ───────────────────────────────────────────────────────
echo "Config:"
copy_file "$REPO/config/config.yaml" "$CLAUDE/orchestra/config.yaml"

# ── 7-9. Global-only steps ───────────────────────────────────────────────────
if [ "$TARGET" = "global" ]; then

    # ── 7. Merge orchestra hooks into settings.json ───────────────────────────
    echo "Settings:"
    SETTINGS="$CLAUDE/settings.json"
    if [ ! -f "$SETTINGS" ]; then
        warn "settings.json not found; creating minimal one"
        $DRY_RUN || echo '{}' > "$SETTINGS"
    fi

    if jq -e '.hooks.SubagentStop' "$SETTINGS" >/dev/null 2>&1; then
        ok "unchanged: settings.json (hooks already present)"
    else
        if $DRY_RUN; then
            info "would merge orchestra hooks into settings.json"
        else
            FRAGMENT="$REPO/config/settings-hooks.json"
            TMPFILE="$SETTINGS.orchestra-deploy.tmp"

            jq -s '
                .[0] as $existing |
                .[1].hooks as $new_hooks |
                ($existing.hooks.PreToolUse // []) as $existing_ptu |
                ($new_hooks.PreToolUse // []) as $new_ptu |
                ($existing_ptu | map(select(.matcher != "Agent"))) as $cleaned_ptu |
                $existing
                | .hooks.PreToolUse  = ($cleaned_ptu + $new_ptu)
                | .hooks.SubagentStop = ($new_hooks.SubagentStop // [])
                | .hooks.PreCompact  = ($new_hooks.PreCompact // [])
            ' "$SETTINGS" "$FRAGMENT" > "$TMPFILE"

            mv -f "$TMPFILE" "$SETTINGS"
            ok "merged: settings.json (orchestra hooks added)"
        fi
    fi

    # ── 8. Patch status-line.sh ───────────────────────────────────────────────
    echo "Status line:"
    STATUS_LINE="$CLAUDE/scripts/status-line.sh"
    if [ ! -f "$STATUS_LINE" ]; then
        warn "status-line.sh not found — skipping patch (see status-line/orchestra-block.sh)"
    else
        if grep -q "ORCHESTRA_BLOCK_START" "$STATUS_LINE" 2>/dev/null; then
            ok "unchanged: status-line.sh (orchestra block already present)"
        else
            if $DRY_RUN; then
                info "would append orchestra block to status-line.sh"
            else
                BLOCK="$REPO/status-line/orchestra-block.sh"
                BLOCK_CONTENT=$(sed '/^#!/d; /^# orchestra-block.sh/d; /^# USAGE/d; /^#$/d; /^# Prerequisites/d; /^#   -/d; /^# deploy.sh will/d; /^# The presence/d' "$BLOCK")
                TMPFILE="$STATUS_LINE.orchestra-deploy.tmp"
                awk -v block="$BLOCK_CONTENT" '
                    /^# Output the status line/ { print block; print ""; }
                    { print }
                ' "$STATUS_LINE" > "$TMPFILE"
                mv -f "$TMPFILE" "$STATUS_LINE"
                ok "patched: status-line.sh (orchestra block appended)"
            fi
        fi
    fi

    # ── 9. Global gitignore ───────────────────────────────────────────────────
    echo "Gitignore:"
    GLOBAL_GI="${HOME}/.gitignore_global"
    GI_ENTRY=".claude/orchestra/"
    if grep -qF "$GI_ENTRY" "$GLOBAL_GI" 2>/dev/null; then
        ok "unchanged: ~/.gitignore_global"
    else
        if $DRY_RUN; then
            info "would add $GI_ENTRY to ~/.gitignore_global"
        else
            printf "\n# Claude Orchestra runtime state (auto-created in every project)\n%s\n" "$GI_ENTRY" >> "$GLOBAL_GI"
            git config --global core.excludesFile "$GLOBAL_GI"
            ok "updated: ~/.gitignore_global"
        fi
    fi

fi  # end --global-only steps

echo ""
$DRY_RUN && echo "Dry run complete — no files written." || echo "Deploy complete."
echo ""
echo "  Quick-start:"
echo "    1. In Claude Code: Shift+Tab to enter plan mode"
echo "    2. Type /brain <task>   — full pipeline (Planner → Actor → Reviewer)"
echo "    3. Type /duo <task>     — lightweight pipeline (Sonnet plans, Haiku acts)"
echo "    4. See docs/design.md for full reference"
echo ""
