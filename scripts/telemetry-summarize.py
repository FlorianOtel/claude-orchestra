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
import urllib.error
import urllib.parse
import urllib.request
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
    """Locate transcript JSONL by scanning all ~/.claude/projects/*/ dirs.
    Works regardless of which path form (NFS vs local) Claude Code used to store it."""
    projects_root = Path.home() / ".claude" / "projects"
    if transcript_session_id:
        # Exact lookup: search every project dir for the specific UUID
        try:
            for proj_dir in sorted(projects_root.iterdir()):
                if not proj_dir.is_dir():
                    continue
                path = proj_dir / f"{transcript_session_id}.jsonl"
                if path.exists():
                    return path
        except Exception:
            pass
        return None
    else:
        # No UUID: return most recently modified JSONL across all projects
        try:
            all_jsonls = list(projects_root.glob("*/*.jsonl"))
            if all_jsonls:
                all_jsonls.sort(key=lambda p: p.stat().st_mtime, reverse=True)
                return all_jsonls[0]
        except Exception:
            pass
        return None


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


def _load_sohoai_config() -> Dict[str, Any]:
    """Load SoHoAI config from config/config.yaml or ~/.claude/orchestra/config.yaml"""
    if yaml is None:
        return {"enabled": True, "timeout_s": 5}

    candidates = [
        Path(__file__).parent.parent / "config" / "config.yaml",
        Path.home() / ".claude" / "orchestra" / "config.yaml",
    ]

    for candidate in candidates:
        if candidate.exists():
            try:
                with open(candidate) as f:
                    data = yaml.safe_load(f)
                    if data and "sohoai" in data:
                        return data["sohoai"]
            except Exception:
                continue

    return {"enabled": True, "timeout_s": 5}


def query_sohoai_usage(
    session_id: str,
    started_at_unix: float,
    ended_at_unix: float,
    base_url: str,
    timeout_s: int,
    model_filter: Optional[str] = None,
) -> Optional[dict]:
    """Query SoHoAI for cost_usd and token counts.

    For native sessions (session_id starts with 'native-'):
      Queries by model_filter + time window.  Source filter is intentionally
      omitted: SoHoAI assigns 'unknown' source to non-Anthropic LiteLLM-routed
      models, so only model name + started_at window are reliable for scoping.
    For orchestra sessions:
      Queries by orchestra_session_id.

    Returns dict with keys:
      cost_usd, input_tokens, output_tokens,
      cache_creation_tokens, cache_read_tokens
    Or None on failure / no matching records.
    """
    if not base_url or not session_id:
        return None

    is_native = session_id.startswith("native-")

    # Build time bounds
    since_iso = datetime.fromtimestamp(started_at_unix - 60, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    until_iso = datetime.fromtimestamp(ended_at_unix + 60, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Try 1: SoHoAI SQLite DB (direct, fast, no HTTP timeout)
    try:
        import sqlite3
        from pathlib import Path
    except ImportError:
        sqlite3 = None
        Path = None

    if sqlite3 is not None and Path is not None:
        cfg = _load_sohoai_config()
        db_path = os.environ.get("SOHOAI_DB_PATH", "") or cfg.get("db_path", "")
        if db_path and Path(db_path).exists():
            try:
                uri = Path(db_path).as_uri() + "?mode=ro"
                with sqlite3.connect(uri, uri=True) as conn:
                    session_started_iso = datetime.fromtimestamp(
                        started_at_unix, tz=timezone.utc
                    ).strftime("%Y-%m-%dT%H:%M:%SZ")
                    if is_native:
                        if not model_filter:
                            return None
                        row = conn.execute(
                            "SELECT SUM(cost_usd), SUM(input_tokens), SUM(output_tokens), "
                            "SUM(cache_creation_tokens), SUM(cache_read_tokens) "
                            "FROM usage_events WHERE (model = ? OR model LIKE ?) "
                            "AND created_at >= ?",
                            (model_filter, f"%{model_filter}%", session_started_iso),
                        ).fetchone()
                        latest = conn.execute(
                            "SELECT input_tokens, output_tokens "
                            "FROM usage_events WHERE (model = ? OR model LIKE ?) "
                            "AND created_at >= ? ORDER BY created_at DESC LIMIT 1",
                            (model_filter, f"%{model_filter}%", session_started_iso),
                        ).fetchone()
                    else:
                        row = conn.execute(
                            "SELECT SUM(cost_usd), SUM(input_tokens), SUM(output_tokens), "
                            "SUM(cache_creation_tokens), SUM(cache_read_tokens) "
                            "FROM usage_events WHERE orchestra_session_id = ?",
                            (session_id,),
                        ).fetchone()
                        latest = conn.execute(
                            "SELECT input_tokens, output_tokens "
                            "FROM usage_events WHERE orchestra_session_id = ? "
                            "ORDER BY created_at DESC LIMIT 1",
                            (session_id,),
                        ).fetchone()
                    if row and (row[0] is not None or row[1] or row[2]):
                        return {
                            "cost_usd": float(row[0] or 0.0),
                            "input_tokens": int(row[1] or 0),
                            "output_tokens": int(row[2] or 0),
                            "cache_creation_tokens": int(row[3] or 0),
                            "cache_read_tokens": int(row[4] or 0),
                            "latest_total_tokens": int(
                                ((latest[0] or 0) + (latest[1] or 0)) if latest else 0
                            ),
                        }
            except Exception:
                pass

    # Try 2: SoHoAI HTTP API fallback
    try:
        if is_native:
            if not model_filter:
                return None
            url = (
                f"{base_url}/v1/usage/stats?"
                f"model={urllib.parse.quote(model_filter)}&"
                f"since={urllib.parse.quote(since_iso)}&"
                f"until={urllib.parse.quote(until_iso)}"
            )
        else:
            url = (
                f"{base_url}/v1/usage/stats?"
                f"session_id={urllib.parse.quote(session_id)}&"
                f"since={urllib.parse.quote(since_iso)}&"
                f"until={urllib.parse.quote(until_iso)}"
            )

        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=timeout_s) as response:
            if response.status != 200:
                return None
            data = json.loads(response.read().decode("utf-8"))
            totals = data.get("totals", {})
            cost_usd = totals.get("cost_usd", 0.0)
            input_tokens = totals.get("input_tokens", 0)
            output_tokens = totals.get("output_tokens", 0)
            cache_creation_tokens = totals.get("cache_creation_tokens", 0)
            cache_read_tokens = totals.get("cache_read_tokens", 0)
            if cost_usd and cost_usd > 0:
                return {
                    "cost_usd": float(cost_usd),
                    "input_tokens": int(input_tokens or 0),
                    "output_tokens": int(output_tokens or 0),
                    "cache_creation_tokens": int(cache_creation_tokens or 0),
                    "cache_read_tokens": int(cache_read_tokens or 0),
                }
            return None
    except Exception:
        return None


def query_sohoai_cost(
    session_id: str,
    started_at_unix: float,
    ended_at_unix: float,
    base_url: str,
    timeout_s: int,
    model_filter: Optional[str] = None,
) -> Optional[float]:
    """Backward-compatible cost-only wrapper around query_sohoai_usage().

    Returns cost_usd float or None on failure.
    """
    result = query_sohoai_usage(
        session_id, started_at_unix, ended_at_unix, base_url, timeout_s, model_filter
    )
    if result is not None:
        cost = result.get("cost_usd")
        if cost and cost > 0:
            return float(cost)
    return None


def query_litellm_cost(parent: Dict, subagents: List[Dict], warnings: List[str]) -> Optional[float]:
    """Query litellm for cost computation with cache-token rates.

    Returns total cost or None if litellm unavailable or computation fails.
    """
    try:
        import litellm
    except ImportError:
        warnings.append("litellm not installed; skipping litellm cost query")
        return None

    total_cost = 0.0

    try:
        # Parent cost
        if parent.get("model"):
            model = _normalize_model_id(parent["model"])
            tokens = parent.get("tokens", {})
            base_cost = litellm.completion_cost(
                model=model,
                completion_response={"usage": {
                    "prompt_tokens": tokens.get("input", 0),
                    "completion_tokens": tokens.get("output", 0),
                }}
            )
            cache_info = litellm.get_model_info(model) or {}
            cache_create_rate = cache_info.get("cache_creation_input_token_cost", 0.0) or 0.0
            cache_read_rate = cache_info.get("cache_read_input_token_cost", 0.0) or 0.0
            parent_cost = (base_cost
                          + tokens.get("cache_creation", 0) * cache_create_rate
                          + tokens.get("cache_read", 0) * cache_read_rate)
            total_cost += parent_cost

        # Subagent costs
        for subagent in subagents:
            if subagent.get("model"):
                model = _normalize_model_id(subagent["model"])
                tokens = subagent.get("tokens", {})
                base_cost = litellm.completion_cost(
                    model=model,
                    completion_response={"usage": {
                        "prompt_tokens": tokens.get("input", 0),
                        "completion_tokens": tokens.get("output", 0),
                    }}
                )
                cache_info = litellm.get_model_info(model) or {}
                cache_create_rate = cache_info.get("cache_creation_input_token_cost", 0.0) or 0.0
                cache_read_rate = cache_info.get("cache_read_input_token_cost", 0.0) or 0.0
                agent_cost = (base_cost
                             + tokens.get("cache_creation", 0) * cache_create_rate
                             + tokens.get("cache_read", 0) * cache_read_rate)
                total_cost += agent_cost

        if total_cost == 0.0:
            # Non-local model but zero cost suggests missing model in litellm
            if parent.get("model") or any(s.get("model") for s in subagents):
                warnings.append("litellm returned zero cost for non-local model")
            return None

        return round(total_cost, 4)
    except Exception as e:
        warnings.append(f"litellm cost computation failed: {e}")
        return None


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
    Walk ALL JSONLs in the project's transcripts directory whose records
    fall in the [started_at_unix, ended_at_unix] window. Captures content
    split across multiple JSONLs by --fork-session or /clear rotation.
    Subagent type is read from the matching `agent-*.meta.json` sidecar.
    """
    parent: Dict[str, Any] = {
        "model": None,
        "tokens": {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0},
        "transcripts": [],   # NEW: list of UUIDs that contributed (forensics)
    }
    subagents: List[Dict[str, Any]] = []

    # Walk ALL JSONLs in the project's transcripts directory whose records
    # fall in the [started_at_unix, ended_at_unix] window. Captures content
    # split across multiple JSONLs by --fork-session or /clear rotation.
    project_transcripts_dir = transcript_path.parent
    if not project_transcripts_dir.is_dir():
        warnings.append(f"Project transcripts dir not found at {project_transcripts_dir}")
        return parent, subagents

    iteration_counts: Dict[str, int] = {}
    for jsonl_path in sorted(project_transcripts_dir.glob("*.jsonl")):
        p_model, p_tokens, p_first, _ = _walk_jsonl_for_tokens(
            jsonl_path, started_at_unix, ended_at_unix
        )
        if p_first is None:
            continue  # no in-window content; skip

        # Accumulate parent tokens; first-encountered model wins
        for k, v in p_tokens.items():
            parent["tokens"][k] += v
        if parent["model"] is None and p_model:
            parent["model"] = p_model
        parent["transcripts"].append(jsonl_path.stem)

        # Walk subagents for THIS parent-UUID
        subagents_dir = jsonl_path.with_suffix("") / "subagents"
        if not subagents_dir.is_dir():
            continue
        for meta_path in sorted(subagents_dir.glob("agent-*.meta.json")):
            try:
                meta = json.loads(meta_path.read_text())
            except Exception as e:
                warnings.append(f"Could not read {meta_path.name}: {e}")
                continue
            subagent_type = meta.get("agentType", "unknown")
            sub_jsonl = meta_path.with_suffix("").with_suffix(".jsonl")
            sub_model, sub_tokens, sub_first, sub_last = _walk_jsonl_for_tokens(
                sub_jsonl, started_at_unix, ended_at_unix
            )
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
    # ended_at_unix: prefer .outcome mtime when present so the time window is
    # bounded by an explicit session terminator (set by /duo-act, /duo-abandon,
    # or the Stop-hook safety net) rather than by "now". This excludes any
    # post-cleanup parent-transcript activity from cost attribution and makes
    # re-runs of the summariser idempotent.
    outcome_path = session_dir / ".outcome"
    if outcome_path.exists():
        try:
            ended_at_unix = outcome_path.stat().st_mtime
        except Exception:
            ended_at_unix = time.time()
    else:
        ended_at_unix = time.time()

    # Transcript — priority: .transcript-path (full path stored at session start) >
    # explicit UUID arg > CLAUDE_PROJECT_DIR-based lookup > legacy hardcoded fallback
    stored_path_file = session_dir / ".transcript-path"
    stored_path_str = stored_path_file.read_text().strip() if stored_path_file.exists() else ""
    if stored_path_str and Path(stored_path_str).exists():
        transcript_path = Path(stored_path_str)
        transcript_session_id = args.transcript_session_id or transcript_path.stem
    else:
        transcript_path = get_transcript_path(args.transcript_session_id)
        transcript_session_id = args.transcript_session_id if args.transcript_session_id else (transcript_path.stem if transcript_path else "unknown")

    # Warnings list
    warnings: List[str] = []

    # Load pricing
    pricing_data = load_pricing_yaml()

    # Process transcript
    parent, subagents = process_transcript(transcript_path, started_at_unix, ended_at_unix, warnings)

    # Compute cost via priority cascade
    cost_usd = None
    cost_source = "none"
    # These are set only when SoHoAI is used, so downstream code can report the split.
    _subagent_cost_usd: Optional[float] = None
    _parent_cost_usd: Optional[float] = None

    # Source 1: SoHoAI API
    # SoHoAI only captures subagent costs: subagents inherit ANTHROPIC_CUSTOM_HEADERS
    # (which carries X-Orchestra-Session-ID), but the parent Brain's API calls go to
    # SoHoAI without that header (env var is written after parent starts).  Augment the
    # SoHoAI subagent figure with a parent cost estimate from T2 JSONL + pricing.yaml.
    sohoai_base = os.environ.get("ANTHROPIC_BASE_URL", "").rstrip("/")
    sohoai_cfg = _load_sohoai_config()
    if sohoai_cfg.get("enabled", True) and sohoai_base:
        sohoai_cost = query_sohoai_cost(
            session_dir.name, started_at_unix, ended_at_unix,
            sohoai_base, int(sohoai_cfg.get("timeout_s", 5))
        )
        if sohoai_cost is not None:
            # Compute parent-only cost from T2 tokens; pass empty subagents list.
            # Use a scratch warnings list so a missing pricing entry doesn't pollute
            # the main warnings (SoHoAI is the primary source; T2 parent is additive).
            _parent_scratch: List[str] = []
            parent_cost = compute_cost(parent, [], pricing_data, _parent_scratch)
            _subagent_cost_usd = sohoai_cost
            _parent_cost_usd = parent_cost
            cost_usd = round(sohoai_cost + parent_cost, 4)
            cost_source = "sohoai_api+t2_parent" if parent_cost > 0 else "sohoai_api"
            if not pricing_data.get("models") and parent_cost == 0:
                warnings.append("parent cost unavailable (no pricing.yaml): sohoai_api subagent cost only")

    # Source 2: litellm (with cache-token rates)
    if cost_usd is None:
        cost_usd = query_litellm_cost(parent, subagents, warnings)
        if cost_usd is not None:
            cost_source = "litellm"

    # Source 3: pricing.yaml (original compute_cost, unchanged)
    if cost_usd is None:
        cost_usd = compute_cost(parent, subagents, pricing_data, warnings)
        cost_source = "pricing_yaml" if pricing_data.get("models") else "none"

    if cost_usd is None:
        cost_usd = 0.0

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
        "cost_source": cost_source,
        # Present only when SoHoAI is the primary source so readers can see the split.
        **({
            "subagent_cost_usd": _subagent_cost_usd,
            "parent_cost_usd": _parent_cost_usd,
        } if _subagent_cost_usd is not None else {}),
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
        "session_dir": str(session_dir),
        "command": args.command,
        "started_at": to_iso8601(started_at_unix),
        "duration_s": int(ended_at_unix - started_at_unix),
        "outcome": telemetry["outcome"],
        "cost_usd_estimate": cost_usd,
        "cost_source": cost_source,
        **({
            "subagent_cost_usd": _subagent_cost_usd,
            "parent_cost_usd": _parent_cost_usd,
        } if _subagent_cost_usd is not None else {}),
        "total_tokens": total_tokens,
        "regret_flag": regret_flag,
        "pricing_snapshot_date": telemetry["pricing_snapshot_date"],
    }

    # If session already in global log, replace the line (stop-hook may have written an
    # earlier stale outcome=abandoned; Brain's cleanup is authoritative).
    new_line = json.dumps(global_line) + "\n"
    if telemetry_jsonl.exists():
        try:
            with open(telemetry_jsonl) as f:
                lines = f.readlines()
            updated = [new_line if session_dir.name in line else line for line in lines]
            if updated != lines:
                with open(str(telemetry_jsonl) + ".tmp", "w") as f:
                    f.writelines(updated)
                os.replace(str(telemetry_jsonl) + ".tmp", str(telemetry_jsonl))
                cost_detail = (
                    f"${cost_usd:.4f} (parent=${_parent_cost_usd:.4f} + subagents=${_subagent_cost_usd:.4f})"
                    if _subagent_cost_usd is not None and _parent_cost_usd
                    else f"${cost_usd:.4f}"
                )
                print(f"telemetry: cost={cost_detail} tokens={total_tokens} outcome={telemetry['outcome']} session={session_dir.name} (updated global log)", flush=True)
                return
        except Exception:
            pass

    try:
        with open(telemetry_jsonl, "a") as f:
            f.write(new_line)
    except Exception as e:
        print(f"telemetry-summarize.py: failed to append to telemetry.jsonl: {e}", file=sys.stderr)
        # Don't exit; the session record was written

    # Print summary
    cost_detail = (
        f"${cost_usd:.4f} (parent=${_parent_cost_usd:.4f} + subagents=${_subagent_cost_usd:.4f})"
        if _subagent_cost_usd is not None and _parent_cost_usd
        else f"${cost_usd:.4f}"
    )
    print(f"telemetry: cost={cost_detail} tokens={total_tokens} outcome={telemetry['outcome']} session={session_dir.name}")


if __name__ == "__main__":
    main()
