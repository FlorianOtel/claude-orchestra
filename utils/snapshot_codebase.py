"""
Codebase snapshot generator for NotebookLM.

Aggregates the project's key source files into a single Markdown document
suitable for upload as a NotebookLM source.

Usage:
    python utils/snapshot_codebase.py
    python utils/snapshot_codebase.py --output /tmp/snapshot.md

Note on encoding: NotebookLM's Markdown parser chokes on Unicode box-drawing
characters (U+2500-U+257F) and non-BMP emoji (U+10000+) even inside code
fences -- they cause a perpetual stuck-indexing spinner with no visible error.
_sanitize_for_markdown() strips these before embedding file content.
File size is NOT a constraint -- a 122 KB combined snapshot indexes fine.
"""

from __future__ import annotations

import argparse
import logging
import re
import subprocess
from datetime import datetime
from pathlib import Path

log = logging.getLogger(__name__)

PROJECT_ROOT = Path("/mnt/nfs/Florian/Gin-AI/projects/claude-orchestra")
DEFAULT_OUTPUT = PROJECT_ROOT / "utils" / "codebase_snapshot.md"
INCLUDE_EXTENSIONS: set[str] = {".py", ".yaml", ".yml", ".sh", ".md", ".json"}

_SNAPSHOT_FILES_FALLBACK: list[str] = [
    # Root docs
    "CLAUDE.md",
    "README.md",
    # Agent definitions
    "agents/actor.md",
    "agents/planner.md",
    "agents/reviewer.md",
    # Skill/command definitions
    "commands/brain.md",
    "commands/brain-abandon.md",
    "commands/duo-plan.md",
    "commands/duo-act.md",
    "commands/duo-abandon.md",
    # Claude.md injection block
    "claude-md-block/orchestra-guard.md",
    # Config
    "config/config.yaml",
    "config/context-windows.yaml",
    "config/pricing.yaml",
    "config/settings-hooks.json",
    # Scripts
    "scripts/orchestra-hook.sh",
    "scripts/bash-session-init.sh",
    "scripts/otel-headers-helper.sh",
    "scripts/ctx-segment.sh",
    "scripts/sohoai-live-cost.sh",
    "scripts/native-session-finalize.py",
    "scripts/native-session-report.py",
    "scripts/native-session-report.sh",
    "scripts/native-subagent-cost.sh",
    "scripts/session-report.py",
    "scripts/session-report.sh",
    "scripts/telemetry-report.sh",
    "scripts/telemetry-summarize.py",
    "scripts/telemetry-summarize.sh",
    "scripts/smoke-test.sh",
    # Status-line
    "status-line/orchestra-block.sh",
    # This utility
    "utils/snapshot_codebase.py",
]  # used only when git is unavailable


def _lang(path: Path) -> str:
    return {
        ".py": "python",
        ".yaml": "yaml",
        ".yml": "yaml",
        ".sh": "bash",
        ".json": "json",
        ".md": "",
    }.get(path.suffix.lower(), "")


def discover_files(extensions: set[str] | None = None) -> list[Path]:
    """
    Discover project files via git, filtered by extension.

    Falls back to _SNAPSHOT_FILES_FALLBACK if git is unavailable.

    Args:
        extensions: Set of file extensions to include (e.g., {".py", ".sh"}).
                   If None, uses INCLUDE_EXTENSIONS.

    Returns:
        Sorted list of absolute paths.
    """
    if extensions is None:
        extensions = INCLUDE_EXTENSIONS

    try:
        result = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            log.warning("git ls-files failed (returncode %d); falling back to hardcoded list", result.returncode)
            return [PROJECT_ROOT / f for f in _SNAPSHOT_FILES_FALLBACK]

        files: list[Path] = []
        for line in result.stdout.strip().split("\n"):
            if not line:
                continue
            path = PROJECT_ROOT / line
            if path.suffix.lower() in extensions:
                files.append(path)

        return sorted(files)

    except FileNotFoundError:
        log.warning("git not found; falling back to hardcoded list")
        return [PROJECT_ROOT / f for f in _SNAPSHOT_FILES_FALLBACK]


def _sanitize_for_markdown(content: str) -> str:
    """
    Replace or strip characters that cause NotebookLM's indexing to hang.

    Empirically confirmed problematic ranges (stuck-spinner, no visible error):
      U+2500-U+257F  Box Drawing -- corner/bar chars  (replaced with dash)
      U+2580-U+259F  Block Elements -- block-fill     (replaced with dash)
      U+2190-U+21FF  Arrows                           (stripped)
      U+2600-U+26FF  Misc Symbols                     (stripped)
      U+2700-U+27BF  Dingbats                         (stripped)
      U+10000+       Non-BMP emoji                    (stripped)

    Box-drawing and block-elements are replaced with dash to preserve table
    and border structure as ASCII.  All other symbol ranges are removed outright
    because they have no prose equivalent.

    NOTE: add new ranges here whenever NotebookLM is found to choke on a new
    character class -- do not rely on "it looked fine last time" since the
    backend parser changes without notice.
    """
    content = re.sub(r"[\u2500-\u259F]", "-", content)  # box-drawing + block elements -> dash
    content = re.sub(r"[\u2190-\u21FF]", "", content)    # arrows -> removed
    content = re.sub(r"[\u2600-\u27BF]", "", content)    # misc symbols + dingbats -> removed
    content = re.sub(r"[^\u0000-\uFFFF]", "", content)   # non-BMP emoji -> removed
    return content


def generate_snapshot(
    output: Path = DEFAULT_OUTPUT,
    files: list[str] | None = None,
    extensions: set[str] | None = None,
) -> Path:
    """Write the snapshot Markdown to `output` and return the path."""
    targets = discover_files(extensions=extensions) if files is None else [PROJECT_ROOT / f for f in files]
    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")

    sections: list[str] = [
        f"# Claude Orchestra -- Codebase Snapshot\n\nGenerated: {now}\n",
        "---\n",
    ]

    included = 0
    for path in targets:
        if not path.exists():
            log.warning("Skipping missing file: %s", path)
            continue
        rel = path.relative_to(PROJECT_ROOT)
        lang = _lang(path)
        content = _sanitize_for_markdown(
            path.read_text(encoding="utf-8", errors="replace")
        )

        # Use a fence longer than the longest backtick run inside the file so
        # the outer fence always closes correctly (standard Markdown rule).
        max_inner = max(
            (len(m.group(0)) for m in re.finditer(r"`+", content)),
            default=0,
        )
        fence = "`" * max(3, max_inner + 1)

        sections.append(f"## `{rel}`\n\n{fence}{lang}\n{content}\n{fence}\n")
        included += 1
        log.info("  + %s", rel)

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(sections), encoding="utf-8")

    size_kb = output.stat().st_size / 1024
    log.info("Snapshot written: %s  (%d files, %.1f KB)", output, included, size_kb)
    return output


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description="Generate codebase snapshot for NotebookLM")
    parser.add_argument(
        "--output", default=str(DEFAULT_OUTPUT),
        help=f"Output file path (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--extensions", nargs="+", default=None,
        help="File extensions to include (e.g., .py .yaml .sh .md); default: .py .yaml .yml .sh .md .json",
    )
    args = parser.parse_args()
    extensions = set(args.extensions) if args.extensions else None
    generate_snapshot(output=Path(args.output), extensions=extensions)


if __name__ == "__main__":
    main()
