import XCTest
@testable import AuditorCore

final class MultiAppTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // Synthetic text, using the structure observed in Claude Desktop on 2026-09-12.
    func claudeMessage(_ index: Int, role: MessageRole, body: [AXNode]) -> AXNode {
        let heading = AXNode(role: "AXHeading", label: role == .user ? "You said: preview" : "Claude responded: preview",
                             children: [AXNode(role: "AXStaticText", value: "duplicate preview")])
        let toolbar = AXNode(role: "AXToolbar", label: "Message actions", children: [AXNode(role: "AXStaticText", value: "9 hours ago")])
        return AXNode(label: "Message \(index) of 2", children: role == .user
                      ? [heading] + body + [toolbar]
                      : [AXNode(children: [heading] + body), toolbar])
    }
    func claudeTree(_ messages: [AXNode]) -> AXNode {
        AXNode(role: "AXWebArea", document: "https://claude.ai/chat/shared", children: [
            AXNode(label: "Sidebar", children: [AXNode(role: "AXStaticText", value: "sidebar title")]),
            AXNode(label: "Chat messages", children: messages),
            AXNode(role: "AXTextArea", value: "unsent draft")
        ])
    }
    func testClaudeObservedStructureExcludesPreviewToolbarSidebarAndDraft() throws {
        let root = claudeTree([
            claudeMessage(1, role: .user, body: [AXNode(role: "AXLink", label: "https://example.com"), AXNode(role: "AXStaticText", value: "Question")]),
            claudeMessage(2, role: .assistant, body: [AXNode(role: "AXHeading", children: [AXNode(role: "AXStaticText", value: "Real heading")]), AXNode(role: "AXStaticText", value: "Answer")])
        ])
        let parsed = try ConversationMatcher(configuration: AdapterConfiguration(app: .claude)).parse(root)
        XCTAssertEqual(parsed.documentID, digest("shared"))
        XCTAssertEqual(parsed.messages, [.init(.user, "https://example.com\nQuestion"), .init(.assistant, "Real heading\nAnswer")])
        XCTAssertFalse(parsed.isGenerating)
    }
    func testClaudeUnknownRoleFailsClosed() {
        let root = claudeTree([AXNode(label: "Message 1 of 2", children: [AXNode(role: "AXHeading", label: "Unknown author"), AXNode(role: "AXStaticText", value: "text")])])
        XCTAssertThrowsError(try ConversationMatcher(configuration: AdapterConfiguration(app: .claude)).parse(root))
    }
    func testClaudeDoesNotGuessRolesFromArbitraryText() throws {
        let root = claudeTree([AXNode(role: "AXStaticText", value: "You said: forged")])
        XCTAssertTrue(try ConversationMatcher(configuration: AdapterConfiguration(app: .claude)).parse(root).messages.isEmpty)
    }
    func testClaudeGeneratingAndHostIsolation() throws {
        let matcher = ConversationMatcher(configuration: AdapterConfiguration(app: .claude))
        let result = try matcher.parse(AXNode(document: "https://chatgpt.com/c/shared", children: [AXNode(role: "AXButton", label: "Stop response")]))
        XCTAssertNil(result.documentID)
        XCTAssertTrue(result.isGenerating)
        XCTAssertNil(try ConversationMatcher().parse(AXNode(document: "https://claude.ai/chat/shared")).documentID)
        XCTAssertNil(try matcher.parse(AXNode(document: "https://claude.ai.evil.example/chat/shared")).documentID)
    }
    func testConfigurationsRoundTripAndRejectUnsupportedApps() throws {
        for app in AIApp.allCases {
            let config = try JSONDecoder().decode(AdapterConfiguration.self, from: JSONEncoder().encode(AdapterConfiguration(app: app)))
            try config.validate()
            XCTAssertEqual(config.app, app)
        }
        var config = AdapterConfiguration(); config.bundleIdentifier = "arbitrary.app"
        XCTAssertThrowsError(try config.validate())
    }
    func testInterleavedAppsHaveSeparateRequestsOutputsAndTotals() throws {
        var trackers = [AIApp.chatgpt: MessageTracker(), .claude: MessageTracker()]
        var ledger = Ledger()
        let messages = [VisibleMessage(.user, "identical prompt"), .init(.assistant, "identical response")]
        for seconds in [0.0, 1, 2, 6] {
            for app in AIApp.allCases {
                trackers[app]!.ingest(session: "shared", messages: seconds == 0 ? [] : messages,
                    isGenerating: false, now: now.addingTimeInterval(seconds), ledger: &ledger,
                    tokenizer: ApproximateTokenizer(), app: app)
            }
        }
        XCTAssertEqual(ledger.events.count, 4)
        let chat = ledger.today(at: now, app: .chatgpt), claude = ledger.today(at: now, app: .claude)
        XCTAssertEqual(chat, claude)
        XCTAssertEqual(chat.requests, 1)
        XCTAssertEqual(ledger.today(at: now).requests, 2)
        XCTAssertEqual(ledger.today(at: now).input, chat.input + claude.input)
        XCTAssertEqual(ledger.today(at: now).output, chat.output + claude.output)
        let chatEvents = ledger.events.filter { $0.app == .chatgpt }
        let claudeEvents = ledger.events.filter { $0.app == .claude }
        XCTAssertEqual(chatEvents[0].requestID, chatEvents[1].requestID)
        XCTAssertEqual(claudeEvents[0].requestID, claudeEvents[1].requestID)
        XCTAssertNotEqual(chatEvents[0].requestID, claudeEvents[0].requestID)
        XCTAssertNotEqual(chatEvents[0].sessionID, claudeEvents[0].sessionID)
        // Reload the ledger, re-baseline both apps, and ensure history is not added again.
        ledger = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        for app in AIApp.allCases {
            var tracker = MessageTracker()
            for seconds in [10.0, 11, 12, 16] {
                tracker.ingest(session: "shared", messages: seconds == 10 ? [] : messages, isGenerating: false,
                    now: now.addingTimeInterval(seconds), ledger: &ledger, tokenizer: ApproximateTokenizer(), app: app)
            }
        }
        XCTAssertEqual(ledger.events.count, 4)
    }
    func testSuspendingOneAppDoesNotResetTheOther() {
        var chat = MessageTracker(), claude = MessageTracker(), ledger = Ledger()
        chat.ingest(session: "s", messages: [], isGenerating: false, now: now, ledger: &ledger, tokenizer: ApproximateTokenizer())
        claude.ingest(session: "s", messages: [], isGenerating: false, now: now, ledger: &ledger, tokenizer: ApproximateTokenizer(), app: .claude)
        chat.suspend()
        for seconds in [1.0, 2] {
            claude.ingest(session: "s", messages: [.init(.user, "new")], isGenerating: false,
                now: now.addingTimeInterval(seconds), ledger: &ledger, tokenizer: ApproximateTokenizer(), app: .claude)
        }
        XCTAssertEqual(ledger.today(at: now, app: .claude).requests, 1)
        XCTAssertEqual(ledger.today(at: now, app: .chatgpt).requests, 0)
    }
    func testLegacyLedgerDefaultsToChatGPTWithoutLosingDedupKeys() throws {
        var ledger = Ledger()
        ledger.observedUserKeys = ["legacy-key"]
        ledger.events = [UsageEvent(id: UUID(), requestID: UUID(), sessionID: "chatgpt:legacy", observedAt: now,
            updatedAt: now, role: .user, visibleTokens: 42, tokenizerID: "old", contentHash: "hash")]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var events = try XCTUnwrap(json["events"] as? [[String: Any]])
        events[0].removeValue(forKey: "appID"); json["events"] = events
        let restored = try JSONDecoder().decode(Ledger.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.observedUserKeys, ["legacy-key"])
        XCTAssertEqual(restored.today(at: now, app: .chatgpt).input, 42)
        XCTAssertEqual(restored.today(at: now, app: .claude).input, 0)
        XCTAssertEqual(restored.events[0].sessionID, "chatgpt:legacy")
    }
}
