#!/usr/bin/env python3
"""
native-session-report.py — cost report for all Claude Code sessions (not just orchestra).

Walks ~/.claude/usage-data/session-meta/*.json for session discovery, scans corresponding
JSONL transcripts to compute tokens and cost. Falls back to session-meta token counts if
JSONL is missing.

Usage:
  native-session-report.py [--last N] [--since YYYY-MM-DD] [--month YYYY-MM]
                           [--project PATH] [--tier] [--json] [--min-cost X]
                           [--exclude-orchestra]

Where:
  --last N              Show the last N sessions (default 20)
  --since YYYY-MM-DD    Show sessions from this date onwards
  --month YYYY-MM       Show sessions in this month (YYYY-MM-01 to end of month)
  --project PATH        Filter by project path prefix
  --tier                Show per-model breakdown
  --json                Output as JSON instead of table
  --min-cost X          Filter sessions with cost >= X USD
  --exclude-orchestra   Exclude sessions tracked in orchestra telemetry
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

try:
    import yaml
except ImportError:
    yaml = None


def _normalize_model_id(model: str) -> str:
    """Strip trailing -YYYYMMDD snapshot suffix and [1m] context suffix from model IDs.

    Examples:
      claude-sonnet-4-6[1m] -> claude-sonnet-4-6
      claude-haiku-4-5-20251001 -> claude-haiku-4-5
    """
    if not model:
        return model
    # Strip [context] suffix
    model = re.sub(r'\[.*?\]$', '', model)
    # Strip -YYYYMMDD suffix
    return re.sub(r'-\d{8}$', '', model)


def load_pricing_yaml() -> Dict[str, Any]:
    """Load pricing from config/pricing.yaml or ~/.claude/orchestra/pricing.yaml"""
    if yaml is None:
        return {}

    candidates = [
        Path(__file__).parent.parent / "config" / "pricing.yaml",
        Path.home() / ".claude" / "orchestra" / "pricing.yaml",
    ]

    for candidate in candidates:
        if candidate.exists():
            try:
                with open(candidate) as f:
                    data = yaml.safe_load(f)
                    if data and "models" in data:
                        return data
            except Exception:
                continue

    return {}


def get_transcript_path(session_id: str) -> Optional[Path]:
    """Locate transcript JSONL by scanning all ~/.claude/projects/*/ dirs."""
    projects_root = Path.home() / ".claude" / "projects"
    if session_id:
        try:
            for proj_dir in sorted(projects_root.iterdir()):
                if not proj_dir.is_dir():
                    continue
                path = proj_dir / f"{session_id}.jsonl"
                if path.exists():
                    return path
        except Exception:
            pass
    return None


def parse_jsonl_tokens(jsonl_path: Optional[Path]) -> Tuple[Optional[str], Dict[str, int]]:
    """Scan JSONL file and sum all assistant message usage (NO time window).

    Returns (model, tokens_dict) where tokens_dict has keys:
      input, output, cache_creation, cache_read
    """
    tokens = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}
    model: Optional[str] = None

    if not jsonl_path or not jsonl_path.exists():
        return model, tokens

    try:
        with open(jsonl_path) as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if record.get("type") != "assistant" or "message" not in record:
                    continue

                msg = record["message"]
                usage = msg.get("usage")
                if not usage:
                    continue

                msg_model = msg.get("model")
                if model is None and msg_model and msg_model != "<synthetic>":
                    model = msg_model

                tokens["input"] += usage.get("input_tokens", 0) or 0
                tokens["output"] += usage.get("output_tokens", 0) or 0
                tokens["cache_creation"] += usage.get("cache_creation_input_tokens", 0) or 0
                tokens["cache_read"] += usage.get("cache_read_input_tokens", 0) or 0
    except Exception:
        pass

    return model, tokens


def compute_session_cost(
    tokens: Dict[str, int],
    model: Optional[str],
    pricing_data: Dict[str, Any]
) -> float:
    """Compute USD cost from tokens dict and pricing table."""
    if not pricing_data or "models" not in pricing_data or not model:
        return 0.0

    model_key = _normalize_model_id(model)
    rates = pricing_data["models"].get(model_key, {})
    if not rates:
        return 0.0

    total_cost = 0.0
    for key, rate_key in [
        ("input", "input"),
        ("output", "output"),
        ("cache_creation", "cache_creation"),
        ("cache_read", "cache_read"),
    ]:
        token_count = tokens.get(key, 0)
        rate = rates.get(rate_key, 0.0)
        total_cost += (token_count * rate) / 1_000_000.0

    return round(total_cost, 4)


def load_orchestra_cc_uuids() -> Set[str]:
    """Load set of CC UUIDs tracked in orchestra telemetry.

    Reads ~/.claude/orchestra/telemetry.jsonl, for each line reads
    ${session_dir}/telemetry.json to collect transcript_session_id and
    all UUIDs in parent.transcripts.
    """
    cc_uuids: Set[str] = set()
    telemetry_jsonl = Path.home() / ".claude" / "orchestra" / "telemetry.jsonl"

    if not telemetry_jsonl.exists():
        return cc_uuids

    try:
        with open(telemetry_jsonl) as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # Add the transcript_session_id
                if record.get("transcript_session_id"):
                    cc_uuids.add(record["transcript_session_id"])

                # Read the telemetry.json if session_dir is available
                session_dir = record.get("session_dir")
                if session_dir:
                    telemetry_json = Path(session_dir) / "telemetry.json"
                    if telemetry_json.exists():
                        try:
                            with open(telemetry_json) as tf:
                                telemetry = json.load(tf)
                                parent = telemetry.get("parent", {})
                                # Add all UUIDs from parent.transcripts
                                for uuid in parent.get("transcripts", []):
                                    if uuid:
                                        cc_uuids.add(uuid)
                        except Exception:
                            pass
    except Exception:
        pass

    return cc_uuids


def is_session_active() -> bool:
    """Check if any Claude Code session is currently running.

    Returns True if any .lck file exists in ~/.claude/active-sessions/ with
    a valid live PID.
    """
    active_sessions_dir = Path.home() / ".claude" / "active-sessions"
    if not active_sessions_dir.exists():
        return False

    try:
        for lck_file in active_sessions_dir.glob("*.lck"):
            try:
                content = lck_file.read_text().strip()
                # Support both old format (raw PID) and new format (cc_pid=PID\n...)
                if content.startswith("cc_pid="):
                    pid = int(content.split("\n")[0].split("=", 1)[1].strip())
                else:
                    pid = int(content)
                # Check if process exists
                if os.path.exists(f"/proc/{pid}"):
                    return True
            except (ValueError, Exception):
                continue
    except Exception:
        pass

    return False


def apply_filters(
    sessions: List[Dict[str, Any]],
    since: Optional[str],
    month: Optional[str],
    project: Optional[str],
    min_cost: float,
) -> List[Dict[str, Any]]:
    """Filter sessions by criteria."""
    filtered = []

    for session in sessions:
        # Date filter: --since
        if since:
            try:
                since_date = datetime.strptime(since, "%Y-%m-%d").date()
                session_date = datetime.fromisoformat(session["start_time"][:10]).date()
                if session_date < since_date:
                    continue
            except Exception:
                pass

        # Date filter: --month
        if month:
            try:
                session_date = datetime.fromisoformat(session["start_time"][:10]).date()
                month_parts = month.split("-")
                if len(month_parts) == 2:
                    year, month_num = int(month_parts[0]), int(month_parts[1])
                    if session_date.year != year or session_date.month != month_num:
                        continue
            except Exception:
                pass

        # Project filter
        if project:
            session_project = session.get("project_path", "")
            if not session_project.startswith(project):
                continue

        # Cost filter
        if session.get("cost_usd", 0) < min_cost:
            continue

        filtered.append(session)

    return filtered


def get_project_friendly_name(mangled_project_path: str) -> str:
    """Extract friendly project name from mangled path or lookup sidecar.

    Attempts:
    1. Check ~/.claude/projects/<mangled_path>/*.project-name sidecar
    2. Fallback to last path component
    """
    projects_root = Path.home() / ".claude" / "projects"
    project_dir = projects_root / mangled_project_path

    if project_dir.exists():
        # Look for <uuid>.project-name sidecar
        try:
            for sidecar in project_dir.glob("*.project-name"):
                try:
                    return sidecar.read_text().strip()
                except Exception:
                    pass
        except Exception:
            pass

    # Fallback: derive from original project_path if available
    # or use last component of mangled path
    if mangled_project_path.startswith("-mnt-nfs-"):
        # Convert back: -mnt-nfs-Florian-Gin-AI-projects-X -> X
        parts = mangled_project_path.split("-")
        if len(parts) > 4:
            return parts[-1]
    return mangled_project_path


def mangle_project_path(project_path: str) -> str:
    """Mangle absolute project path to ~/.claude/projects dirname."""
    # Replace every / with -
    return project_path.replace("/", "-")


def load_sessions() -> List[Dict[str, Any]]:
    """Load all sessions from ~/.claude/usage-data/session-meta/*.json"""
    sessions: List[Dict[str, Any]] = []
    session_meta_dir = Path.home() / ".claude" / "usage-data" / "session-meta"

    if not session_meta_dir.exists():
        return sessions

    pricing_data = load_pricing_yaml()

    try:
        for meta_file in sorted(session_meta_dir.glob("*.json")):
            try:
                with open(meta_file) as f:
                    meta = json.load(f)
            except Exception:
                continue

            session_id = meta.get("session_id", "")
            project_path = meta.get("project_path", "")
            start_time = meta.get("start_time", "")
            duration_minutes = meta.get("duration_minutes", 0)

            # Attempt to parse JSONL
            jsonl_path = get_transcript_path(session_id)
            model, tokens = parse_jsonl_tokens(jsonl_path)
            jsonl_status = "from_jsonl" if jsonl_path else "no_jsonl"

            # Fallback to session-meta token counts if JSONL missing
            if not jsonl_path or (tokens["input"] == 0 and tokens["output"] == 0):
                tokens = {
                    "input": meta.get("input_tokens", 0) or 0,
                    "output": meta.get("output_tokens", 0) or 0,
                    "cache_creation": 0,
                    "cache_read": 0,
                }
                jsonl_status = "no_jsonl"

            # Estimate model if not found in JSONL
            if not model:
                model = "unknown"

            # Compute cost
            cost_usd = compute_session_cost(tokens, model, pricing_data)

            # Derive friendly project name
            mangled_path = mangle_project_path(project_path) if project_path else ""
            friendly_name = get_project_friendly_name(mangled_path) if mangled_path else "unknown"

            session = {
                "session_id": session_id,
                "project_path": project_path,
                "project_name": friendly_name,
                "start_time": start_time,
                "duration_minutes": duration_minutes,
                "model": model,
                "tokens": tokens,
                "cost_usd": cost_usd,
                "jsonl_status": jsonl_status,
            }
            sessions.append(session)
    except Exception:
        pass

    # Sort by start_time descending (most recent first)
    sessions.sort(key=lambda s: s.get("start_time", ""), reverse=True)
    return sessions


def print_table(
    sessions: List[Dict[str, Any]],
    orchestra_uuids: Set[str],
    exclude_orchestra: bool,
) -> None:
    """Print tabular output with orchestra-overlap indicators."""
    if not sessions:
        print("(no sessions)")
        return

    # Print header
    print(f"{'Date':<17} {'Project':<25} {'Model':<25} {'Tokens':>12} {'Cache%':>7} {'Cost':>9}")
    print("-" * 100)

    total_cost = 0.0
    total_tokens = 0
    session_count = 0

    for session in sessions:
        session_id = session.get("session_id", "")
        try:
            dt = datetime.fromisoformat(session.get("start_time", "").replace("Z", "+00:00"))
            date = dt.strftime("%Y-%m-%d--%H-%M")
        except Exception:
            date = session.get("start_time", "")[:10]
        project = session.get("project_name", "")[:25]
        model = _normalize_model_id(session.get("model", "unknown"))[:25]
        tokens = session.get("tokens", {})
        total_toks = sum(tokens.values())
        cache_toks = tokens.get("cache_creation", 0) + tokens.get("cache_read", 0)
        cache_pct = (cache_toks / total_toks * 100) if total_toks > 0 else 0
        cost = session.get("cost_usd", 0)

        # Check if this session is in orchestra telemetry
        is_orchestra = session_id in orchestra_uuids
        marker = " ↑" if is_orchestra else ""

        print(
            f"{date:<17} {project:<25} {model:<25} {total_toks:>12,} "
            f"{cache_pct:>6.1f}% ${cost:>8.4f}{marker}"
        )

        total_cost += cost
        total_tokens += total_toks
        session_count += 1

    print("-" * 95)
    mean_cost = total_cost / session_count if session_count > 0 else 0
    print(f"\nSessions: {session_count}   Total cost: ${total_cost:.2f}   "
          f"Total tokens: {total_tokens:,}   Mean cost: ${mean_cost:.4f}")


def print_by_project(sessions: List[Dict[str, Any]]) -> None:
    """Print breakdown by project."""
    by_project: Dict[str, Tuple[float, int]] = {}

    for session in sessions:
        project = session.get("project_name", "unknown")
        cost = session.get("cost_usd", 0)
        if project not in by_project:
            by_project[project] = (0.0, 0)
        curr_cost, count = by_project[project]
        by_project[project] = (curr_cost + cost, count + 1)

    if by_project:
        print("\nBy project:")
        for project in sorted(by_project.keys()):
            cost, count = by_project[project]
            print(f"  {project:<30} ${cost:>8.2f}  ({count} session{'s' if count != 1 else ''})")


def print_tier_breakdown(sessions: List[Dict[str, Any]]) -> None:
    """Print per-model cost breakdown."""
    by_model: Dict[str, Tuple[int, float]] = {}

    for session in sessions:
        model = _normalize_model_id(session.get("model", "unknown"))
        tokens = sum(session.get("tokens", {}).values())
        cost = session.get("cost_usd", 0)

        if model not in by_model:
            by_model[model] = (0, 0.0)
        curr_toks, curr_cost = by_model[model]
        by_model[model] = (curr_toks + tokens, curr_cost + cost)

    if by_model:
        print(f"\nBy model:")
        print(f"  {'Model':<25} {'Tokens':>12} {'Cost':>9} {'% of total':>12}")
        print(f"  {'-' * 60}")

        total_toks = sum(t for t, _ in by_model.values())
        total_cost = sum(c for _, c in by_model.values())

        for model in sorted(by_model.keys()):
            toks, cost = by_model[model]
            pct = (cost / total_cost * 100) if total_cost > 0 else 0
            print(f"  {model:<25} {toks:>12,} ${cost:>8.4f} {pct:>11.1f}%")

        print(f"  {'-' * 60}")
        print(f"  {'TOTAL':<25} {total_toks:>12,} ${total_cost:>8.4f}")


def print_json(sessions: List[Dict[str, Any]]) -> None:
    """Print sessions as JSON."""
    output = {
        "sessions": sessions,
        "summary": {
            "count": len(sessions),
            "total_cost": sum(s.get("cost_usd", 0) for s in sessions),
            "total_tokens": sum(sum(s.get("tokens", {}).values()) for s in sessions),
        },
    }
    print(json.dumps(output, indent=2))


def main():
    parser = argparse.ArgumentParser(
        description="Cost report for all Claude Code sessions (not just orchestra)"
    )
    parser.add_argument("--last", type=int, default=20, help="Show last N sessions (default 20)")
    parser.add_argument("--since", help="Show sessions from YYYY-MM-DD onwards")
    parser.add_argument("--month", help="Show sessions in YYYY-MM")
    parser.add_argument("--project", help="Filter by project path prefix")
    parser.add_argument("--tier", action="store_true", help="Show per-model breakdown")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--min-cost", type=float, default=0.0, help="Filter sessions with cost >= X USD")
    parser.add_argument("--exclude-orchestra", action="store_true", help="Exclude orchestra sessions")

    args = parser.parse_args()

    # Load all sessions
    all_sessions = load_sessions()

    if not all_sessions:
        print("(no sessions found in ~/.claude/usage-data/session-meta/)")
        return

    # Apply filters
    filtered = apply_filters(
        all_sessions,
        since=args.since,
        month=args.month,
        project=args.project,
        min_cost=args.min_cost,
    )

    # Limit to --last N
    filtered = filtered[: args.last]

    # Load orchestra UUIDs if needed
    orchestra_uuids = set()
    if not args.exclude_orchestra:
        orchestra_uuids = load_orchestra_cc_uuids()

    if not filtered:
        print("(no sessions match filters)")
        return

    # Output
    if args.json:
        print_json(filtered)
    else:
        print_table(filtered, orchestra_uuids, args.exclude_orchestra)
        print_by_project(filtered)
        if args.tier:
            print_tier_breakdown(filtered)


if __name__ == "__main__":
    main()
