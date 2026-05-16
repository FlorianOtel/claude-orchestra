#!/usr/bin/env python3
"""
native-session-finalize.py — Stop-hook helper to finalize one native session.

Usage: native-session-finalize.py <session_id> <cc_pid> <started_at_iso> <ended_at_iso>
                                   [--session-uuid UUID]

Finalizes a native (non-orchestra) Claude Code session by:
1. Querying SoHoAI for cost attribution (if available)
2. T2 fallback: parsing the JSONL transcript by UUID (if --session-uuid provided)
3. Writing a record to ~/.claude/native-sessions/telemetry.jsonl
4. Printing a one-line summary to stdout (captured by stop hook)
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
    """Import telemetry-summarize.py via importlib."""
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
    parser.add_argument(
        "--session-uuid",
        default="",
        help="CC session UUID (CLAUDE_CODE_SESSION_ID) for JSONL transcript lookup",
    )
    args = parser.parse_args()

    # Convert timestamps
    started_at_unix = parse_iso8601(args.started_at_iso)
    ended_at_unix = parse_iso8601(args.ended_at_iso)
    duration_s = int(ended_at_unix - started_at_unix)

    # Try to query SoHoAI for cost
    cost_usd_estimate = 0.0
    cost_source = "none"
    model: Optional[str] = None
    total_tokens: int = 0

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

    # T2 fallback: parse JSONL transcript via session UUID + pricing.yaml
    if cost_usd_estimate == 0 and ts_mod is not None and args.session_uuid:
        try:
            jsonl_path = ts_mod.get_transcript_path(args.session_uuid)
            if jsonl_path:
                # ended_at_unix is "now" (hook fire time); use it as upper bound —
                # dead session content is all before this point.
                # started_at may be the Stop-hook fire time (first turn), not actual
                # session start. Use a 1-hour lookback to capture early messages.
                t2_model, t2_tokens, first_ts, _ = ts_mod._walk_jsonl_for_tokens(
                    jsonl_path, max(0.0, started_at_unix - 3600), ended_at_unix
                )
                if first_ts is not None:
                    # Always record model + tokens when transcript is parsed successfully.
                    # Don't gate on t2_cost > 0 — non-Anthropic models have $0 cost but
                    # still need correct model name recorded.
                    if t2_model:
                        model = t2_model
                    if t2_tokens:
                        total_tokens = sum(t2_tokens.values())
                    cost_source = "pricing_yaml"
                    pricing_data = ts_mod.load_pricing_yaml()
                    if pricing_data:
                        warnings: list = []

                        # Walk subagent JSONLs — same pattern as process_transcript()
                        subagents_list = []
                        _subagents_dir = Path(str(jsonl_path)).with_suffix("") / "subagents"
                        if _subagents_dir.is_dir():
                            for _meta_path in sorted(_subagents_dir.glob("agent-*.meta.json")):
                                try:
                                    _meta = json.loads(_meta_path.read_text())
                                except Exception:
                                    continue
                                _sub_jsonl = _meta_path.with_suffix("").with_suffix(".jsonl")
                                _sm, _st, _sf, _ = ts_mod._walk_jsonl_for_tokens(
                                    _sub_jsonl, 0.0, ended_at_unix
                                )
                                if _sf is None:
                                    continue
                                subagents_list.append({
                                    "type": _meta.get("agentType", "unknown"),
                                    "model": _sm,
                                    "tokens": _st,
                                })

                        parent = {"model": t2_model, "tokens": t2_tokens}
                        t2_cost = ts_mod.compute_cost(parent, subagents_list, pricing_data, warnings)
                        if t2_cost > 0:
                            cost_usd_estimate = t2_cost
        except Exception:
            pass

    # Skip if this session is the parent process of an orchestra run.
    # The orchestra Stop-hook writes the orchestra record first; we check for a matching
    # started_at before writing the native record to avoid double-counting in reports.
    _orch_jsonl = Path.home() / ".claude" / "orchestra" / "telemetry.jsonl"
    if _orch_jsonl.exists():
        try:
            with open(_orch_jsonl) as _f:
                for _line in _f:
                    if not _line.strip():
                        continue
                    try:
                        _r = json.loads(_line)
                        if _r.get("started_at") == args.started_at_iso:
                            print(
                                f"native-session-finalize: skipping {args.session_id} "
                                f"— parent of orchestra session at {args.started_at_iso}",
                                file=sys.stderr,
                            )
                            sys.exit(0)
                    except Exception:
                        pass
        except Exception:
            pass

    # Build telemetry record
    record = {
        "session_id": args.session_id,
        "command": "native",
        "started_at": args.started_at_iso,
        "ended_at": args.ended_at_iso,
        "duration_s": duration_s,
        "cost_usd_estimate": cost_usd_estimate,
        "cost_source": cost_source,
    }
    if model:
        record["model"] = model
    if total_tokens:
        record["total_tokens"] = total_tokens

    # Clean up per-session live caches
    for _suffix in ".cost-cache", ".subcost-cache", ".sohoai":
        _cache_path = Path.home() / ".claude" / "active-sessions" / f"{args.session_id}{_suffix}"
        if _cache_path.exists():
            try:
                _cache_path.unlink()
            except Exception:
                pass

    # Write to telemetry.jsonl — replace existing entry for this session_id if present,
    # else append. Mirrors orchestra telemetry-summarize.py dedup behaviour: re-runs
    # (e.g. Stop hook firing after a manual finalize) produce one authoritative record.
    native_sessions_dir = Path.home() / ".claude" / "native-sessions"
    native_sessions_dir.mkdir(parents=True, exist_ok=True)
    telemetry_jsonl = native_sessions_dir / "telemetry.jsonl"

    try:
        existing_lines: list = []
        if telemetry_jsonl.exists():
            with open(telemetry_jsonl) as f:
                for line in f:
                    if not line.strip():
                        continue
                    try:
                        rec = json.loads(line)
                        if rec.get("session_id") == args.session_id:
                            continue  # drop old record; new one written below
                    except Exception:
                        pass
                    existing_lines.append(line if line.endswith("\n") else line + "\n")
        tmp = telemetry_jsonl.with_suffix(".tmp")
        with open(tmp, "w") as f:
            f.writelines(existing_lines)
            f.write(json.dumps(record) + "\n")
        tmp.replace(telemetry_jsonl)
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
