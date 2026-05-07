#!/usr/bin/env python3
"""
session-report.py — Unified cost report for native and orchestra sessions.

Usage: session-report.py [--last N] [--since DATE] [--month YYYY-MM] [--source native|orchestra|brain|duo|all]

Reads telemetry from:
- ~/.claude/native-sessions/telemetry.jsonl — native session records
- ~/.claude/orchestra/telemetry.jsonl — orchestra session records

Produces a unified tabular report with filtering and aggregation.

--source options:
  native    — native sessions only
  orchestra — any orchestra command (brain, duo, etc.; excludes native)
  brain     — /brain command sessions only
  duo       — /duo command sessions only
  all       — all sources (default)
"""

import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


def parse_iso8601(timestamp_str: str) -> datetime:
    """Parse ISO-8601 timestamp to datetime."""
    try:
        return datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
    except Exception:
        return datetime.now(timezone.utc)


def load_native_telemetry() -> List[Dict[str, Any]]:
    """Load telemetry from ~/.claude/native-sessions/telemetry.jsonl."""
    path = Path.home() / ".claude" / "native-sessions" / "telemetry.jsonl"
    records = []
    if path.exists():
        try:
            with open(path) as f:
                for line in f:
                    if line.strip():
                        record = json.loads(line)
                        record["source"] = "native"
                        records.append(record)
        except Exception:
            pass
    return records


def load_orchestra_telemetry() -> List[Dict[str, Any]]:
    """Load telemetry from ~/.claude/orchestra/telemetry.jsonl."""
    path = Path.home() / ".claude" / "orchestra" / "telemetry.jsonl"
    records = []
    if path.exists():
        try:
            with open(path) as f:
                for line in f:
                    if line.strip():
                        record = json.loads(line)
                        # Extract command as source (brain / duo / other)
                        source = record.get("command", "unknown")
                        record["source"] = source
                        records.append(record)
        except Exception:
            pass
    return records


def extract_project_name(session_dir: str) -> str:
    """Extract project name from session_dir path.

    Pattern: <project_dir>/.claude/orchestra/sessions/<session_id>
    Returns: basename of <project_dir>
    """
    try:
        path = Path(session_dir)
        # Remove /.claude/orchestra/sessions/<session_id>
        parts = path.parts
        # Find .claude index
        if ".claude" in parts:
            idx = parts.index(".claude")
            if idx > 0:
                return parts[idx - 1]
    except Exception:
        pass
    return "-"


def get_session_telemetry_json(session_dir: str) -> Optional[Dict[str, Any]]:
    """Read telemetry.json from session_dir if it exists."""
    try:
        path = Path(session_dir) / "telemetry.json"
        if path.exists():
            with open(path) as f:
                return json.load(f)
    except Exception:
        pass
    return None


def format_cost(cost: float) -> str:
    """Format cost as $X.XXXX or '-' if zero/absent."""
    if cost is None or cost == 0:
        return "-"
    return f"${cost:.4f}"


def format_duration(duration_s: int) -> str:
    """Format duration in seconds as readable string."""
    if duration_s < 0:
        return "-"
    return f"{duration_s}s"


def apply_filters(records: List[Dict[str, Any]], args: argparse.Namespace) -> List[Dict[str, Any]]:
    """Apply --last, --since, --month, --source filters."""
    filtered = records

    # --source filter
    if args.source == "all":
        pass  # include everything
    elif args.source == "native":
        filtered = [r for r in filtered if r.get("source") == "native"]
    elif args.source == "orchestra":
        # orchestra is an alias for any non-native source (brain, duo, etc.)
        filtered = [r for r in filtered if r.get("source") != "native"]
    else:
        # specific command: "brain", "duo", etc.
        filtered = [r for r in filtered if r.get("source") == args.source]

    # Sort by started_at descending (most recent first)
    filtered.sort(
        key=lambda r: parse_iso8601(r.get("started_at", "")).timestamp(),
        reverse=True
    )

    # --since filter (date string YYYY-MM-DD)
    if args.since:
        try:
            since_dt = datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
            filtered = [
                r for r in filtered
                if parse_iso8601(r.get("started_at", "")) >= since_dt
            ]
        except Exception:
            pass

    # --month filter (YYYY-MM)
    if args.month:
        try:
            month_dt = datetime.strptime(args.month, "%Y-%m").replace(tzinfo=timezone.utc)
            month_next = (
                month_dt.replace(day=28) + __import__("datetime").timedelta(days=4)
            ).replace(day=1)
            filtered = [
                r for r in filtered
                if month_dt <= parse_iso8601(r.get("started_at", "")) < month_next
            ]
        except Exception:
            pass

    # --last filter
    if args.last:
        filtered = filtered[: args.last]

    return filtered


def load_active_native_sessions() -> List[Dict[str, Any]]:
    """Load active native sessions from ~/.claude/active-sessions/native-*.lck files."""
    active = []
    active_sessions_dir = Path.home() / ".claude" / "active-sessions"
    if active_sessions_dir.exists():
        for lck_file in active_sessions_dir.glob("native-*.lck"):
            try:
                with open(lck_file) as f:
                    lines = f.readlines()
                    record = {}
                    for line in lines:
                        if "=" in line:
                            k, v = line.split("=", 1)
                            record[k.strip()] = v.strip()
                    if record.get("session_id"):
                        active.append({
                            "session_id": record.get("session_id"),
                            "cc_pid": int(record.get("cc_pid", 0)) if record.get("cc_pid") else 0,
                            "started_at": record.get("started_at", ""),
                            "source": "native",
                            "status": "(active)",
                        })
            except Exception:
                pass
    return active


def main():
    parser = argparse.ArgumentParser(
        description="Unified cost report: native + orchestra sessions."
    )
    parser.add_argument("--last", type=int, help="Show last N sessions")
    parser.add_argument("--since", help="Show sessions since DATE (YYYY-MM-DD)")
    parser.add_argument("--month", help="Show sessions in YYYY-MM")
    parser.add_argument(
        "--source", choices=["native", "orchestra", "brain", "duo", "all"], default="all",
        help="Filter by source: native, orchestra (any non-native), brain, duo, or all"
    )
    args = parser.parse_args()

    # Load all records
    native_records = load_native_telemetry()
    orchestra_records = load_orchestra_telemetry()
    all_records = native_records + orchestra_records

    # Apply filters
    filtered_records = apply_filters(all_records, args)

    # Load active sessions
    active_sessions = load_active_native_sessions()

    # Prepare display records
    display_records = []
    for rec in filtered_records:
        tok = rec.get("total_tokens")
        tok_str = f"{tok:,}" if tok else "-"
        raw_model = rec.get("model") or "-"
        if raw_model != "-":
            raw_model = re.sub(r'\[.*?\]$', '', raw_model)
            raw_model = re.sub(r'-\d{8}$', '', raw_model)
        display_records.append({
            "date": parse_iso8601(rec.get("started_at", "")).strftime("%Y-%m-%d--%H-%M"),
            "source": rec.get("source", "-"),
            "project": extract_project_name(rec.get("session_dir", "")) if rec.get("session_dir") else "-",
            "model": raw_model,
            "tokens": tok_str,
            "cost": format_cost(rec.get("cost_usd_estimate", 0)),
            "duration": format_duration(rec.get("duration_s", 0)),
            "outcome": rec.get("outcome", "-"),
        })

    # Add active sessions at top
    for active in active_sessions:
        display_records.insert(0, {
            "date": parse_iso8601(active.get("started_at", "")).strftime("%Y-%m-%d--%H-%M"),
            "source": active.get("source", "-"),
            "project": "-",
            "model": "-",
            "tokens": "-",
            "cost": "-",
            "duration": "-",
            "outcome": active.get("status", "-"),
        })

    # Print header
    print()
    print(f"{'Date':<17} {'Source':<8} {'Project':<17} {'Model':<23} {'Tokens':>10}  {'Cost':>9}  {'Dur':>6}  Outcome")
    print("-" * 106)

    # Print rows with alignment
    total_cost = 0.0
    session_count = 0
    for rec in display_records:
        date_str = rec["date"].ljust(17)
        source_str = rec["source"].ljust(8)
        project_str = rec["project"][:17].ljust(17)
        model_str = rec["model"][:23].ljust(23)
        tokens_str = rec["tokens"].rjust(10)
        cost_str = rec["cost"].rjust(9)
        dur_str = rec["duration"].rjust(6)
        outcome_str = rec["outcome"]
        print(f"{date_str} {source_str} {project_str} {model_str} {tokens_str}  {cost_str}  {dur_str}  {outcome_str}")

        # Accumulate cost (skip active markers)
        if rec["outcome"] != "(active)":
            try:
                if rec["cost"] != "-" and rec["cost"].startswith("$"):
                    total_cost += float(rec["cost"][1:])
                session_count += 1
            except Exception:
                pass

    # Print aggregates
    print()
    print("--- Aggregates ---")
    print(f"Sessions: {session_count}  Total cost: ${total_cost:.4f}")
    print()


if __name__ == "__main__":
    main()
