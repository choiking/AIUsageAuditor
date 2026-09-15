# Agent Meter (码表)

[English](README.md) · [中文](README.zh-CN.md)

The app is called **码表** — the everyday Chinese word for a speedometer, with 码 (code) doing double duty. It ships as `码表.app`; the interface calls itself Agent Meter in English.

A local macOS menu-bar app that reads **Claude Code** and **Codex** log files and shows how many tokens they report using, grouped by which tool produced them.

No API key, proxy, certificate, or Accessibility permission required. Nothing leaves your machine.

> **These are log-reported tokens — not your subscription quota, and not a bill.**
> They cover Claude programming-agent and Codex sessions only. Ordinary Claude and ChatGPT chats are not included. The cost figure is a list-price estimate, not a bill — see [Cost estimate](#cost-estimate).

## Screenshot

![码表 dashboard](Docs/images/dashboard.png)

Today's totals across all log sources, broken down by entry point. The interface is available in English and Chinese.

## Install

Download the latest `.zip` from [Releases](https://github.com/choiking/AIUsageAuditor/releases), unzip, and drag **码表.app** to Applications.

The build is ad-hoc signed and not notarized, so macOS blocks it on first launch — often with a misleading "damaged" message. That's the quarantine flag. **Right-click the app → Open → Open**, or:

```sh
xattr -dr com.apple.quarantine "/Applications/码表.app"
```

Requires **Apple Silicon** and **macOS 13+**. Intel and macOS 13 behavior are unverified. Building from source avoids the Gatekeeper step entirely.

## Use

Click the token totals in the menu bar to open the dashboard. To show it immediately:

```sh
open "build/码表.app" --args --show
```

The dashboard has two tabs: **Usage** and **Analysis**. Usage has **Today** and **Imported history**, with input/output totals, cache breakdowns, Codex reasoning breakdowns, per-source counts, last usage time, and data-quality warnings. The menu bar always shows today's accepted input/output, whichever period the dashboard is on.

The source list is two levels. **Claude Code** and **Codex** are the top-level categories, each showing that tool's combined totals; the entrypoint rows below each one break it down by where the usage came from. Both categories start **collapsed**, with a count of how many entrypoints they hold — click one to expand it and to select it. Selecting either level changes the details pane, and a tool's figures are exactly the sum of its entrypoint rows. Collapsing a category whose entrypoint is selected moves the selection up to the category, so the details pane never describes a hidden row. Expansion is per-run and is not remembered between launches.

The **language** is set from the `⋯` menu at the bottom of the panel: **Follow system**, **中文**, or **English**. Follow system means Chinese for a Chinese system language and English for anything else. The choice is remembered per user and switches the interface immediately; it changes display text only — the ledger, the diagnostics report, and `LogInspector` output stay language-independent.

The first scan imports retained history. After that it checks every five seconds and reads only appended bytes. Pause stops scanning for this run; resuming backfills. Selecting a source changes the details, not what is monitored.

**Zero records for a period means no eligible local records were found — not that the account consumed nothing.** Check the source's last usage timestamp to tell old history from fresh usage.

## Content analysis

The **Analysis** tab groups user prompts into development, debugging/testing, research/questions, writing/translation, design, planning, and other. Switch between **Today** and **History** (including today), filter by source, or select a category to search and expand matching prompts. It also shows session counts, assistant message counts, and tool activity for the selected period and source.

Classification uses local Chinese/English keyword rules, not a model, and can be wrong. Percentages represent prompt counts, not tokens. Known system wrappers, tool results, Claude subagent prompts, and Codex internal review/subagent sessions are excluded; unrecognized injected content may remain. Claude streaming message snapshots and copied logs are deduplicated. Codex event/response copies with matching text within five seconds are reconciled. Assistant counts describe recorded messages, not model requests. Only explicit Claude tool errors are counted; Codex error formats are not interpreted.

Content is indexed in memory when this tab opens, then updated with collection. It is never uploaded or added to the usage ledger. Prompt previews and classification use at most 12,000 characters per prompt. History covers currently available source files; deleting a log removes its content from analysis on the next scan. Numeric usage history remains retained separately. Large files import in batches, with an incomplete-data notice.

To inspect aggregates without printing prompts: `./build/LogInspector --analysis`.

## Where the data comes from

| Path | Field read |
| --- | --- |
| `~/.claude/projects/**/*.jsonl` (incl. subagent logs) | `assistant.message.usage` |
| `~/.codex/sessions/**/rollout-*.jsonl`<br>`~/.codex/archived_sessions/**/rollout-*.jsonl` | `event_msg` → `token_count` → `payload.info` |

`CLAUDE_CONFIG_DIR` and `CODEX_HOME` override the base directories if set in the app's launch environment. Finder launches may not inherit terminal variables.

Sources are classified by the entry point recorded in the log, never guessed from process names:

| Log metadata | Shown as |
| --- | --- |
| Claude `entrypoint = claude-desktop` | Claude Code · Desktop |
| Claude `cli` | Claude Code CLI |
| Claude `claude-vscode` / `vscode` | Claude Code IDE |
| Claude `sdk-cli` / `sdk` | Claude Code SDK |
| Codex `originator = Codex Desktop` / `codex_work_desktop` | Codex Desktop |
| Codex `codex_cli_rs` / `codex-tui` / `codex_exec` | Codex CLI / Exec |
| Codex `codex_vscode` | Codex VS Code |
| Codex `codex_sdk_ts` | Codex SDK |
| Codex `codex-chrome-extension-sidepanel` | Codex browser extension |
| Missing or unrecognized | Unknown source |

Two notes on this. Codex's generic `source: vscode` does not override an explicit `originator: Codex Desktop`. And `claude-desktop` means **Claude Code running inside the Claude desktop app**, not the desktop app's Chat tab — every such record carries a working directory (`cwd`) and git branch, which a chat conversation does not have. All four Claude rows are the same product on different surfaces; ordinary Claude chat is not logged here at all. Classification reflects recorded entry points, not whether the client used an API key or a subscription login. No credentials are read.

## How counting works

**Claude.** Streaming snapshots and copied history are deduplicated globally using hashed request/message IDs, keeping the latest timestamp. Conflicting same-time snapshots are excluded until superseded. Input = uncached + cache-read + cache-creation; output is as reported. Breakdowns are already included in input.

**Codex.** Usage is the difference between consecutive cumulative counters within a session. Repeated totals and rate-limit-only events add nothing. `last_token_usage` is not separately summed. Cache counters are input breakdowns, reasoning is an output breakdown, and `total_tokens` is used directly. A counter regression in any tracked field excludes that whole session, with a warning — resets are deliberately not auto-interpreted.

**Dates.** Log timestamps set the local calendar day. An initial Codex snapshot that doesn't match its last invocation may be inherited or pruned history, so it counts toward history only, not today.

A "record" is a deduplicated usage increment — not necessarily one message, request, or invoice line. Missing optional counters are labeled partially unreported; malformed records appear as exclusions rather than fabricated zeros.

## Token breakdown

The details pane lists every token counter the selected tool reports, each row labelled with the JSONL field it is summed from, so a figure can be traced back to the log rather than taken on trust.

**Claude Code** reports per-turn usage, and its cache counters are additive parts of input:

| Row | Field |
| --- | --- |
| Uncached input | `input_tokens` |
| Cache read | `cache_read_input_tokens` |
| Cache write | `cache_creation_input_tokens` |
| — 1-hour TTL | `cache_creation.ephemeral_1h_input_tokens` |
| — 5-minute TTL | `cache_creation.ephemeral_5m_input_tokens` |
| Output | `output_tokens` |

The first three sum to INPUT; the two TTLs sum to cache write.

**Codex** reports cumulative session totals, so each displayed figure is the difference between consecutive counters. Its cache and reasoning counters are breakdowns already contained in input and output:

| Row | Field |
| --- | --- |
| Input | `input_tokens` |
| — of which cache read | `cached_input_tokens` |
| — of which cache write | `cache_write_input_tokens` |
| Output | `output_tokens` |
| — of which reasoning | `reasoning_output_tokens` |
| Total | `total_tokens` |

Codex reports no cache-write TTL split. A counter absent from a record is shown as partially unreported rather than as zero.

## Cost estimate

Each source shows what its tokens would cost **at published API list rates**. This is an estimate of list price, not a record of spend:

- **The logs record no billing mode.** On a Claude or ChatGPT subscription you pay a flat monthly fee, and this number has nothing to do with what you were charged. It answers "what would these tokens cost at API rates", nothing more.
- **Rates are transcribed as of 2026-09-16** from [Anthropic's pricing page](https://platform.claude.com/docs/en/about-claude/pricing) and [OpenAI's](https://developers.openai.com/api/docs/pricing), and go stale when either changes.
- Every figure is copied from those tables rather than derived from a multiplier, because the multipliers have exceptions — Claude Fable 5.1 and Mythos 5.1 read cache at 0.025× base input, not the usual 0.1×.
- Claude cache tokens are priced at their own rates: reads at 0.1× base input, writes at 1.25× for a 5-minute TTL and 2× for a 1-hour TTL. Claude logs report the two write TTLs separately, so they are priced separately rather than assumed; when a record omits the split, the cheaper 5-minute rate is used.
- OpenAI publishes no cache-write premium — cached input is discounted and everything else bills at base input — so both write rates equal the input rate for those models.
- **A few model ids have no published rate** and stay unpriced: `gpt-5-codex`, `gpt-5.2-codex`, and `codex-auto-review` appear on neither pricing page. Lookup is by exact id, or by the id minus a trailing `-YYYYMMDD` snapshot date. It deliberately does **not** fall back to a shared prefix: `gpt-5-codex` is not `gpt-5`, and the codex variants are priced differently from the base models they resemble.
- Records whose model is unknown or unpriced contribute nothing and are reported separately, the same fail-closed rule used for unrecognized sources.

To add or override rates, create `~/Library/Application Support/AIUsageAuditor/pricing.json`. Values are USD per million tokens; entries merge over the bundled table, and a malformed file is ignored rather than zeroing it.

```json
{
  "effective": "2026-09-15",
  "rates": {
    "gpt-6-astra": { "input": 4, "output": 16, "cacheRead": 0.4, "cacheWrite5m": 5, "cacheWrite1h": 8 }
  }
}
```

## Privacy

The ledger at `~/Library/Application Support/AIUsageAuditor/log-usage.json` (the folder keeps its original name so history written before the renames to Agent Meter and then 码表 is not orphaned) is written atomically with mode `0600` (directory `0700`). It holds numeric snapshots, timestamps, recognized source metadata, hashed identities, and read checkpoints.

**The ledger never stores prompts, responses, tool outputs, project paths, raw session/request IDs, or credentials.** The source JSONL files do contain transcripts; parsing happens locally, in memory. `diagnostics.json` records only aggregate scan status and per-source counters.

The **Analysis** tab is the one place prompt text is handled. Opening it builds an in-memory index of prompts, replies, tool calls and tool errors from the same local JSONL, classifies each prompt by keyword into one of seven categories, and lets you search and read them. That index is built on demand, is never written to disk, and is discarded when the app exits — but the tab does display your prompt text on screen, so treat it like any other window showing your transcripts. The Usage tab and the menu bar read counters only.

Read checkpoints advance only for complete lines. Partial appends are retried, files replaced or truncated in place are rebuilt, and sanitized history from removed or rotated paths is kept. A corrupted ledger is preserved and stops import; a failed write does not publish unsaved totals. The running app holds an advisory writer lock in `log-usage.lock`.

## Build

```sh
./scripts/test.sh --disable-sandbox
./scripts/build-app.sh --disable-sandbox
```

`--disable-sandbox` concerns SwiftPM's build process, not app permissions. `AUDITOR_BUILD_ROOT` overrides the build cache location; Xcode's shared scheme is `AgentMeter`.

```sh
./build/LogInspector                                  # same scanner as the GUI, no persistence
./build/LogInspector --state /tmp/auditor-check.json  # scratch file — never the live ledger
python3 scripts/generate_project.py                   # regenerate the Xcode project
```

42 Swift tests cover origin classification, streaming and conflict resolution, copied fork/archive history, cumulative counters, regressions, historical attribution, partial writes, restart idempotency, deleted history, truncation, redaction, corrupt storage, and write failure.

## Limitations

- Remote and cloud usage appears only if records exist locally. History from before installation can't be recovered.
- These local log formats may change between tool versions.
- Copied history rewritten with new identities or timestamps may not deduplicate. In-place rewrites replace that file's cached records.
- Optional counter fields absent from older records are not assumed to be universally reported.
- Files are ingested up to 32 MiB per file per scan; individual records over 8 MiB are skipped.
- Cost figures are list-price arithmetic on reported tokens. They do not account for subscriptions, discounts, batch or priority pricing, free tiers, or partner rates.
- Source time ranges don't prove complete retention or account-wide coverage.
- The v0.3 app no longer polls Accessibility or merges visible-text estimates into totals. Legacy core and inspector utilities remain for reference; the `scripts/proxy*` tools are experimental and the app never runs them.

See [`Docs/JSONL_USAGE_VALIDATION.md`](Docs/JSONL_USAGE_VALIDATION.md) for schema and provenance evidence, and [`Docs/LOG_CAPTURE_VALIDATION.md`](Docs/LOG_CAPTURE_VALIDATION.md) for the earlier desktop-log investigation.

## License

[MIT](LICENSE)
