# Claude Code and Codex usage JSONL — verified 2026-09-15

**v0.3.0 follow-up:** the native Swift log scanner is now connected to the running
Auditor dashboard with origin classification, history/today views, checkpoints
and an independent `log-usage.json` ledger. See the current README. The on-demand
Python reader discussed below remains the original proof, not the app's runtime.
42 Swift tests passed; the packaged UI was verified against real logs, including
automatic ingestion of newly appended Codex Desktop usage while the app ran.

Both sources contain usable **log-reported token usage** on this machine. This
supersedes the ordinary desktop-log investigation only for these programming
tools; it does not establish token capture for ordinary Claude/ChatGPT chats.
The on-demand reader is `scripts/jsonl_usage_probe.py`. It has not been connected
to the menu-bar app or its existing estimated-token ledger.

## Provenance check of the two displayed examples

Further investigation has now linked every imported Claude desktop parent session
to the desktop **Code** session index; see [CLAUDE_DESKTOP_PROVENANCE.md](CLAUDE_DESKTOP_PROVENANCE.md).
That session-ID join resolves the Code/Cowork uncertainty for these specific records.

Read the containing session's metadata for the actual examples shown to the user:

- Claude usage at `2026-07-04T11:34:12.427Z`: containing records consistently
  report `entrypoint: claude-desktop`, `version: 2.1.197`, `isSidechain: true`.
  This identifies a desktop-origin agent/subagent session, not a demonstration
  of ordinary Claude chat capture. The metadata inspected does not distinguish
  the exact desktop product tab or establish subscription vs API-key billing.
  `userType: external` is not evidence of either billing mode.
- Codex usage at `2026-09-12T15:19:05.415Z`: session metadata reports
  `originator: Codex Desktop`, `source: vscode`, `cli_version: 0.153.4`,
  `model_provider: openai`. The explicit originator establishes desktop origin;
  the source string alone should not be interpreted as the VS Code app.
  Provider `openai` does not establish subscription vs API-key authentication.

These were read-only checks of existing records, not newly generated model calls.
No account credentials were read to infer historical authentication.

## Sources observed

- Claude Code: `~/.claude/projects/**/*.jsonl`, including nested subagent logs.
  Ten files, 592 assistant usage snapshots, 277 usable unique request/message
  records; 313 duplicate snapshots and two incomplete records at initial scan.
- Codex: `~/.codex/sessions/**/rollout-*.jsonl` and
  `~/.codex/archived_sessions/**/rollout-*.jsonl`. 164 files including one archive;
  146 sessions with usage. Three sessions had counter regressions and are
  excluded from the proof's totals pending investigation. Live files may change
  these counts, including this running Codex task.

## Counting rules

Claude Code reads only top-level assistant `message.usage`. Deduplicate globally
by `(requestId, message.id)`, keeping the latest timestamp. Conflicting usage at
the same timestamp remains ambiguous until a later snapshot supersedes it.
This avoids repeated streaming blocks and copied fork history. Exclude records
without stable identity, timestamp or the four required numeric fields.
Its observed total combines input, output, cache creation and cache read input
tokens. These have different billing semantics; a sum is not a monetary charge.
Nested tool-result rollups are not counted again.

Codex reads `event_msg` / `token_count` / `payload.info.total_token_usage`.
Compute deltas within a session; never add cumulative snapshots or repeatedly
sum `last_token_usage`. Ignore rate-limit-only events with null `info` and
unchanged counters. Exact copied events with matching timestamp and total/last
usage are deduplicated across sessions. Counter regression in any tracked field
excludes the whole session in this conservative proof; its output is explicitly
partial. Modified copies with changed timestamps are not guaranteed deduplicated.

Codex's `total_tokens` is used directly. Cached input, cache writes and reasoning
output are shown as separate reported fields and are not added to that total.
Optional fields may be absent in older versions; a zero aggregate does not prove
every request reported that category. This reader does not calculate cost.

A file beginning with nonzero cumulative usage contributes that initial snapshot;
if earlier events were pruned, its full amount cannot be attributed to that first
timestamp as newly incurred usage. The proof reports retained-log aggregates and
event time ranges, not a daily billing ledger. Forks, resets, moved files and
historical retention require care in a future incremental importer.

## Privacy and operation

No network requests, certificate installation or proxy changes are needed.
The JSONL documents themselves contain transcripts, but the reader outputs only
allowlisted numeric counters, validated timestamps and diagnostics. It does not
output or copy transcript text, tool bodies, paths, model free text or session IDs.
Incomplete final lines are deferred to the next scan. Invalid JSON, oversized
lines and read errors are counted without logging their contents.

Run from the project:

```sh
python3 scripts/jsonl_usage_probe.py
python3 -m unittest discover -s scripts -p test_jsonl_usage_probe.py -v
```

The local, git-ignored snapshot is `.log-lab/jsonl-usage-report.json`.
Seven synthetic tests cover streaming/fork deduplication, conflicting snapshots,
cumulative usage, copied Codex history, regression exclusion, partial writes,
invalid counters and rate-limit-only events. No production Swift files changed.

Claude Code officially documents JSONL session storage and copied history on forks:
[How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works).
The exact token schemas and values above were verified against local records;
they should not be treated as a permanently stable public storage API.
