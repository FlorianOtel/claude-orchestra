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

# ── 4. Slash commands ─────────────────────────────────────────────────────────
echo "Commands:"
for f in "$REPO"/commands/*.md; do
    copy_file "$f" "$CLAUDE/commands/$(basename "$f")"
done

# ── 5. Hook script ────────────────────────────────────────────────────────────
echo "Scripts:"
for s in orchestra-hook.sh telemetry-summarize.sh telemetry-report.sh otel-headers-helper.sh; do
    if [ -f "$REPO/scripts/$s" ]; then
        copy_file "$REPO/scripts/$s" "$CLAUDE/scripts/$s"
        $DRY_RUN || chmod +x "$CLAUDE/scripts/$s"
    fi
done
# Python parsers — no chmod
if [ -f "$REPO/scripts/telemetry-summarize.py" ]; then
    copy_file "$REPO/scripts/telemetry-summarize.py" "$CLAUDE/scripts/telemetry-summarize.py"
fi
if [ -f "$REPO/scripts/native-session-finalize.py" ]; then
    copy_file "$REPO/scripts/native-session-finalize.py" "$CLAUDE/scripts/native-session-finalize.py"
fi
if [ -f "$REPO/scripts/native-session-report.py" ]; then
    copy_file "$REPO/scripts/native-session-report.py" "$CLAUDE/scripts/native-session-report.py"
fi
if [ -f "$REPO/scripts/session-report.py" ]; then
    copy_file "$REPO/scripts/session-report.py" "$CLAUDE/scripts/session-report.py"
fi

# Shell wrappers
if [ -f "$REPO/scripts/native-session-report.sh" ]; then
    copy_file "$REPO/scripts/native-session-report.sh" "$CLAUDE/scripts/native-session-report.sh"
    $DRY_RUN || chmod +x "$CLAUDE/scripts/native-session-report.sh"
fi
if [ -f "$REPO/scripts/session-report.sh" ]; then
    copy_file "$REPO/scripts/session-report.sh" "$CLAUDE/scripts/session-report.sh"
    $DRY_RUN || chmod +x "$CLAUDE/scripts/session-report.sh"
fi

# Clean up artifacts deleted in the headless→subagents revert (idempotent).
# Per-category orphan removal — only delete specific known-deleted files,
# not "anything not in repo" (operator may have personal commands/agents).
if ! $DRY_RUN; then
    # 7a. Headless scripts (Step 7 of the revert plan).
    for orphan in run-tier.sh format-stream.sh runs-registry.sh start-research.sh; do
        if [ -f "$CLAUDE/scripts/$orphan" ]; then
            rm -f "$CLAUDE/scripts/$orphan"
            ok "cleaned orphan: $CLAUDE/scripts/$orphan"
        fi
    done

    # 7b. Stripped agent variants (consumed by run-tier.sh; gone with it).
    if [ -d "$CLAUDE/agents/.stripped" ]; then
        rm -rf "$CLAUDE/agents/.stripped"
        ok "cleaned orphan: $CLAUDE/agents/.stripped/"
    fi

    # 7c. Obsolete commands (Step 6 of the revert plan, plus the duo session-bracketing redesign).
    # duo.md was replaced by duo-start.md / duo-end.md / duo-abandon.md (2026-05-05).
    # duo-stop.md was renamed to duo-end.md (2026-05-05).
    # duo-start.md was renamed to duo-plan.md, duo-end.md to duo-act.md (2026-05-06).
    # brain-abandon.md was previously deferred but is now shipped as the explicit
    # /brain cancel command (paired with the new .brain-inflight marker).
    for orphan in explore.md brain-resume.md brain-status.md orchestra-mode.md duo.md duo-stop.md duo-start.md duo-end.md; do
        if [ -f "$CLAUDE/commands/$orphan" ]; then
            rm -f "$CLAUDE/commands/$orphan"
            ok "cleaned orphan: $CLAUDE/commands/$orphan"
        fi
    done

    # 7d. Researcher agent (Phase 0 dialogue agent; Phase 0 now inline in /brain).
    if [ -f "$CLAUDE/agents/researcher.md" ]; then
        rm -f "$CLAUDE/agents/researcher.md"
        ok "cleaned orphan: $CLAUDE/agents/researcher.md"
    fi
fi

# ── 6. Orchestra config ───────────────────────────────────────────────────────
echo "Config:"
copy_file "$REPO/config/config.yaml" "$CLAUDE/orchestra/config.yaml"
copy_file "$REPO/config/pricing.yaml" "$CLAUDE/orchestra/pricing.yaml"

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

if [ "$CURRENT_MATCHERS" = "$EXPECTED_MATCHERS" ] && jq -e '.hooks.SubagentStop' "$SETTINGS" >/dev/null 2>&1 && jq -e '.hooks.Stop' "$SETTINGS" >/dev/null 2>&1; then
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
            | .hooks.Stop = ($new_hooks.Stop // [])
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
        SOURCE_BLOCK="$(sed '/^#!/d; /^# orchestra-block.sh/d; /^# USAGE/d; /^# just before the final/d; /^#$/d; /^# Prerequisites/d; /^#   -/d; /^# deploy.sh will/d; /^# The presence/d' "$REPO/status-line/orchestra-block.sh")"
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
                !in_block && /ORCHESTRA_BLOCK_START/ { next }
                !in_block && /inline just before the final/ { next }
                !in_block { print }
            ' "$STATUS_LINE" > "$TMPFILE.stripped"
            # Now append fresh block via the same awk-insert logic
            sed '/^#!/d; /^# orchestra-block.sh/d; /^# USAGE/d; /^# just before the final/d; /^#$/d; /^# Prerequisites/d; /^#   -/d; /^# deploy.sh will/d; /^# The presence/d' "$REPO/status-line/orchestra-block.sh" > "$TMPFILE.block"
            awk -v bfile="$TMPFILE.block" '
                /^# Output the status line/ { while ((getline line < bfile) > 0) print line; print ""; }
                { print }
            ' "$TMPFILE.stripped" > "$TMPFILE"
            rm -f "$TMPFILE.stripped" "$TMPFILE.block"
            mv -f "$TMPFILE" "$STATUS_LINE"
            chmod +x "$STATUS_LINE"
            ok "updated: status-line.sh (orchestra block refreshed)"
        fi
    else
        if $DRY_RUN; then
            info "would append orchestra block to status-line.sh"
        else
            BLOCK="$REPO/status-line/orchestra-block.sh"
            TMPFILE="$STATUS_LINE.orchestra-deploy.tmp"
            sed '/^#!/d; /^# orchestra-block.sh/d; /^# USAGE/d; /^# just before the final/d; /^#$/d; /^# Prerequisites/d; /^#   -/d; /^# deploy.sh will/d; /^# The presence/d' "$BLOCK" > "$TMPFILE.block"
            awk -v bfile="$TMPFILE.block" '
                /^# Output the status line/ { while ((getline line < bfile) > 0) print line; print ""; }
                { print }
            ' "$STATUS_LINE" > "$TMPFILE"
            rm -f "$TMPFILE.block"
            mv -f "$TMPFILE" "$STATUS_LINE"
            chmod +x "$STATUS_LINE"
            ok "patched: status-line.sh (orchestra block appended)"
        fi
    fi
fi

# ── 9. Inject orchestra-guard block into ~/.claude/CLAUDE.md ──────────────────
# The guard fires every turn (CLAUDE.md is loaded into the system prompt prefix
# by the harness on every turn), giving us per-turn reinforcement of the
# orchestra-pipeline rules — matching plan-mode's reminder cadence. Without
# this, /brain reliably skips Planner/Actor dispatches in long Phase 0 sessions
# because /brain.md's instructions get buried by repeated plan-mode reminders.
# Skip-with-warning if the user's global CLAUDE.md is absent.
echo "CLAUDE.md guard:"
GLOBAL_CLAUDE_MD="$HOME/.claude/CLAUDE.md"
GUARD_SOURCE="$REPO/claude-md-block/orchestra-guard.md"
if [ ! -f "$GLOBAL_CLAUDE_MD" ]; then
    warn "~/.claude/CLAUDE.md not found — skipping orchestra-guard injection (Component A reinforcement in /brain.md still active; see plans/adaptive-exploring-bunny.md)"
elif [ ! -f "$GUARD_SOURCE" ]; then
    warn "claude-md-block/orchestra-guard.md not found in repo — skipping injection"
else
    GUARD_PRESENT=false
    grep -q "ORCHESTRA_GUARD_START" "$GLOBAL_CLAUDE_MD" 2>/dev/null && GUARD_PRESENT=true

    if $GUARD_PRESENT; then
        # Extract deployed block (between markers, exclusive of the markers themselves)
        DEPLOYED_GUARD="$(awk '/^<!-- ORCHESTRA_GUARD_START -->/{flag=1;next} /^<!-- ORCHESTRA_GUARD_END -->/{flag=0} flag' "$GLOBAL_CLAUDE_MD")"
        SOURCE_GUARD="$(cat "$GUARD_SOURCE")"
        if [ "$DEPLOYED_GUARD" = "$SOURCE_GUARD" ]; then
            ok "unchanged: ~/.claude/CLAUDE.md (orchestra-guard block matches source)"
        elif $DRY_RUN; then
            info "would re-deploy orchestra-guard block in ~/.claude/CLAUDE.md (source has changed)"
        else
            TMPFILE="$GLOBAL_CLAUDE_MD.orchestra-deploy.tmp"
            # Strip old block (markers and content)
            awk '
                /^<!-- ORCHESTRA_GUARD_START -->/ { in_block=1; next }
                /^<!-- ORCHESTRA_GUARD_END -->/ { in_block=0; next }
                !in_block { print }
            ' "$GLOBAL_CLAUDE_MD" > "$TMPFILE"
            # Append fresh block at end
            {
                printf '\n<!-- ORCHESTRA_GUARD_START -->\n'
                cat "$GUARD_SOURCE"
                printf '<!-- ORCHESTRA_GUARD_END -->\n'
            } >> "$TMPFILE"
            mv -f "$TMPFILE" "$GLOBAL_CLAUDE_MD"
            ok "updated: ~/.claude/CLAUDE.md (orchestra-guard block refreshed)"
        fi
    else
        if $DRY_RUN; then
            info "would append orchestra-guard block to ~/.claude/CLAUDE.md"
        else
            {
                printf '\n<!-- ORCHESTRA_GUARD_START -->\n'
                cat "$GUARD_SOURCE"
                printf '<!-- ORCHESTRA_GUARD_END -->\n'
            } >> "$GLOBAL_CLAUDE_MD"
            ok "patched: ~/.claude/CLAUDE.md (orchestra-guard block appended)"
        fi
    fi
fi

# ── 10. Global gitignore ──────────────────────────────────────────────────────
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
echo "    2. Type /brain <task>          — full pipeline (Planner → Actor → Reviewer)"
echo "       Type /brain-abandon         — cancel the active /brain session"
echo "    3. Type /duo-plan <task>      — open a /duo planning session (multi-turn refinement)"
echo "       Type /duo-act               — commit the plan and execute Actor"
echo "       Type /duo-abandon           — cancel the active /duo session"
echo "    4. See docs/design.md for full reference"
echo ""
