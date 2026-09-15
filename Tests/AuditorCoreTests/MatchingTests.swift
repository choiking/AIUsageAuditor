import XCTest
@testable import AuditorCore

final class MatchingTests: XCTestCase {
    func message(_ role: String, _ text: String) -> AXNode {
        AXNode(identifier: "\(role)-message", children: [AXNode(role: "AXStaticText", value: text)])
    }
    func testExtractsRolesExcludesDraftsAndButtons() throws {
        let root = AXNode(children: [
            AXNode(role: "AXTextArea", value: "unsent secret", children: [message("user", "draft")]),
            message("user", "sent text"), message("assistant", "answer"),
            AXNode(role: "AXButton", label: "Stop generating")
        ])
        let result = try ChatGPTMatcher().parse(root)
        XCTAssertEqual(result.messages, [VisibleMessage(.user, "sent text"), VisibleMessage(.assistant, "answer")])
        XCTAssertTrue(result.isGenerating)
    }
    func testNestedTextNotCountedTwiceAndRepeatsPreserved() throws {
        let text = AXNode(role: "AXStaticText", value: "repeat", children: [AXNode(role: "AXStaticText", value: "repeat")])
        let root = AXNode(identifier: "assistant-message", children: [text, text, AXNode(role: "AXButton", label: "Copy")])
        XCTAssertEqual(try ChatGPTMatcher().parse(root).messages.first?.text, "repeat\nrepeat")
    }
    func testNoAlternationGuessForUnlabeledText() throws {
        XCTAssertTrue(try ChatGPTMatcher().parse(AXNode(children: [AXNode(role: "AXStaticText", value: "random sidebar")])).messages.isEmpty)
    }
    func testAmbiguousRoleFailsClosed() throws {
        var config = AdapterConfiguration(); config.assistantRules = config.userRules
        XCTAssertThrowsError(try ChatGPTMatcher(configuration: config).parse(message("user", "hi")))
    }
    func testConversationScopeExcludesSidebar() throws {
        var config = AdapterConfiguration()
        config.conversationRules = [NodeRule(identifierPattern: "^transcript$")]
        let root = AXNode(children: [message("user", "sidebar"), AXNode(identifier: "transcript", children: [message("user", "real")])])
        XCTAssertEqual(try ChatGPTMatcher(configuration: config).parse(root).messages.map(\.text), ["real"])
    }
    func testDocumentIdentityIgnoresTitleAndRejectsForeignHosts() throws {
        let matcher = ChatGPTMatcher()
        let id = try matcher.parse(AXNode(label: "title", document: "https://chatgpt.com/c/abc")).documentID
        XCTAssertEqual(id, digest("abc"))
        XCTAssertEqual(id, try matcher.parse(AXNode(label: "renamed", document: "https://chatgpt.com/c/abc")).documentID)
        XCTAssertNil(try matcher.parse(AXNode(document: "https://example.com/c/abc")).documentID)
    }
    func testInvalidConfigurationRejected() {
        var config = AdapterConfiguration(); config.pollInterval = 0
        XCTAssertThrowsError(try config.validate())
        config = AdapterConfiguration(); config.userRules = [NodeRule(identifierPattern: "[")]
        XCTAssertThrowsError(try config.validate())
    }
    func testDefaultConfigurationRoundTrips() throws {
        let config = try JSONDecoder().decode(AdapterConfiguration.self, from: JSONEncoder().encode(AdapterConfiguration()))
        try config.validate()
    }

    func testGenericChatGPTGroupDoesNotSwallowWholeConversation() throws {
        let root = AXNode(label: "ChatGPT", children: [message("user", "question"), message("assistant", "answer")])
        XCTAssertEqual(try ChatGPTMatcher().parse(root).messages.count, 2)
    }
}
