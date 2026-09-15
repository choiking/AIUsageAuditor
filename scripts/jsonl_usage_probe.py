"""Read-only usage proof for Claude Code and Codex; outputs no transcript text.

This deliberately excludes ambiguous records instead of inventing token counts.
It is an on-demand full scan, not yet the Auditor's production importer.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

CLAUDE = ("input_tokens", "output_tokens", "cache_creation_input_tokens",
          "cache_read_input_tokens")
CODEX = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens",
         "output_tokens", "reasoning_output_tokens", "total_tokens")
MAX_LINE = 8 * 1024 * 1024


def usage(value, keys, required):
    if not isinstance(value, dict) or not all(k in value for k in required):
        return None
    result = {}
    for key in keys:
        if key not in value:
            continue
        number = value[key]
        if type(number) is not int or not 0 <= number < 10**15:
            return None
        result[key] = number
    return result


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(timezone.utc).isoformat() if parsed.tzinfo else None
    except ValueError:
        return None


def records(path, diagnostics):
    try:
        with path.open("rb") as stream:
            while raw := stream.readline(MAX_LINE + 1):
                if len(raw) > MAX_LINE:
                    while raw and not raw.endswith(b"\n"):
                        raw = stream.readline(MAX_LINE + 1)
                    diagnostics["oversize_lines"] += 1
                    continue
                if not raw.endswith(b"\n"):
                    diagnostics["unfinished_tail_lines"] += 1
                    break
                try:
                    value = json.loads(raw)
                except (ValueError, UnicodeError, RecursionError):
                    diagnostics["invalid_json_lines"] += 1
                    continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        diagnostics["unreadable_files"] += 1


def claude_report(files):
    diag = Counter()
    unique = {}
    for path in files:
        for record in records(path, diag):
            if record.get("type") != "assistant":
                continue
            message = record.get("message")
            if not isinstance(message, dict) or "usage" not in message:
                continue
            diag["usage_snapshots"] += 1
            numbers = usage(message["usage"], CLAUDE, CLAUDE)
            identity = (record.get("requestId"), message.get("id"))
            stamp = timestamp(record.get("timestamp"))
            if numbers is None or stamp is None or not all(isinstance(x, str) and x for x in identity):
                diag["excluded_incomplete_records"] += 1
                continue
            previous = unique.get(identity)
            if previous:
                diag["repeated_request_message_snapshots"] += 1
                if stamp < previous[0]:
                    continue
                # Same request/message can appear in streaming and forked history.
                # A timestamp tie with different usage is ambiguous, not additive.
                if stamp == previous[0] and numbers != previous[1]:
                    unique[identity] = (stamp, previous[1], True)
                    continue
                if stamp == previous[0] and previous[2]:
                    continue
            unique[identity] = (stamp, numbers, False)
    totals = Counter()
    accepted = 0
    accepted_times = []
    for stamp, numbers, ambiguous in unique.values():
        if ambiguous:
            diag["excluded_ambiguous_messages"] += 1
            continue
        totals.update(numbers)
        accepted += 1
        accepted_times.append(stamp)
    return {"source": "claude_code", "files": len(files),
            "unique_usage_records": accepted, "diagnostics": dict(diag),
            "observed_tokens": {k: totals[k] for k in CLAUDE},
            "observed_total_tokens": sum(totals[k] for k in CLAUDE),
            "observed_time_range_utc": [min(accepted_times), max(accepted_times)] if accepted_times else None,
            "scope": "local Claude Code records; excludes incomplete or ambiguous records"}


def codex_report(files):
    diag = Counter()
    sessions = defaultdict(list)
    for path in files:
        session = None
        for record in records(path, diag):
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue
            if record.get("type") == "session_meta":
                candidate = payload.get("id") or payload.get("session_id")
                if isinstance(candidate, str) and candidate:
                    session = candidate
            if record.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            diag["token_count_events"] += 1
            info = payload.get("info")
            if not isinstance(info, dict):
                diag["no_usage_info"] += 1
                continue
            total = usage(info.get("total_token_usage"), CODEX,
                          ("input_tokens", "output_tokens", "total_tokens"))
            last = usage(info.get("last_token_usage"), CODEX, ())
            stamp = timestamp(record.get("timestamp"))
            if session is None or total is None or stamp is None:
                diag["excluded_incomplete_records"] += 1
                continue
            sessions[session].append((stamp, total, last))

    candidates = []
    for rows in sessions.values():
        previous = Counter()
        pending = []
        regressed = False
        for stamp, total, last in sorted(rows, key=lambda r: r[0]):
            if any(total[k] < previous[k] for k in total):
                regressed = True
                diag["counter_regressions"] += 1
            delta = {k: total[k] - previous[k] for k in total}
            previous.update({k: total[k] - previous[k] for k in total})
            if not any(delta.values()):
                diag["unchanged_usage_snapshots"] += 1
                continue
            # Exclude exact copied events across rollout/fork histories.
            signature = hashlib.sha256(json.dumps([stamp, total, last], sort_keys=True).encode()).digest()
            pending.append((stamp, signature, delta))
        if regressed:
            diag["excluded_regressing_sessions"] += 1
        else:
            candidates.extend(pending)
    totals = Counter()
    seen = set()
    accepted_times = []
    for stamp, signature, delta in sorted(candidates, key=lambda r: r[0]):
        if signature in seen:
            diag["copied_usage_events"] += 1
            continue
        seen.add(signature)
        totals.update(delta)
        accepted_times.append(stamp)
    return {"source": "codex", "files": len(files), "sessions_with_usage": len(sessions),
            "unique_usage_increments": len(seen), "diagnostics": dict(diag),
            "observed_tokens": {k: totals[k] for k in CODEX},
            "observed_time_range_utc": [min(accepted_times), max(accepted_times)] if accepted_times else None,
            "scope": "local active and archived rollouts; excludes regressing sessions; "
                     "cached and reasoning counters are breakdowns, not additions to total_tokens"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--claude-root", type=Path, default=Path.home() / ".claude/projects")
    parser.add_argument("--codex-root", type=Path, default=Path.home() / ".codex/sessions")
    parser.add_argument("--codex-archive-root", type=Path, default=Path.home() / ".codex/archived_sessions")
    args = parser.parse_args()
    claude = sorted(args.claude_root.rglob("*.jsonl"))
    codex = sorted(set(args.codex_root.rglob("rollout-*.jsonl")) |
                   set(args.codex_archive_root.rglob("rollout-*.jsonl")))
    result = {"checked_at": datetime.now(timezone.utc).isoformat(),
              "classification": "log-reported usage, not a billing statement or account-wide total",
              "sources": [claude_report(claude), codex_report(codex)]}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
