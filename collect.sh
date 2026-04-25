#!/usr/bin/env bash
# collect.sh — sync changes FROM ~/.claude/ back into this repo
#
# Use this when you've been iterating directly in ~/.claude/ and want to
# checkpoint those changes back to the repo for versioning / sharing.
#
# Usage:
#   ./collect.sh           — copy live files into repo, print diff summary
#   ./collect.sh --dry-run — show what would change without writing

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE="${HOME}/.claude"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in --dry-run) DRY_RUN=true ;; esac
done

info() { printf "\033[36m  •\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m  ✓\033[0m %s\n" "$*"; }

collect_file() {
    local src="$1" dst="$2"
    if $DRY_RUN; then
        if [ -f "$src" ]; then
            diff -q "$src" "$dst" >/dev/null 2>&1 && info "unchanged: $(basename "$dst")" || info "would update: $(basename "$dst")"
        else
            info "source missing, skip: $src"
        fi
        return
    fi
    if [ ! -f "$src" ]; then
        info "source missing, skipped: $src"
        return
    fi
    if [ -f "$dst" ] && diff -q "$src" "$dst" >/dev/null 2>&1; then
        ok "unchanged: $(basename "$dst")"
    else
        cp -f "$src" "$dst"
        ok "collected: $(basename "$dst")"
    fi
}

echo ""
echo "Claude Orchestra — collect (live → repo)"
echo "  source: $CLAUDE"
echo "  repo:   $REPO"
$DRY_RUN && echo "  mode:   DRY RUN"
echo ""

echo "Agents:"
collect_file "$CLAUDE/agents/planner.md"        "$REPO/.claude/agents/planner.md"
collect_file "$CLAUDE/agents/actor.md"           "$REPO/.claude/agents/actor.md"
collect_file "$CLAUDE/agents/reviewer.md"        "$REPO/.claude/agents/reviewer.md"

echo "Commands:"
collect_file "$CLAUDE/commands/brain.md"         "$REPO/.claude/commands/brain.md"
collect_file "$CLAUDE/commands/duo.md"           "$REPO/.claude/commands/duo.md"
collect_file "$CLAUDE/commands/orchestra-mode.md" "$REPO/.claude/commands/orchestra-mode.md"

echo "Scripts:"
collect_file "$CLAUDE/scripts/orchestra-hook.sh" "$REPO/scripts/orchestra-hook.sh"

echo "Config:"
collect_file "$CLAUDE/orchestra/config.yaml"    "$REPO/config/config.yaml"

echo ""
$DRY_RUN && echo "Dry run complete — no files written." || echo "Collect complete."
echo ""
if ! $DRY_RUN; then
    echo "  Next steps:"
    echo "    git diff           — review changes"
    echo "    git add -p         — stage selectively"
    echo "    git commit -m '...' — commit"
    echo "    git push           — publish"
fi
echo ""
