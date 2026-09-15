# Validation - v0.2 multi-app update

Validated on Apple Silicon with Xcode 26.5 and Swift 6.3.2, September 12-13, 2026.

| Check | Result |
| --- | --- |
| SwiftPM debug build and unit tests | 31 tests, 0 failures |
| Xcode AIUsageAuditor scheme, macOS arm64 | TEST SUCCEEDED; 31 tests, 0 failures |
| SwiftPM release AIUsageAuditor | Built and packaged as build/AI Usage Auditor.app, version 0.2.0 |
| SwiftPM release AXInspector | Built and packaged |
| App signature | codesign --verify --deep --strict passed; local ad-hoc signature |
| Inspector CLI | Help, Claude config export and rejection of an unsupported app verified |
| Two-app demo UI | Launched an isolated demo copy; inspected native accessibility state and screenshot; selected Claude and confirmed separate session totals |
| Demo combined totals | ChatGPT 1,283/2,812 + Claude 640/1,520 = input 1,923 / output 4,332; 2 requests |
| Claude desktop AX structure | Observed one existing conversation through the permitted native UI tool; parser tested with synthetic text using that structure |
| Live Auditor capture and streaming | Not verified; final app requires user-granted Accessibility permission and a live conversation test |
| ChatGPT desktop AX structure | Remains unverified; prior tool restriction was not bypassed |
| Intel / macOS 13 runtime | Not verified; packaged binaries are arm64 |

New tests cover app configuration, observed Claude structure, duplicate role-heading removal, draft/sidebar/toolbar exclusion, unknown role rejection, app-specific document URLs, identical prompts across apps, separate parent request IDs and totals, independent suspension, restart deduplication, and old ledgers without appID retaining ChatGPT attribution. Existing history, streaming, persistence and tokenizer tests also pass.

The first sandboxed Xcode attempt could not write standard developer caches. The authorized retry with normal cache access passed. SwiftPM and release builds used workspace caches. A sandboxed GUI launch could not start; the authorized isolated demo launch succeeded without reading chats or writing usage data. The isolated preview used a different bundle identifier so the existing Auditor instance did not need to be stopped.

This record establishes build/test/demo results. It does not claim official usage accuracy or completed end-to-end compatibility with either live AI app.

## v0.2.1 menu-bar panel sizing

The v0.2 demo check covered a standalone window, which supplied a height to its content. It did not catch MenuBarExtra measuring the root ScrollView without a proposed height. A maximum-height constraint alone allowed the menu-bar panel to collapse to a strip.

The panel now has an explicit height, capped at 740 points and adjusted for the current screen's available height. Scrolling remains available. The release app rebuilt successfully and its signature verified. The desktop UI inspection service timed out during the live dropdown check, so that visual verification remains outstanding. The running app was restarted with version 0.2.1.

## v0.2.2 capture diagnostics and accessibility activation

Live support diagnostics confirmed macOS Accessibility permission was granted and both target processes were running. Before activation, the Auditor read 31 ChatGPT nodes and 12 Claude nodes, recognized zero messages, and misleadingly requested manual sessions.

Added local diagnostics.json containing app/version/permission status, capture counts, role histograms, error messages and timestamps only. It excludes window titles, conversation URLs, IDs and chat text. The file is written atomically with mode 0600. Empty, unrecognized snapshots now report a capture failure before offering a manual session.

The reader requests Electron's documented AXManualAccessibility feature and the Chromium window accessibility flag, with a supported app-level enhanced-accessibility request. Native list/scroll traversal can use specialized content attributes when AXChildren is empty; alternate child views are not concatenated.

After the accessibility requests and bringing Claude forward, live diagnostics reported 272 nodes, a stable session and four recognized Claude messages. These established a baseline; new input/output persistence still requires a fresh user message. ChatGPT remained at 31 nodes and zero matched messages at that stage. This is partial recovery, not verified end-to-end support for both apps.

SwiftPM: 31 tests passed, 0 failures. Release app and inspector rebuilt successfully. A Claude screenshot was blocked by automatic approval review reporting an account usage limit; it was not obtained through another path.

References: https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md and https://www.chromium.org/developers/design-documents/accessibility/
