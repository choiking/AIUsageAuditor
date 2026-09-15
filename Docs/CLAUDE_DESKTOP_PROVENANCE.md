# Claude desktop usage provenance — 2026-09-15

## Result

All 260 accepted `entrypoint: claude-desktop` usage records currently imported
by Auditor belong to four parent sessions. All four parent session IDs match
`cliSessionId` fields in Claude Desktop's **Code session index** under
`~/Library/Application Support/Claude/claude-code-sessions/`. There are zero
unmatched desktop parent sessions in this local dataset.

The current installed Claude application's own local-session reader explicitly
classifies this directory as `code`. It separately reads
`local-agent-mode-sessions`, choosing `chat` or `cowork` from session metadata.
This establishes Code-session provenance using a session-ID join and the
application's storage classification, rather than the entrypoint label alone.

## Example previously shown

The Claude usage snapshot timestamped `2026-07-04T11:34:12.427Z` is in a
`~/.claude/projects/<project>/<parent-session>/subagents/agent-*.jsonl` file.
The containing subagent records have `isSidechain: true`; the parent transcript
has `isSidechain: false`. Both report `entrypoint: claude-desktop` and Claude
Code version `2.1.197`.

The corresponding desktop Code session index has an exactly matching
`cliSessionId`. Its creation time is July 4, 2026 at 19:33:54 Asia/Shanghai;
the usage snapshot is from 19:34:12 that evening. It is historical usage of a
subagent belonging to that Code session, not the user's newly sent ordinary
Chat message.

## Meaning and limits

The observed chain is Claude Desktop's Code session → its Claude Code engine →
subagent → local JSONL usage record → Auditor. This does not prove which mouse
click originally launched every session, or the billing/authentication mode.

The installed app sets the underlying entrypoint via `CLAUDE_CODE_ENTRYPOINT`;
the inspected helper selects `claude-desktop` for its first-party mode and
`claude-desktop-3p` for its third-party mode. This is an entrypoint marker, not
a universal token log for all features in the application. Newer app versions
or imported sessions can have different storage or provenance; future records
must not all be labeled Code solely from this string.

The earlier statement that the exact Code/Cowork surface could not be determined
is superseded **for these four linked sessions** by this additional evidence.
The broader source label still needs a metadata join if future datasets contain
mixed entrypoints. No app behavior or logs were modified during this investigation.

Only metadata, source-code snippets and matching identifiers were inspected.
No transcript text, credentials, titles or organization identifiers are copied
into this report.

Official documentation independently distinguishes Chat, Cowork and Code, and
states that Claude Desktop includes Claude Code without a separate CLI install:
[Claude Code Desktop quickstart](https://code.claude.com/docs/en/desktop-quickstart).
