#!/usr/bin/env python3
"""
telemetry-summarize.py — parse Claude Code JSONL transcript to produce per-session telemetry.

Usage:
  telemetry-summarize.py <session_dir> <command> <outcome> [transcript_session_id]

Where:
  <session_dir>: absolute path to the orchestra session subdir (contains ctime for started_at)
  <command>: 'brain' or 'duo'
  <outcome>: 'pass', 'fix-loop', 'block', 'abandoned', or 'partial'
  <transcript_session_id>: Claude Code session UUID; if empty, pick most recent .jsonl

Produces:
  ${session_dir}/telemetry.json (full per-session record)
  ${HOME}/.claude/orchestra/telemetry.jsonl (append one line)
  stdout: one-line summary
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    import yaml
except ImportError:
    yaml = None


def _normalize_model_id(model: str) -> str:
    """Strip trailing -YYYYMMDD snapshot suffix from model IDs.

    Claude Code records versioned IDs (e.g. claude-haiku-4-5-20251001) while
    pricing.yaml uses base names (claude-haiku-4-5). Strip the suffix so the
    lookup succeeds.
    """
    if not model:
        return model
    return re.sub(r"-\d{8}$", "", model)


def get_transcript_path(transcript_session_id: str) -> Optional[Path]:
    """Locate transcript at ~/.claude/projects/-mnt-nfs-Florian-Gin-AI-projects-claude-orchestra/<id>.jsonl"""
    if not transcript_session_id:
        # Try to find the most recently modified .jsonl in the transcripts dir
        transcripts_dir = Path.home() / ".claude" / "projects" / "-mnt-nfs-Florian-Gin-AI-projects-claude-orchestra"
        if transcripts_dir.exists():
            jsonl_files = list(transcripts_dir.glob("*.jsonl"))
            if jsonl_files:
                jsonl_files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
                return jsonl_files[0]
        return None
    else:
        path = Path.home() / ".claude" / "projects" / "-mnt-nfs-Florian-Gin-AI-projects-claude-orchestra" / f"{transcript_session_id}.jsonl"
        return path if path.exists() else None


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


def load_pricing_yaml() -> Dict[str, Dict[str, float]]:
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


def read_telemetry_events(session_dir: Path) -> List[Dict[str, Any]]:
    """Read telemetry-events.jsonl if it exists."""
    events_file = session_dir / "telemetry-events.jsonl"
    events = []
    if events_file.exists():
        try:
            with open(events_file) as f:
                for line in f:
                    if line.strip():
                        events.append(json.loads(line))
        except Exception:
            pass
    return events


def read_outcome(session_dir: Path) -> str:
    """Read outcome from .outcome file, or return 'partial' as default."""
    outcome_file = session_dir / ".outcome"
    if outcome_file.exists():
        try:
            return outcome_file.read_text().strip()
        except Exception:
            pass
    return "partial"


def _walk_jsonl_for_tokens(
    jsonl_path: Path,
    started_at_unix: float,
    ended_at_unix: float,
) -> Tuple[Optional[str], Dict[str, int], Optional[float], Optional[float]]:
    """Walk a single JSONL file. Sum assistant-message usage within window.
    Returns (model, tokens, first_ts, last_ts)."""
    tokens = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}
    model: Optional[str] = None
    first_ts: Optional[float] = None
    last_ts: Optional[float] = None
    if not jsonl_path.exists():
        return model, tokens, first_ts, last_ts
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
            ts = parse_iso8601(record.get("timestamp", ""))
            if ts < started_at_unix or ts > ended_at_unix:
                continue
            msg_model = msg.get("model")
            if model is None and msg_model and msg_model != "<synthetic>":
                model = msg_model
            tokens["input"] += usage.get("input_tokens", 0) or 0
            tokens["output"] += usage.get("output_tokens", 0) or 0
            tokens["cache_creation"] += usage.get("cache_creation_input_tokens", 0) or 0
            tokens["cache_read"] += usage.get("cache_read_input_tokens", 0) or 0
            if first_ts is None or ts < first_ts:
                first_ts = ts
            if last_ts is None or ts > last_ts:
                last_ts = ts
    return model, tokens, first_ts, last_ts


def process_transcript(
    transcript_path: Path,
    started_at_unix: float,
    ended_at_unix: float,
    warnings: List[str],
) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """
    Walk parent JSONL for parent tokens, then walk sibling
    `<parent-uuid>/subagents/agent-*.jsonl` for each subagent.
    Subagent type is read from the matching `agent-*.meta.json` sidecar.
    """
    parent: Dict[str, Any] = {
        "model": None,
        "tokens": {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0},
    }
    subagents: List[Dict[str, Any]] = []

    if not transcript_path.exists():
        warnings.append(f"Transcript not found at {transcript_path}")
        return parent, subagents

    parent_model, parent_tokens, _, _ = _walk_jsonl_for_tokens(
        transcript_path, started_at_unix, ended_at_unix
    )
    parent["model"] = parent_model
    parent["tokens"] = parent_tokens

    # Subagent transcripts live alongside the parent JSONL in
    # <parent_jsonl_stem>/subagents/agent-<hash>.{jsonl,meta.json}.
    subagents_dir = transcript_path.with_suffix("") / "subagents"
    if not subagents_dir.is_dir():
        return parent, subagents

    iteration_counts: Dict[str, int] = {}
    for meta_path in sorted(subagents_dir.glob("agent-*.meta.json")):
        try:
            meta = json.loads(meta_path.read_text())
        except Exception as e:
            warnings.append(f"Could not read {meta_path.name}: {e}")
            continue
        subagent_type = meta.get("agentType", "unknown")
        jsonl_path = meta_path.with_suffix("").with_suffix(".jsonl")
        sub_model, sub_tokens, sub_first, sub_last = _walk_jsonl_for_tokens(
            jsonl_path, started_at_unix, ended_at_unix
        )
        # Skip subagents with no in-window activity (e.g. earlier sessions).
        if sub_first is None:
            continue
        iteration_counts[subagent_type] = iteration_counts.get(subagent_type, 0) + 1
        subagents.append({
            "type": subagent_type,
            "model": sub_model,
            "tokens": sub_tokens,
            "duration_s": int((sub_last or sub_first) - sub_first),
            "iteration": iteration_counts[subagent_type],
            "description": meta.get("description", ""),
        })

    return parent, subagents


def compute_cost(parent: Dict, subagents: List[Dict], pricing_data: Dict, warnings: List[str]) -> float:
    """Compute USD cost from tokens and pricing table."""
    if not pricing_data or "models" not in pricing_data:
        warnings.append("Pricing data missing; cost estimate set to 0")
        return 0.0

    models_rates = pricing_data["models"]
    total_cost = 0.0

    # Parent cost
    parent_model_key = _normalize_model_id(parent["model"] or "")
    if parent_model_key and parent_model_key in models_rates:
        rates = models_rates[parent_model_key]
        for tier_key, tier_name in [("input", "input"), ("output", "output"), ("cache_creation", "cache_creation"), ("cache_read", "cache_read")]:
            tokens = parent["tokens"].get(tier_key, 0)
            rate = rates.get(tier_name, 0.0)
            total_cost += (tokens * rate) / 1_000_000.0

    # Subagent costs
    for subagent in subagents:
        sub_model_key = _normalize_model_id(subagent["model"] or "")
        if sub_model_key and sub_model_key in models_rates:
            rates = models_rates[sub_model_key]
            for tier_key, tier_name in [("input", "input"), ("output", "output"), ("cache_creation", "cache_creation"), ("cache_read", "cache_read")]:
                tokens = subagent["tokens"].get(tier_key, 0)
                rate = rates.get(tier_name, 0.0)
                total_cost += (tokens * rate) / 1_000_000.0

    return round(total_cost, 4)


def compute_blast_radius(session_dir: Path) -> Dict[str, int]:
    """Estimate blast radius from PLAN.md, TASKS.json, etc."""
    blast = {
        "files_read": 0,
        "files_edited": 0,
        "loc_changed_estimate": 0,
    }
    # For now, return stub values; detailed parsing would require reading JSONL for tool_use blocks
    return blast


def compute_iterations(session_dir: Path, subagents: List[Dict[str, Any]]) -> Dict[str, int]:
    """Iteration counts derived from subagent dispatch list."""
    counts = {"planner": 0, "actor": 0, "reviewer": 0, "Explore": 0}
    for s in subagents:
        t = s.get("type", "")
        if t in counts:
            counts[t] += 1
    return {
        "planner_replans": max(0, counts["planner"] - 1),
        "actor_invocations": counts["actor"],
        "reviewer_fix_cycles": max(0, counts["reviewer"] - 1),
        "explore_dispatches": counts["Explore"],
    }


def cross_check_t1_t2(session_dir: Path, subagents: List[Dict], warnings: List[str]) -> None:
    """Compare T1 token counts with T2 if telemetry-events.jsonl exists."""
    events = read_telemetry_events(session_dir)
    if not events:
        return

    t1_tokens: Dict[str, int] = {}
    for event in events:
        subagent_type = event.get("subagent", event.get("subagent_type", "unknown"))
        if subagent_type not in t1_tokens:
            t1_tokens[subagent_type] = 0
        usage = event.get("usage") or {}
        t1_tokens[subagent_type] += sum(usage.values())

    # Compare with T2 subagents by type
    t2_tokens: Dict[str, int] = {}
    for subagent in subagents:
        subagent_type = subagent.get("type", "unknown")
        if subagent_type not in t2_tokens:
            t2_tokens[subagent_type] = 0
        tokens = subagent.get("tokens", {})
        t2_tokens[subagent_type] += sum(tokens.values())

    for subagent_type, t2_total in t2_tokens.items():
        if subagent_type in t1_tokens:
            t1_total = t1_tokens[subagent_type]
            if t2_total > 0 and abs(t1_total - t2_total) > 0.05 * t2_total:
                warnings.append(f"T1/T2 token delta on {subagent_type}: T1={t1_total} T2={t2_total}")


def main():
    parser = argparse.ArgumentParser(
        description="Parse Claude Code JSONL transcript to produce per-session telemetry."
    )
    parser.add_argument("session_dir", help="Absolute path to orchestra session subdir")
    parser.add_argument("command", choices=["brain", "duo"], help="Command type")
    parser.add_argument("outcome", choices=["pass", "fix-loop", "block", "abandoned", "partial"], help="Session outcome")
    parser.add_argument("transcript_session_id", nargs="?", default="", help="Claude Code session UUID")
    args = parser.parse_args()

    session_dir = Path(args.session_dir)
    if not session_dir.exists():
        print(f"telemetry-summarize.py: session_dir not found at {session_dir}", file=sys.stderr)
        sys.exit(1)

    # Timestamps. Session dir name encodes UTC start: "<YYYYMMDDTHHMMSSZ>-<PID>".
    # Linux st_ctime is metadata-change time, not creation, so it drifts as files
    # are added to the session_dir; parse the basename instead.
    started_at_unix = time.time()
    m = re.match(r"^(\d{8}T\d{6}Z)-\d+$", session_dir.name)
    if m:
        try:
            dt = datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
            started_at_unix = dt.timestamp()
        except Exception:
            pass
    ended_at_unix = time.time()

    # Transcript
    transcript_path = get_transcript_path(args.transcript_session_id)
    transcript_session_id = args.transcript_session_id if args.transcript_session_id else (transcript_path.stem if transcript_path else "unknown")

    # Warnings list
    warnings: List[str] = []

    # Load pricing
    pricing_data = load_pricing_yaml()

    # Process transcript
    parent, subagents = process_transcript(transcript_path, started_at_unix, ended_at_unix, warnings)

    # Compute cost
    cost_usd = compute_cost(parent, subagents, pricing_data, warnings)

    # Compute iterations and blast radius
    iterations = compute_iterations(session_dir, subagents)
    blast_radius = compute_blast_radius(session_dir)

    # Cross-check T1 vs T2
    cross_check_t1_t2(session_dir, subagents, warnings)

    # Build telemetry.json
    telemetry = {
        "session_id": session_dir.name,
        "command": args.command,
        "transcript_session_id": transcript_session_id,
        "started_at": to_iso8601(started_at_unix),
        "ended_at": to_iso8601(ended_at_unix),
        "duration_s": int(ended_at_unix - started_at_unix),
        "outcome": args.outcome if args.outcome else read_outcome(session_dir),
        "parent": parent,
        "subagents": subagents,
        "iterations": iterations,
        "cost_usd_estimate": cost_usd,
        "blast_radius": blast_radius,
        "pricing_snapshot_date": str(pricing_data.get("last_updated") or datetime.now(timezone.utc).strftime("%Y-%m-%d")),
    }

    if warnings:
        telemetry["parser_warnings"] = warnings

    # Write telemetry.json atomically
    telemetry_path = session_dir / "telemetry.json"
    telemetry_tmp = session_dir / "telemetry.json.tmp"
    try:
        with open(telemetry_tmp, "w") as f:
            json.dump(telemetry, f, indent=2)
        os.replace(telemetry_tmp, telemetry_path)
    except Exception as e:
        print(f"telemetry-summarize.py: failed to write telemetry.json: {e}", file=sys.stderr)
        sys.exit(1)

    # Append to global telemetry.jsonl
    orchestra_dir = Path.home() / ".claude" / "orchestra"
    orchestra_dir.mkdir(parents=True, exist_ok=True)
    telemetry_jsonl = orchestra_dir / "telemetry.jsonl"

    total_tokens = sum(parent["tokens"].values())
    for subagent in subagents:
        total_tokens += sum(subagent["tokens"].values())

    regret_flag = iterations["reviewer_fix_cycles"] > 0 or iterations["planner_replans"] > 0

    global_line = {
        "session_id": session_dir.name,
        "command": args.command,
        "started_at": to_iso8601(started_at_unix),
        "duration_s": int(ended_at_unix - started_at_unix),
        "outcome": telemetry["outcome"],
        "cost_usd_estimate": cost_usd,
        "total_tokens": total_tokens,
        "regret_flag": regret_flag,
        "pricing_snapshot_date": telemetry["pricing_snapshot_date"],
    }

    # Skip append if this session_id is already in the global log (T2 re-run guard).
    if telemetry_jsonl.exists():
        try:
            with open(telemetry_jsonl) as f:
                if any(session_dir.name in line for line in f):
                    print(f"telemetry: cost=${cost_usd:.4f} tokens={total_tokens} outcome={telemetry['outcome']} session={session_dir.name} (global log already has this session, skipping append)", flush=True)
                    return
        except Exception:
            pass

    try:
        with open(telemetry_jsonl, "a") as f:
            f.write(json.dumps(global_line) + "\n")
    except Exception as e:
        print(f"telemetry-summarize.py: failed to append to telemetry.jsonl: {e}", file=sys.stderr)
        # Don't exit; the session record was written

    # Print summary
    print(f"telemetry: cost=${cost_usd} tokens={total_tokens} outcome={telemetry['outcome']} session={session_dir.name}")


if __name__ == "__main__":
    main()
