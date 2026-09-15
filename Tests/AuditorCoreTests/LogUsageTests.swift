import XCTest
@testable import AuditorCore

final class LogUsageTests: XCTestCase {
    var directory: URL!
    var roots: LogRoots!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots = LogRoots(claude: directory.appendingPathComponent("claude"),
            codex: directory.appendingPathComponent("codex"), codexArchive: directory.appendingPathComponent("archive"))
        for root in [roots.claude, roots.codex, roots.codexArchive] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func encoded(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10); return data
    }
    func file(_ name: String, root: URL, rows: [[String: Any]]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try rows.reduce(into: Data()) { $0.append(try encoded($1)) }.write(to: url)
        return url
    }
    func append(_ rows: [[String: Any]], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd()
        for row in rows { try handle.write(contentsOf: encoded(row)) }
    }
    func claude(_ output: Int, second: Int = 1, entry: String = "claude-desktop", id: String = "r") -> [String: Any] {
        ["type": "assistant", "timestamp": String(format: "2026-09-15T00:00:%02dZ", second),
         "entrypoint": entry, "requestId": id, "sessionId": "PRIVATE_SESSION", "isSidechain": true,
         "message": ["id": "PRIVATE_MESSAGE", "content": "PRIVATE_BODY", "usage": [
            "input_tokens": 2, "output_tokens": output, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 3]]]
    }
    func meta(_ id: String = "session", origin: String = "Codex Desktop") -> [String: Any] {
        ["type": "session_meta", "payload": ["id": id, "originator": origin, "source": "vscode", "cwd": "PRIVATE_PATH"]]
    }
    func codex(_ input: Int, second: Int, lastInput: Int? = nil) -> [String: Any] {
        let total: [String: Any] = ["input_tokens": input, "output_tokens": 10,
            "cached_input_tokens": input / 2, "cache_write_input_tokens": 0,
            "reasoning_output_tokens": 4, "total_tokens": input + 10]
        var last = total
        if let lastInput { last["input_tokens"] = lastInput; last["total_tokens"] = lastInput + 10 }
        return ["timestamp": String(format: "2026-09-15T00:00:%02dZ", second), "type": "event_msg",
                "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last]]]
    }

    func testOriginatorOverridesGenericSourceAndUnknownStaysUnknown() throws {
        XCTAssertEqual(LogSource.classify("Codex Desktop", tool: .codex).0, .codexDesktop)
        XCTAssertEqual(LogSource.classify("codex_vscode", tool: .codex).0, .codexIDE)
        XCTAssertEqual(LogSource.classify("codex-tui", tool: .codex).0, .codexCLI)
        XCTAssertEqual(LogSource.classify(nil, tool: .codex).0, .codexUnknown)
        XCTAssertEqual(LogSource.classify("PRIVATE arbitrary origin", tool: .codex).1, LogProvenance.unreported)
        XCTAssertEqual(LogProvenance.display(LogProvenance.unreported, .english), "not reported")
        XCTAssertEqual(LogProvenance.display(LogProvenance.unreported, .chinese), "未提供或未识别")
        // Ledgers written before the English interface stored the old literal.
        XCTAssertEqual(LogProvenance.display("未提供或未识别", .english), "not reported")
        XCTAssertEqual(LogProvenance.display("codex_vscode", .english), "codex_vscode")
        var state = LogFileState(tool: .codex)
        LogParser.ingest(try encoded(meta()), state: &state)
        LogParser.ingest(try encoded(codex(100, second: 1)), state: &state)
        XCTAssertEqual(state.records.first?.source, .codexDesktop)
    }
    func testClaudeStreamingAndForkCopyUseOneFinalRecord() throws {
        _ = try file("a.jsonl", root: roots.claude, rows: [claude(1), claude(8, second: 2)])
        _ = try file("copy.jsonl", root: roots.claude, rows: [claude(1), claude(8, second: 2)])
        let result = try LogScanner(roots: roots).scan()
        let total = LogTotals(events: result.summary.events)
        XCTAssertEqual(total.records, 1); XCTAssertEqual(total.input, 10)
        XCTAssertEqual(total.output, 8); XCTAssertEqual(total.total, 18)
        XCTAssertEqual(result.summary.events.first?.source, .claudeDesktop)
    }
    func testConflictingClaudeSnapshotIsExcludedUntilLaterSnapshot() throws {
        let url = try file("a.jsonl", root: roots.claude, rows: [claude(1), claude(8), claude(1)])
        let scanner = try LogScanner(roots: roots)
        let result = try scanner.scan()
        XCTAssertEqual(result.summary.ambiguousMessages, 1); XCTAssertTrue(result.summary.events.isEmpty)
        try append([claude(9, second: 3)], to: url)
        XCTAssertEqual(try scanner.scan().summary.events.first?.tokens.output, 9)
    }
    func testCodexCumulativeSnapshotsAndCacheAreNotAddedTwice() throws {
        _ = try file("rollout-a.jsonl", root: roots.codex, rows: [meta(), codex(100, second: 1), codex(150, second: 2), codex(150, second: 3)])
        let totals = LogTotals(events: try LogScanner(roots: roots).scan().summary.events)
        XCTAssertEqual(totals.total, 160); XCTAssertEqual(totals.input, 150)
        XCTAssertEqual(totals.output, 10); XCTAssertEqual(totals.cacheRead, 75)
        XCTAssertEqual(totals.reasoning, 4); XCTAssertEqual(totals.records, 2)
    }
    func testCopiedCodexPrefixAndArchivedCopyDeduplicate() throws {
        let parent = [meta("parent"), codex(100, second: 1)]
        _ = try file("rollout-a.jsonl", root: roots.codex, rows: parent)
        _ = try file("rollout-a.jsonl", root: roots.codexArchive, rows: parent)
        _ = try file("rollout-b.jsonl", root: roots.codex, rows: [meta("fork"), codex(100, second: 1), codex(150, second: 2)])
        XCTAssertEqual(LogTotals(events: try LogScanner(roots: roots).scan().summary.events).total, 160)
    }
    func testRegressionExcludesWholeSessionButNotOtherSources() throws {
        _ = try file("rollout-a.jsonl", root: roots.codex, rows: [meta(), codex(100, second: 1), codex(20, second: 2)])
        _ = try file("a.jsonl", root: roots.claude, rows: [claude(8)])
        let result = try LogScanner(roots: roots).scan()
        XCTAssertEqual(result.summary.excludedSessions.count, 1)
        XCTAssertEqual(LogTotals(events: result.summary.events).total, 18)
    }
    func testInitialInheritedTotalHasNoDailyAttribution() throws {
        _ = try file("rollout-a.jsonl", root: roots.codex, rows: [meta(), codex(1000, second: 1, lastInput: 100), codex(1100, second: 2)])
        let events = try LogScanner(roots: roots).scan().summary.events
        XCTAssertNil(events.first?.occurredAt)
        XCTAssertEqual(LogTotals(events: events.filter { $0.occurredAt != nil }).total, 100)
        XCTAssertEqual(LogTotals(events: events).total, 1110)
    }
    func testPartialWritesRestartAndDeletionRetainSanitizedHistory() throws {
        let url = try file("a.jsonl", root: roots.claude, rows: [claude(1)])
        let store = directory.appendingPathComponent("log-usage.json")
        let first = try LogScanner(roots: roots, storeURL: store)
        XCTAssertEqual(try first.scan().summary.events.count, 1)
        let secondRow = try encoded(claude(8, second: 2))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: secondRow.dropLast()); try handle.close()
        let partial = try first.scan()
        XCTAssertEqual(partial.pendingFiles, 1)
        XCTAssertEqual(partial.summary.events.first?.tokens.output, 1)
        let second = try LogScanner(roots: roots, storeURL: store)
        let final = try FileHandle(forWritingTo: url); try final.seekToEnd(); try final.write(contentsOf: Data([10])); try final.close()
        XCTAssertEqual(try second.scan().summary.events.first?.tokens.output, 8)
        XCTAssertFalse(try second.scan().changed)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try LogScanner(roots: roots, storeURL: store).scan().summary.events.first?.tokens.output, 8)
        let saved = try String(contentsOf: store)
        XCTAssertFalse(saved.contains("PRIVATE")); XCTAssertFalse(saved.contains(url.path))
    }
    func testTruncatedFileIsRebuilt() throws {
        let url = try file("a.jsonl", root: roots.claude, rows: [claude(1), claude(8, second: 2)])
        let scanner = try LogScanner(roots: roots); _ = try scanner.scan()
        try encoded(claude(9, second: 3, id: "new")).write(to: url)
        let result = try scanner.scan()
        XCTAssertEqual(result.summary.events.count, 1); XCTAssertEqual(result.summary.events.first?.tokens.output, 9)
    }
    func testCorruptStorePreservedAndSaveFailureDoesNotPublish() throws {
        let store = directory.appendingPathComponent("bad.json")
        let data = Data("not-json".utf8); try data.write(to: store)
        XCTAssertThrowsError(try LogScanner(roots: roots, storeURL: store))
        XCTAssertEqual(try Data(contentsOf: store), data)
        let badParent = directory.appendingPathComponent("file-not-folder"); try data.write(to: badParent)
        _ = try file("a.jsonl", root: roots.claude, rows: [claude(8)])
        let scanner = try LogScanner(roots: roots, storeURL: badParent.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try scanner.scan()); XCTAssertTrue(scanner.archive.files.isEmpty)
    }
    func testInvalidAndRateOnlyLinesDoNotBecomeZeroUsage() throws {
        var bad = claude(8); bad["timestamp"] = "not a date"
        _ = try file("a.jsonl", root: roots.claude, rows: [bad])
        _ = try file("rollout-a.jsonl", root: roots.codex, rows: [meta(), ["type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]]])
        let result = try LogScanner(roots: roots).scan()
        XCTAssertTrue(result.summary.events.isEmpty); XCTAssertEqual(result.incompleteUsage, 1)
        XCTAssertNil(LogTokens.number(true)); XCTAssertNil(LogTokens.number(-1)); XCTAssertNil(LogTokens.number(1.2))
    }
}
