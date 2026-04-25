#!/usr/bin/env bash
# deploy.sh — install or update Claude Orchestra into ~/.claude/
#
# Usage:
#   ./deploy.sh             — deploy to ~/.claude/ (system-wide, all machines via NFS)
#   ./deploy.sh --dry-run   — preview what would change without writing anything
#   ./deploy.sh --diff      — show unified diff of every file that would change
#
# Idempotent: safe to re-run after any change in the repo.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE="${HOME}/.claude"
DRY_RUN=false
SHOW_DIFF=false

info()  { printf "\033[36m  •\033[0m %s\n" "$*"; }
ok()    { printf "\033[32m  ✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m  !\033[0m %s\n" "$*"; }
die()   { printf "\033[31m  ✗\033[0m %s\n" "$*"; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true   ;;
        --diff)    SHOW_DIFF=true ;;
        *) die "Unknown argument: $arg. Usage: ./deploy.sh [--dry-run] [--diff]" ;;
    esac
done

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
echo "  target: $CLAUDE"
$DRY_RUN  && echo "  mode:   DRY RUN (no writes)"
$SHOW_DIFF && echo "  mode:   DIFF (no writes)"
echo ""

# ── 1. Prerequisite checks ────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || die "jq is required (sudo apt install jq)"
[ -d "$CLAUDE" ] || die "~/.claude does not exist — is Claude Code installed?"

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

# Stripped versions (frontmatter removed) — consumed by run-tier.sh as
# --append-system-prompt-file. Generated once at deploy; byte-stable across
# subprocess invocations to maximise prompt-cache reuse.
$DRY_RUN || mkdir -p "$CLAUDE/agents/.stripped"
for f in "$REPO"/agents/*.md; do
    name="$(basename "$f")"
    dst="$CLAUDE/agents/.stripped/$name"
    if $DRY_RUN; then
        info "would generate stripped: $dst"
    else
        # Drop the YAML frontmatter (between first two `---` lines), keep body.
        awk 'BEGIN{f=0} /^---$/{f++; next} f>=2{print}' "$f" > "$dst.tmp" && mv -f "$dst.tmp" "$dst"
    fi
done
$DRY_RUN || ok "stripped: $CLAUDE/agents/.stripped/ ($(ls "$CLAUDE/agents/.stripped/" 2>/dev/null | wc -l) files)"

# ── 4. Slash commands ─────────────────────────────────────────────────────────
echo "Commands:"
for f in "$REPO"/commands/*.md; do
    copy_file "$f" "$CLAUDE/commands/$(basename "$f")"
done

# ── 5. Hook + tier scripts ────────────────────────────────────────────────────
echo "Scripts:"
for s in orchestra-hook.sh run-tier.sh format-stream.sh runs-registry.sh start-research.sh; do
    if [ -f "$REPO/scripts/$s" ]; then
        copy_file "$REPO/scripts/$s" "$CLAUDE/scripts/$s"
        $DRY_RUN || chmod +x "$CLAUDE/scripts/$s"
    fi
done

# ── 6. Orchestra config ───────────────────────────────────────────────────────
echo "Config:"
copy_file "$REPO/config/config.yaml" "$CLAUDE/orchestra/config.yaml"

# ── 7. Merge orchestra hooks into settings.json ───────────────────────────────
echo "Settings:"
SETTINGS="$CLAUDE/settings.json"
if [ ! -f "$SETTINGS" ]; then
    warn "settings.json not found; creating minimal one"
    $DRY_RUN || echo '{}' > "$SETTINGS"
fi

# Check idempotency: all orchestra PreToolUse matchers from the fragment present?
FRAGMENT="$REPO/config/settings-hooks.json"
EXPECTED_MATCHERS="$(jq -r '[.hooks.PreToolUse[].matcher] | sort | join(",")' "$FRAGMENT")"
CURRENT_MATCHERS="$(jq -r '([.hooks.PreToolUse // [] | .[]] | map(select(.hooks[].command | contains("orchestra-hook.sh"))) | map(.matcher) | sort | join(","))' "$SETTINGS" 2>/dev/null || echo "")"

if [ "$CURRENT_MATCHERS" = "$EXPECTED_MATCHERS" ] && jq -e '.hooks.SubagentStop' "$SETTINGS" >/dev/null 2>&1; then
    ok "unchanged: settings.json (hooks already present)"
else
    if $DRY_RUN; then
        info "would merge orchestra hooks into settings.json"
    else
        TMPFILE="$SETTINGS.orchestra-deploy.tmp"

        # Keep non-orchestra PreToolUse entries; replace all orchestra-hook.sh entries
        jq -s '
            .[0] as $existing |
            .[1].hooks as $new_hooks |
            ($existing.hooks.PreToolUse // []) as $existing_ptu |
            ($new_hooks.PreToolUse // []) as $new_ptu |
            ($existing_ptu | map(select(
                (.hooks // []) | map(.command // "") | map(contains("orchestra-hook.sh")) | any | not
            ))) as $non_orchestra_ptu |
            $existing
            | .hooks.PreToolUse  = ($non_orchestra_ptu + $new_ptu)
            | .hooks.SubagentStop = ($new_hooks.SubagentStop // [])
            | .hooks.PreCompact  = ($new_hooks.PreCompact // [])
        ' "$SETTINGS" "$FRAGMENT" > "$TMPFILE"

        mv -f "$TMPFILE" "$SETTINGS"
        ok "merged: settings.json (orchestra hooks updated)"
    fi
fi

# ── 8. Patch status-line.sh ───────────────────────────────────────────────────
echo "Status line:"
STATUS_LINE="$CLAUDE/scripts/status-line.sh"
if [ ! -f "$STATUS_LINE" ]; then
    warn "status-line.sh not found — skipping patch (see status-line/orchestra-block.sh)"
else
    # Idempotent re-deploy: if the block is already present, compare to the source.
    # If different, strip the old block and re-append. (Old logic was append-once-only,
    # which left the deployed block stale after orchestra-block.sh source updates.)
    BLOCK_PRESENT=false
    grep -q "ORCHESTRA_BLOCK_START" "$STATUS_LINE" 2>/dev/null && BLOCK_PRESENT=true

    if $BLOCK_PRESENT; then
        # Extract deployed block (from ORCHESTRA_BLOCK_START to just before "# Output the status line")
        DEPLOYED_BLOCK="$(awk '/^# ORCHESTRA_BLOCK_START/,/^# Output the status line/' "$STATUS_LINE" | sed '$d')"
        SOURCE_BLOCK="$(sed '/^#!/d; /^# orchestra-block.sh/d; /^# USAGE/d; /^#$/d; /^# Prerequisites/d; /^#   -/d; /^# deploy.sh will/d; /^# The presence/d' "$REPO/status-line/orchestra-block.sh")"
        if [ "$DEPLOYED_BLOCK" = "$SOURCE_BLOCK" ]; then
            ok "unchanged: status-line.sh (orchestra block already present, matches source)"
        elif $DRY_RUN; then
            info "would re-deploy orchestra block (source has changed)"
        else
            # Strip old block (from ORCHESTRA_BLOCK_START up to but not including "# Output the status line")
            TMPFILE="$STATUS_LINE.orchestra-deploy.tmp"
            awk '
                /^# ORCHESTRA_BLOCK_START/ { in_block=1; next }
                in_block && /^# Output the status line/ { in_block=0 }
                !in_block { print }
            ' "$STATUS_LINE" > "$TMPFILE.stripped"
            # Now append fresh block via the same awk-insert logic
            BLOCK_CONTENT=$(sed '/^#!/d; /^# orchestra-block.sh/d; /^# USAGE/d; /^#$/d; /^# Prerequisites/d; /^#   -/d; /^# deploy.sh will/d; /^# The presence/d' "$REPO/status-line/orchestra-block.sh")
            awk -v block="$BLOCK_CONTENT" '
                /^# Output the status line/ { print block; print ""; }
                { print }
            ' "$TMPFILE.stripped" > "$TMPFILE"
            rm -f "$TMPFILE.stripped"
            mv -f "$TMPFILE" "$STATUS_LINE"
            ok "updated: status-line.sh (orchestra block refreshed)"
        fi
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

# ── 9. Global gitignore ───────────────────────────────────────────────────────
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

echo ""
$DRY_RUN && echo "Dry run complete — no files written." || echo "Deploy complete."
echo ""
echo "  Quick-start:"
echo "    1. In Claude Code: Shift+Tab to enter plan mode"
echo "    2. Type /brain <task>   — full pipeline (Planner → Actor → Reviewer)"
echo "    3. Type /duo <task>     — lightweight pipeline (Sonnet plans, Haiku acts)"
echo "    4. See docs/design.md for full reference"
echo ""
