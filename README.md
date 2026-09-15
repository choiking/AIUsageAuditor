# AI Usage Auditor — v0.3.1

The Claude Desktop row explicitly excludes the regular **Chat** tab. An
`entrypoint: claude-desktop` record proves a desktop-origin agent log, not that
all desktop conversations are logged. Empty periods display “no eligible log
usage” rather than a misleading numeric zero. At the latest check, the monitored
Claude JSONL files had not changed since September 8 and their most recent usable
token record was August 17; sending a regular chat message did not add a record
to these sources. Additional JSONL under Application Support's
`local-agent-mode-sessions` was historical too (latest modification July 8) and
is not part of the current scanner's roots.

A local macOS menu-bar app that reads **Claude programming-agent JSONL and Codex rollout JSONL** and groups reported token usage by the log's `entrypoint` / `originator`. SwiftUI, AppKit and Foundation; no Python runtime, API key, proxy, certificate or Accessibility permission is required by the app.

The dashboard offers **Today** and **Imported history**, input/output totals, cache breakdowns, Codex reasoning breakdowns, per-source counts, last usage time and explicit data-quality warnings. These are **log-reported tokens**, not subscription quotas or a billing statement. They do not cover ordinary Claude or ChatGPT chats.

## Run

Open `build/AI Usage Auditor.app`, then click its menu-bar token totals. To show the dashboard immediately:

```sh
open "build/AI Usage Auditor.app" --args --show
```

The first scan imports retained historical logs. Later scans check every five seconds and read only appended bytes. Selecting a source changes the details, not what is monitored. Pause stops scanning for this run; resuming backfills available records. A restart resumes collection. The menu bar always shows today's accepted input/output, regardless of the selected dashboard period.

Zero records for a period means no eligible local records were found for that period, not that the account consumed nothing. The source's last usage timestamp distinguishes old history from fresh usage. Missing optional counters are labeled as partially unreported. Counter regressions and malformed records are shown as exclusions, not fabricated zero usage.

The packaged build targets Apple Silicon/macOS 13+, is locally ad-hoc signed, and is not notarized. Intel and macOS 13 runtime behavior have not been verified.

## Read sources and classification

- `~/.claude/projects/**/*.jsonl`, including subagent logs: `assistant.message.usage`.
- `~/.codex/sessions/**/rollout-*.jsonl`, plus `~/.codex/archived_sessions/**/rollout-*.jsonl`: `event_msg` → `token_count` → `payload.info`.
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` override the respective base directories if set in the app's launch environment. Finder launches may not inherit terminal environment variables.

| Log metadata | Dashboard source |
| --- | --- |
| Claude `entrypoint = claude-desktop` | Claude desktop agent; does not establish which desktop tab |
| Claude `cli` | Claude Code CLI |
| Claude `claude-vscode` / `vscode` | Claude Code IDE |
| Claude `sdk-cli` / `sdk` | Claude Code SDK |
| Codex `originator = Codex Desktop` / `codex_work_desktop` | Codex Desktop |
| Codex `codex_cli_rs` / `codex-tui` / `codex_exec` | Codex CLI / Exec |
| Codex `codex_vscode` | Codex VS Code |
| Codex `codex_sdk_ts` | Codex SDK |
| Codex `codex-chrome-extension-sidepanel` | Codex browser extension |
| Missing/unrecognized values | Unknown source, never guessed from process names |

Codex's generic `source: vscode` does **not** override an explicit `originator: Codex Desktop`. Classification is based on recorded entry points, not on whether the client used an API key or a subscription login. No credentials are read to infer billing mode.

## Counting and dates

- Claude streaming snapshots and copied history are deduplicated globally using hashed request/message IDs. Keep the latest timestamp; conflicting same-time snapshots are excluded until superseded. Input is uncached input + cache-read input + cache-creation input; output is the reported output. The breakdowns are already included in input.
- Codex uses the difference between consecutive cumulative counters in each session. Repeated totals and rate-limit-only events do not add usage. Exact copied timestamp/usage events are deduplicated across files and fork history. `last_token_usage` is not independently summed. Cache counters are input breakdowns, reasoning is an output breakdown, and `total_tokens` is used directly.
- A counter regression in any tracked Codex field excludes that entire session; a warning makes this partial coverage visible. Automatic interpretation of resets is deliberately deferred.
- Log timestamps determine the local calendar day. An initial Codex cumulative snapshot that does not match its last invocation may represent inherited/pruned history: its amount contributes only to history, not today's usage. Source time ranges do not prove complete retention or account-wide coverage.
- The unit shown as a record is a deduplicated usage record/increment, not necessarily a user message, request or invoice line.

## Persistence and privacy

The app saves `~/Library/Application Support/AIUsageAuditor/log-usage.json` atomically with file mode `0600` and directory mode `0700`. It contains numeric snapshots, timestamps, recognized source metadata, hashed identities and read checkpoints. It never copies prompts, responses, tool outputs, project paths, raw session/request IDs or credentials into its ledger. Source JSONL documents do contain transcripts; parsing happens locally in memory.

Read checkpoints are advanced only for complete lines. Partial appends are retried, files replaced/truncated in place are rebuilt, and cached sanitized history from removed/rotated paths is retained. Moved copies are deduplicated by logical identity. A corrupted/unsupported ledger is preserved and stops import; a failed write does not publish unsaved totals. The running app holds an advisory writer lock in `log-usage.lock`; the kernel releases it on exit.

`diagnostics.json` records only aggregate scan status and per-source counters. The legacy `usage.json` and adapter configurations remain untouched. **The v0.3 app no longer polls Accessibility or merges old visible-text estimates into log totals.** Legacy core/inspector utilities remain in the repository for reference.

## Build and verification

```sh
./scripts/test.sh --disable-sandbox
./scripts/build-app.sh --disable-sandbox
python3 scripts/generate_project.py

# Same native scanner as the GUI; no persistence by default.
./build/LogInspector

# Optional checkpoint test in a separate scratch file; do not use the app's live ledger.
./build/LogInspector --state /tmp/auditor-log-check.json
```

The `--disable-sandbox` flag concerns SwiftPM's build process, not app permissions. `AUDITOR_BUILD_ROOT` overrides the build cache location. Xcode's shared scheme is `AIUsageAuditor`.

42 Swift tests cover both retained legacy behavior and eleven new log scenarios: origin classification, streaming/conflict resolution, copied fork/archive history, cumulative counters, regressions, initial historical attribution, partial writes, restart idempotency, deleted history, truncation, redaction, corrupt storage and write failure. Native real-data validation found 4,219 accepted records across seven source categories with three Codex sessions excluded at the validation snapshot; counts can change while tools are running.

## Limitations

These local storage formats may change between app versions. Remote/cloud usage is visible only if its records are available locally. Missing/deleted history from before installation cannot be recovered. Copied history rewritten with new identities/timestamps may not deduplicate. Rewrites in place replace that file's cached records. Optional counter fields absent in older records are not assumed to be universally reported. Very large files are ingested up to 32 MiB per file per scan and individual records over 8 MiB are skipped. No cost calculation is performed.

See `Docs/JSONL_USAGE_VALIDATION.md` for schema/provenance evidence and `Docs/LOG_CAPTURE_VALIDATION.md` for the earlier ordinary-desktop-log investigation. The scripts under `scripts/proxy*` and Python JSONL proof are experimental tools; the app does not run them.
