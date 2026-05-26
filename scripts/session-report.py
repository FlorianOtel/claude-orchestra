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
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


_NATIVE_UUID_RE = re.compile(
    r'^native-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
)


def _read_model_from_jsonl(uuid: str) -> Optional[str]:
    """Return first non-synthetic model from transcript JSONL, or None."""
    projects_root = Path.home() / ".claude" / "projects"
    try:
        for proj_dir in sorted(projects_root.iterdir()):
            if not proj_dir.is_dir():
                continue
            p = proj_dir / f"{uuid}.jsonl"
            if p.exists():
                with open(p) as f:
                    for line in f:
                        if not line.strip():
                            continue
                        try:
                            r = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if r.get("type") == "assistant" and "message" in r:
                            m = r["message"].get("model")
                            if m and m != "<synthetic>":
                                return m
    except Exception:
        pass
    return None


def _read_last_ts_from_jsonl(uuid: str) -> Optional[datetime]:
    """Return the timestamp of the last message in the JSONL transcript, or None.
    Scans ALL project directories for the UUID (a session can appear in multiple
    project dirs when the working directory changed mid-session) and returns the
    maximum timestamp found across all copies."""
    projects_root = Path.home() / ".claude" / "projects"
    last_ts: Optional[datetime] = None
    try:
        for proj_dir in projects_root.iterdir():
            if not proj_dir.is_dir():
                continue
            p = proj_dir / f"{uuid}.jsonl"
            if not p.exists():
                continue
            try:
                with open(p) as f:
                    for line in f:
                        if not line.strip():
                            continue
                        try:
                            r = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        ts_str = r.get("timestamp")
                        if ts_str:
                            try:
                                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                                if last_ts is None or ts > last_ts:
                                    last_ts = ts
                            except Exception:
                                pass
            except Exception:
                pass
    except Exception:
        pass
    return last_ts


def _get_project_friendly_name(mangled: str) -> str:
    """Return friendly project name from mangled ~/.claude/projects/ dir name.
    Checks *.project-name sidecar first; falls back to last path component."""
    projects_root = Path.home() / ".claude" / "projects"
    project_dir = projects_root / mangled
    if project_dir.exists():
        try:
            for sidecar in project_dir.glob("*.project-name"):
                return sidecar.read_text().strip()
        except Exception:
            pass
    # NFS mangled paths: -mnt-nfs-Florian-Gin-AI-projects-<name> → <name>
    if mangled.startswith("-mnt-nfs-"):
        parts = mangled.split("-")
        if len(parts) > 4:
            return parts[-1]
    return mangled


def _read_project_from_jsonl(uuid: str) -> str:
    """Locate transcript JSONL for uuid; return friendly project name, or ''."""
    projects_root = Path.home() / ".claude" / "projects"
    try:
        for proj_dir in sorted(projects_root.iterdir()):
            if not proj_dir.is_dir():
                continue
            if (proj_dir / f"{uuid}.jsonl").exists():
                return _get_project_friendly_name(proj_dir.name)
    except Exception:
        pass
    return ""


def parse_iso8601(timestamp_str: str) -> datetime:
    """Parse ISO-8601 timestamp to datetime."""
    try:
        return datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
    except Exception:
        return datetime.now(timezone.utc)


def load_native_telemetry() -> List[Dict[str, Any]]:
    """Load telemetry from ~/.claude/native-sessions/telemetry.jsonl.
    Deduplicates by session_id, keeping the last record (re-runs are authoritative)."""
    path = Path.home() / ".claude" / "native-sessions" / "telemetry.jsonl"
    seen: Dict[str, Dict[str, Any]] = {}  # session_id -> record, last wins
    if path.exists():
        try:
            with open(path) as f:
                for line in f:
                    if line.strip():
                        record = json.loads(line)
                        record["source"] = "native"
                        seen[record.get("session_id", "")] = record
        except Exception:
            pass
    return list(seen.values())


def load_orchestra_telemetry() -> List[Dict[str, Any]]:
    """Load telemetry from ~/.claude/orchestra/telemetry.jsonl.
    Deduplicates by session_id, keeping the last record (re-runs are authoritative)."""
    path = Path.home() / ".claude" / "orchestra" / "telemetry.jsonl"
    seen: Dict[str, Dict[str, Any]] = {}  # session_id -> record, last wins
    if path.exists():
        try:
            with open(path) as f:
                for line in f:
                    if line.strip():
                        record = json.loads(line)
                        source = record.get("command", "unknown")
                        record["source"] = source
                        seen[record.get("session_id", "")] = record
        except Exception:
            pass
    return list(seen.values())


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


def format_cost(cost: float, cost_source: str = "") -> str:
    """Format cost as $X.XXXX, or '-' if zero/unknown."""
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

    def _sort_ts(r: Dict[str, Any]) -> float:
        # Sort by last-activity time.
        # If ended_at is present, use it; otherwise derive from started_at + duration_s.
        # For native sessions we don't do a JSONL scan here for performance —
        # ended_at (stop-hook time) is close enough to the last JSONL message.
        ended = r.get("ended_at", "")
        if ended:
            return parse_iso8601(ended).timestamp()
        started = parse_iso8601(r.get("started_at", "")).timestamp()
        duration = r.get("duration_s", 0) or 0
        return started + duration

    # Sort by last-activity descending (most recent first)
    filtered.sort(key=_sort_ts, reverse=True)

    def _effective_end(r: Dict[str, Any]) -> datetime:
        ended = r.get("ended_at", "")
        if ended:
            return parse_iso8601(ended)
        started = parse_iso8601(r.get("started_at", ""))
        duration = r.get("duration_s", 0) or 0
        from datetime import timedelta
        return started + timedelta(seconds=duration)

    # --since filter (date string YYYY-MM-DD): use effective end time so sessions
    # active in the window are included even if they started before it.
    if args.since:
        try:
            since_dt = datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
            filtered = [r for r in filtered if _effective_end(r) >= since_dt]
        except Exception:
            pass

    # --month filter (YYYY-MM)
    if args.month:
        try:
            month_dt = datetime.strptime(args.month, "%Y-%m").replace(tzinfo=timezone.utc)
            month_next = (month_dt.replace(day=28) + timedelta(days=4)).replace(day=1)
            filtered = [r for r in filtered if month_dt <= _effective_end(r) < month_next]
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
                    cc_pid = int(record.get("cc_pid", 0)) if record.get("cc_pid") else 0
                    if record.get("session_id") and cc_pid:
                        try:
                            os.kill(cc_pid, 0)  # raises if process is dead
                        except (ProcessLookupError, PermissionError):
                            continue  # stale .lck — skip silently
                        active.append({
                            "session_id": record.get("session_id"),
                            "cc_pid": cc_pid,
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

    # Suppress native sessions that are the parent process of an orchestra run.
    # When /brain or /duo runs, the parent CC process is registered as a native session
    # AND finalized as an orchestra session — same started_at, different session_id formats.
    orchestra_start_times = {r.get("started_at") for r in orchestra_records if r.get("started_at")}
    native_records = [
        r for r in native_records
        if r.get("started_at") not in orchestra_start_times
    ]

    all_records = native_records + orchestra_records

    # Apply filters
    filtered_records = apply_filters(all_records, args)

    # Load active sessions, filtered to the same date window as main records
    active_sessions = load_active_native_sessions()

    def _active_in_window(active: Dict[str, Any]) -> bool:
        ts = parse_iso8601(active.get("started_at", ""))
        if args.since:
            try:
                since_dt = datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
                if ts < since_dt:
                    return False
            except Exception:
                pass
        if args.month:
            try:
                month_dt = datetime.strptime(args.month, "%Y-%m").replace(tzinfo=timezone.utc)
                month_next = (month_dt.replace(day=28) + timedelta(days=4)).replace(day=1)
                if not (month_dt <= ts < month_next):
                    return False
            except Exception:
                pass
        return True

    active_sessions = [a for a in active_sessions if _active_in_window(a)]

    # Prepare display records
    display_records = []
    for rec in filtered_records:
        tok = rec.get("total_tokens")
        tok_str = f"{tok:,}" if tok else "-"
        raw_model = rec.get("model") or "-"
        cost_source = rec.get("cost_source", "")
        # Retroactively resolve model for native sessions with missing model field.
        # Handles past records written before the finalize-script fix (cost_source="none").
        if raw_model == "-" and rec.get("source") == "native":
            m = _NATIVE_UUID_RE.match(rec.get("session_id", ""))
            if m:
                jsonl_model = _read_model_from_jsonl(m.group(1))
                if jsonl_model:
                    raw_model = jsonl_model
                    if cost_source != "pricing_yaml":
                        cost_source = "pricing_yaml"
        if raw_model != "-":
            raw_model = re.sub(r'\[.*?\]$', '', raw_model)
            raw_model = re.sub(r'-\d{8}$', '', raw_model)
        # Derive project name: orchestra sessions use session_dir; native sessions look up JSONL
        if rec.get("session_dir"):
            project = extract_project_name(rec["session_dir"])
        elif rec.get("source") == "native":
            m2 = _NATIVE_UUID_RE.match(rec.get("session_id", ""))
            project = (_read_project_from_jsonl(m2.group(1)) or "-") if m2 else "-"
        else:
            project = "-"
        # Date column: last-activity time in local timezone.
        # Native sessions: last JSONL message timestamp (exact last user turn).
        # Orchestra sessions: ended_at if present, else started_at + duration_s
        #   (the global telemetry.jsonl omits ended_at; it's in per-session telemetry.json).
        # All fall back to started_at when no better value is available.
        display_ts: Optional[datetime] = None
        if rec.get("source") == "native":
            m2_id = _NATIVE_UUID_RE.match(rec.get("session_id", ""))
            if m2_id:
                display_ts = _read_last_ts_from_jsonl(m2_id.group(1))
        if display_ts is None:
            ts_str = rec.get("ended_at", "")
            if not ts_str:
                # Derive ended_at from started_at + duration_s for orchestra records.
                started = parse_iso8601(rec.get("started_at", ""))
                duration = rec.get("duration_s", 0) or 0
                if duration > 0:
                    from datetime import timedelta
                    display_ts = started + timedelta(seconds=duration)
            if display_ts is None:
                display_ts = parse_iso8601(ts_str or rec.get("started_at", ""))
        date_str = display_ts.astimezone().strftime("%Y-%m-%d--%H-%M")

        display_records.append({
            "date": date_str,
            "source": rec.get("source", "-"),
            "project": project,
            "model": raw_model,
            "tokens": tok_str,
            "cost": format_cost(rec.get("cost_usd_estimate", 0), cost_source),
            "duration": format_duration(rec.get("duration_s", 0)),
            "outcome": rec.get("outcome", "-"),
        })

    # Add active sessions at top
    for active in active_sessions:
        display_records.insert(0, {
            "date": parse_iso8601(active.get("started_at", "")).astimezone().strftime("%Y-%m-%d--%H-%M"),
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
    total_tokens = 0
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

        # Accumulate cost and tokens (skip active markers)
        if rec["outcome"] != "(active)":
            try:
                if rec["cost"] != "-" and rec["cost"].startswith("$"):
                    total_cost += float(rec["cost"][1:])
                if rec["tokens"] != "-":
                    total_tokens += int(rec["tokens"].replace(",", ""))
                session_count += 1
            except Exception:
                pass

    # Print aggregates — one item per line
    print()
    print("--- Aggregates ---")
    print(f"Sessions : {session_count}")
    print(f"Tokens   : {total_tokens:,}")
    print(f"Cost     : ${total_cost:.4f}")
    print()


if __name__ == "__main__":
    main()
