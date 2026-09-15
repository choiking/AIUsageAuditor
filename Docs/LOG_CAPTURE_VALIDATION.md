# Local log capture validation — 2026-09-15

Follow-up: Claude Code session JSONL and Codex rollout JSONL **do contain usage**;
see [JSONL_USAGE_VALIDATION.md](JSONL_USAGE_VALIDATION.md). The negative result
below is scoped to the ordinary desktop logs inspected, not programming-tool logs.

Result: the inspected desktop logs do not provide a usable current token counter.
No network settings, certificates, app settings or production capture were changed.
No chat text, credentials, raw log lines or organization identifiers were saved here.

## Claude desktop

Inspected the top-level `.log` files in `~/Library/Logs/Claude`, excluding
`mcp-server-*` third-party tool logs. Searches covered input/output/prompt/completion/
total/cache token fields, snake_case and common camelCase names, token_count,
usage, utilization and completion event markers. No numeric token-counter fields
were found. This is a result for the files and field patterns inspected, not proof
that every possible log or future version lacks usage data.

`claude.ai-web.log` and `unknown-window.log` contain duplicate historical utilization
entries from March 2026 in error/threshold contexts. They are not a current or
complete stream of message usage and must not be counted as separate usage events.

Found `~/Library/Application Support/Claude/plan-usage-history.json`:

- Version 2, with 871 samples at inspection time.
- 723 samples contain recognized utilization fields; 148 do not.
- Observed time range: 2026-08-16 through 2026-09-15, Asia/Shanghai.
- Most recent sample: 2026-09-15 16:08:25, with empty `u: {}`.
- Last sample containing recognized fields: 2026-09-02 20:33:35;
  five-hour utilization 0%, seven-day utilization 2%. These are historical values,
  **not current usage**.

Read-only inspection of the installed Claude application bundle confirms that
`fh` maps to `five_hour`, `sd` to `seven_day`, and `u` stores utilization values.
The writer takes its timestamp from Date.now(), retains approximately 30 days,
and suppresses samples within 270 seconds of the previous sample for that
organization. This is a minimum interval, not a guaranteed refresh cadence.
Empty utilization dictionaries can still be written, so file modification time
alone is not evidence of fresh usable usage data. The reason for the recent
empty records has not been established.

Even valid utilization samples represent subscription quota percentages, not
input/output tokens, individual messages or desktop-only activity. They cannot
be added to the Auditor's token ledger or converted to tokens without unsupported
assumptions. Missing values must remain unavailable, not zero. Any future adapter
must retain per-organization separation internally without exposing identifiers.

## ChatGPT Classic

The initial filename-only search found no matching plain `.log` or usage JSON
files in `~/Library/Application Support/com.openai.chat`; the checked conventional
`~/Library/Logs/ChatGPT` and `~/Library/Logs/com.openai.chat` directories were absent.
Caches, databases, conversation stores and credentials were not inspected, and
the earlier restriction on ChatGPT content access was not bypassed.
This does not establish that ChatGPT never writes logs elsewhere.

The official troubleshooting documentation's `~/Library/Logs/com.openai.codex`
path concerns Codex and must not be treated as ChatGPT Classic's conversation
usage log: https://learn.chatgpt.com/es-419/docs/reference/troubleshooting

## Decision

Do not connect these sources to production token counters. Claude's local quota
history may support a separate historical quota view, but the current empty
records make it unsuitable for current usage reporting. Token capture via logs
has not been demonstrated for these official desktop clients.
