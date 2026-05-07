#!/usr/bin/env python3
"""
native-session-finalize.py — Stop-hook helper to finalize one native session.

Usage: native-session-finalize.py <session_id> <cc_pid> <started_at_iso> <ended_at_iso>

Finalizes a native (non-orchestra) Claude Code session by:
1. Querying SoHoAI for cost attribution (if available)
2. Writing a record to ~/.claude/native-sessions/telemetry.jsonl
3. Printing a one-line summary to stdout (captured by stop hook)
"""

import argparse
import importlib.util
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


def parse_iso8601(timestamp_str: str) -> float:
    """Parse ISO-8601 timestamp to Unix time."""
    try:
        dt = datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
        return dt.timestamp()
    except Exception:
        return 0.0


def to_iso8601(unix_time: float) -> str:
    """Convert Unix time to ISO-8601 string."""
    return datetime.fromtimestamp(unix_time, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def import_telemetry_module():
    """Import query_sohoai_cost from sibling telemetry-summarize.py via importlib."""
    try:
        spec = importlib.util.spec_from_file_location(
            "ts", Path(__file__).parent / "telemetry-summarize.py"
        )
        ts_mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ts_mod)
        return ts_mod
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(
        description="Finalize one native (non-orchestra) Claude Code session."
    )
    parser.add_argument("session_id", help="Session ID (e.g. native-20260507T092335Z-1234)")
    parser.add_argument("cc_pid", type=int, help="Claude Code process PID")
    parser.add_argument("started_at_iso", help="ISO-8601 start timestamp")
    parser.add_argument("ended_at_iso", help="ISO-8601 end timestamp")
    args = parser.parse_args()

    # Convert timestamps
    started_at_unix = parse_iso8601(args.started_at_iso)
    ended_at_unix = parse_iso8601(args.ended_at_iso)
    duration_s = int(ended_at_unix - started_at_unix)

    # Try to query SoHoAI for cost
    cost_usd_estimate = 0.0
    cost_source = "none"

    ts_mod = import_telemetry_module()
    if ts_mod is not None:
        base_url = os.environ.get("ANTHROPIC_BASE_URL", "").rstrip("/")
        if base_url:
            try:
                cost = ts_mod.query_sohoai_cost(
                    args.session_id, started_at_unix, ended_at_unix, base_url, 5
                )
                if cost is not None and cost > 0:
                    cost_usd_estimate = cost
                    cost_source = "sohoai_api"
            except Exception:
                pass

    # Build telemetry record
    record = {
        "session_id": args.session_id,
        "cc_pid": args.cc_pid,
        "command": "native",
        "started_at": args.started_at_iso,
        "ended_at": args.ended_at_iso,
        "duration_s": duration_s,
        "cost_usd_estimate": cost_usd_estimate,
        "cost_source": cost_source,
    }

    # Write to telemetry.jsonl (atomic append)
    native_sessions_dir = Path.home() / ".claude" / "native-sessions"
    native_sessions_dir.mkdir(parents=True, exist_ok=True)
    telemetry_jsonl = native_sessions_dir / "telemetry.jsonl"

    try:
        with open(telemetry_jsonl, "a") as f:
            f.write(json.dumps(record) + "\n")
    except Exception as e:
        print(f"native-session-finalize: failed to write telemetry.jsonl: {e}", file=sys.stderr)
        sys.exit(1)

    # Print summary for stop hook to log
    print(
        f"native-session: cost=${cost_usd_estimate:.4f} duration={duration_s}s "
        f"source={cost_source} session={args.session_id}"
    )


if __name__ == "__main__":
    main()
