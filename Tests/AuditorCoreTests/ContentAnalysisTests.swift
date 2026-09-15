import XCTest
@testable import AuditorCore

final class ContentAnalysisTests: XCTestCase {
    private let time = "2026-09-15T10:00:00.000Z"
    private func data(_ row: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: row, options: .sortedKeys) }
    private func claude(_ id: String, text: Any, extra: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = ["type": "user", "uuid": id, "sessionId": "session", "timestamp": time,
                               "entrypoint": "claude-desktop", "message": ["content": text]]
        r.merge(extra) { _, new in new }; return r
    }
    private func roots(_ directory: URL) -> LogRoots {
        LogRoots(claude: directory.appendingPathComponent("claude"), codex: directory.appendingPathComponent("codex"), codexArchive: directory.appendingPathComponent("archive"))
    }
    private func write(_ rows: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var output = Data()
        for row in rows { output.append(try data(row)); output.append(10) }
        try output.write(to: url)
    }
    func testClaudeSeparatesHumanPromptsToolsAndSyntheticContent() throws {
        var state = ContentFileState(session: "fallback", source: .claudeUnknown)
        let rows = [
            claude("human", text: [["type": "text", "text": "修复登录报错"]], extra: ["origin": ["kind": "human"]]),
            claude("tool", text: [["type": "tool_result", "tool_use_id": "c1", "is_error": true, "content": "not a prompt"]]),
            claude("meta", text: "system context", extra: ["isMeta": true]),
            claude("subagent", text: "delegated task", extra: ["isSidechain": true]),
            claude("injected", text: "injected task", extra: ["origin": ["kind": "system"]]),
            ["type": "assistant", "timestamp": time, "message": ["id": "m1", "model": "test-model", "content": [["type": "tool_use", "id": "c1", "name": "Bash"]]]],
            ["type": "assistant", "timestamp": time, "message": ["id": "m1", "model": "test-model", "content": [["type": "text", "text": "finished"]]]],
            ["type": "assistant", "timestamp": time, "message": ["id": "synthetic", "model": "<synthetic>", "content": []]]
        ]
        for row in rows { ContentAnalysisScanner.ingest(try data(row), tool: .claudeCode, state: &state) }
        let values = Array(state.records.values)
        XCTAssertEqual(values.filter { $0.kind == .prompt }.count, 1)
        XCTAssertEqual(values.first { $0.kind == .prompt }?.category, .debugging)
        XCTAssertEqual(values.first { $0.kind == .prompt }?.source, .claudeDesktop)
        XCTAssertEqual(values.filter { $0.kind == .reply }.count, 1)
        XCTAssertEqual(values.filter { $0.kind == .tool }.count, 1)
        XCTAssertEqual(values.filter { $0.kind == .toolError }.count, 1)
        XCTAssertTrue(values.filter { $0.kind != .prompt }.allSatisfy { $0.text.isEmpty })
    }
    func testCodexMirrorsDeduplicateButLaterRepeatedPromptRemains() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let r = roots(directory)
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "codex-session", "originator": "Codex Desktop"]],
            ["type": "response_item", "timestamp": time, "payload": ["type": "message", "id": "user1", "role": "user", "content": [["type": "input_text", "text": "Explain caching"]]]],
            ["type": "event_msg", "timestamp": "2026-09-15T10:00:01Z", "payload": ["type": "user_message", "message": "Explain caching"]],
            ["type": "event_msg", "timestamp": "2026-09-15T10:01:00Z", "payload": ["type": "user_message", "message": "Explain caching"]],
            ["type": "response_item", "timestamp": time, "payload": ["type": "message", "id": "env", "role": "user", "content": [["type": "input_text", "text": "<environment_context>secret context</environment_context>"]]]],
            ["type": "response_item", "timestamp": time, "payload": ["type": "message", "id": "system", "role": "developer", "content": [["type": "input_text", "text": "instructions"]]]],
            ["type": "response_item", "timestamp": time, "payload": ["type": "function_call", "call_id": "call1", "name": "exec_command"]],
            ["type": "response_item", "timestamp": time, "payload": ["type": "function_call_output", "call_id": "call1", "output": "error is just quoted text"]]
        ]
        try write(rows, to: r.codex.appendingPathComponent("rollout-test.jsonl"))
        try write(rows, to: r.codexArchive.appendingPathComponent("rollout-copy.jsonl"))
        let scanner = ContentAnalysisScanner(roots: r)
        let result = scanner.scan()
        XCTAssertEqual(result.records.filter { $0.kind == .prompt }.count, 2)
        XCTAssertEqual(result.records.filter { $0.kind == .tool }.count, 1)
        XCTAssertEqual(result.records.filter { $0.kind == .toolError }.count, 0)
        XCTAssertTrue(result.records.allSatisfy { $0.source == .codexDesktop })
        XCTAssertEqual(scanner.scan().records.count, result.records.count)
    }
    func testInternalCodexReviewSessionsDoNotBecomeUserContent() throws {
        var state = ContentFileState(session: "fallback", source: .codexUnknown)
        ContentAnalysisScanner.ingest(try data(["type": "session_meta", "payload": [
            "id": "review", "originator": "Codex Desktop", "thread_source": "guardian_review"
        ]]), tool: .codex, state: &state)
        for role in ["user", "assistant"] {
            ContentAnalysisScanner.ingest(try data(["type": "response_item", "timestamp": time, "payload": [
                "type": "message", "role": role, "id": role,
                "content": [["type": "input_text", "text": "copied conversation"]]
            ]]), tool: .codex, state: &state)
        }
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertEqual(ContentAnalysisScanner.cleanPrompt("The following is the Codex agent history whose request action you are assessing.\n## My request:\nold prompt"), "")
    }
    func testIncrementalPartialRewriteAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let r = roots(directory), file = r.claude.appendingPathComponent("test.jsonl")
        try write([claude("one", text: "build a tool")], to: file)
        let scanner = ContentAnalysisScanner(roots: r)
        XCTAssertEqual(scanner.scan().records.count, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: data(claude("two", text: "translate this")))
        XCTAssertEqual(scanner.scan().records.count, 1)
        try handle.write(contentsOf: Data([10])); try handle.close()
        XCTAssertEqual(scanner.scan().records.count, 2)
        try write([claude("new", text: "hi")], to: file)
        XCTAssertEqual(scanner.scan().records.map(\.text), ["hi"])
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(scanner.scan().records.isEmpty)
        // The content scanner creates no persistence files.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["claude"])
    }
    func testPromptCleaningAndClassificationBoundaries() {
        XCTAssertEqual(ContentCategory.classify("prefix suffix fixture"), .other)
        XCTAssertEqual(ContentCategory.classify("帮我翻译这篇文章"), .writing)
        XCTAssertEqual(ContentCategory.classify("设计界面配色"), .design)
        XCTAssertEqual(ContentAnalysisScanner.cleanPrompt("<environment_context>ignore</environment_context>\nFix the error"), "Fix the error")
        XCTAssertEqual(ContentAnalysisScanner.cleanPrompt("# Files mentioned\nignore attachment\n## My request:\nBuild this"), "Build this")
        XCTAssertEqual(ContentAnalysisScanner.cleanPrompt("<send_user_message_question_reply>\n[{\"answer\":\"按这个方向做\"}]\n</send_user_message_question_reply>"), "按这个方向做")
        XCTAssertEqual(ContentAnalysisScanner.cleanPrompt("# AGENTS.md instructions for repo"), "")
        XCTAssertEqual(ContentAnalysisScanner.cleanPrompt("[Request interrupted by user]"), "")
    }
    func testTodayUsesLocalCalendarAndLongPromptsAreBounded() throws {
        var state = ContentFileState(session: "fallback", source: .claudeUnknown)
        ContentAnalysisScanner.ingest(try data(claude("long", text: String(repeating: "x", count: 20_000))), tool: .claudeCode, state: &state)
        XCTAssertEqual(state.records.values.first?.text.count, 12_000)
        var result = ContentAnalysisResult()
        let formatter = ISO8601DateFormatter()
        let dates = ["2026-09-14T15:59:59Z", "2026-09-14T16:00:00Z", "2026-09-15T16:00:00Z"]
        result.records = dates.map { ContentRecord(id: $0, session: "s", date: formatter.date(from: $0)!, source: .codexDesktop, kind: .prompt) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        XCTAssertEqual(result.filtered(today: true, now: formatter.date(from: "2026-09-15T10:00:00Z")!, calendar: calendar).count, 1)
        XCTAssertEqual(result.filtered(today: false).count, 3)
    }
}
