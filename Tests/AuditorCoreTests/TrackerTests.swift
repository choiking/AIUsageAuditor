import XCTest
@testable import AuditorCore

final class TrackerTests: XCTestCase {
    let tokenizer = ApproximateTokenizer()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func ingest(_ tracker: inout MessageTracker, _ ledger: inout Ledger, _ messages: [VisibleMessage],
                _ seconds: Double, generating: Bool = false, session: String = "a") {
        tracker.ingest(session: session, messages: messages, isGenerating: generating,
                       now: start.addingTimeInterval(seconds), ledger: &ledger, tokenizer: tokenizer)
    }

    func testExistingHistoryIsBaseline() {
        var t = MessageTracker(); var l = Ledger()
        let history = [VisibleMessage(.user, "old"), VisibleMessage(.assistant, "old answer")]
        ingest(&t, &l, history, 0); ingest(&t, &l, history, 10)
        XCTAssertTrue(l.events.isEmpty)
    }

    func testSendConfirmedAndStreamingUpsertsOneOutput() {
        var t = MessageTracker(); var l = Ledger()
        ingest(&t, &l, [], 0)
        let user = [VisibleMessage(.user, "Hello")]
        ingest(&t, &l, user, 1); XCTAssertTrue(l.events.isEmpty)
        ingest(&t, &l, user, 2); XCTAssertEqual(l.events.count, 1)
        let stream = user + [VisibleMessage(.assistant, "Hello there")]
        ingest(&t, &l, stream, 3, generating: true)
        ingest(&t, &l, stream, 4, generating: true)
        ingest(&t, &l, stream, 8, generating: true)
        XCTAssertEqual(l.events.count, 1)
        ingest(&t, &l, stream, 9)
        XCTAssertEqual(l.events.count, 2)
        let responseID = l.events.last!.id
        let revised = user + [VisibleMessage(.assistant, "Hello there, final answer")]
        ingest(&t, &l, revised, 10); ingest(&t, &l, revised, 14)
        XCTAssertEqual(l.events.count, 2)
        XCTAssertEqual(l.events.last!.id, responseID)
        XCTAssertEqual(l.events.last!.visibleTokens, tokenizer.count("Hello there, final answer"))
        XCTAssertEqual(l.events.first!.requestID, l.events.last!.requestID)
        XCTAssertEqual(l.today(at: start).requests, 1)
    }

    func testRepeatedIdenticalPromptsAreSeparateRequests() {
        var t = MessageTracker(); var l = Ledger()
        ingest(&t, &l, [], 0)
        var m = [VisibleMessage(.user, "again")]
        ingest(&t, &l, m, 1); ingest(&t, &l, m, 2)
        m += [VisibleMessage(.assistant, "OK")]
        ingest(&t, &l, m, 3); ingest(&t, &l, m, 4); ingest(&t, &l, m, 8)
        m += [VisibleMessage(.user, "again")]
        ingest(&t, &l, m, 9); ingest(&t, &l, m, 10); ingest(&t, &l, m, 11)
        XCTAssertEqual(l.today(at: start).requests, 2)
        XCTAssertEqual(l.events.filter { $0.role == .user }.count, 2)
    }

    func testSwitchingAndRestartDoNotRecountHistory() {
        var t = MessageTracker(); var l = Ledger()
        ingest(&t, &l, [], 0)
        let m = [VisibleMessage(.user, "hello")]
        ingest(&t, &l, m, 1); ingest(&t, &l, m, 2)
        ingest(&t, &l, m, 3, session: "b"); ingest(&t, &l, m, 4, session: "a")
        t = MessageTracker()
        ingest(&t, &l, m, 5); ingest(&t, &l, m, 10)
        XCTAssertEqual(l.events.count, 1)
    }

    func testPrependEditAndShrinkRebaseWithoutCountingHistory() {
        for changed in [[VisibleMessage(.user, "older"), VisibleMessage(.user, "old")],
                        [VisibleMessage(.user, "edited")], []] {
            var t = MessageTracker(); var l = Ledger()
            ingest(&t, &l, [VisibleMessage(.user, "old")], 0)
            ingest(&t, &l, changed, 1); ingest(&t, &l, changed, 10)
            XCTAssertTrue(l.events.isEmpty)
        }
    }

    func testOldPromptNewAnswerIsNotAttributedToNewRequest() {
        var t = MessageTracker(); var l = Ledger()
        let user = [VisibleMessage(.user, "before monitoring")]
        ingest(&t, &l, user, 0)
        let answer = user + [VisibleMessage(.assistant, "answer")]
        ingest(&t, &l, answer, 1); ingest(&t, &l, answer, 2); ingest(&t, &l, answer, 10)
        XCTAssertTrue(l.events.isEmpty)
    }

    func testTransientNewNodeIsNotCounted() {
        var t = MessageTracker(); var l = Ledger()
        ingest(&t, &l, [], 0)
        ingest(&t, &l, [VisibleMessage(.user, "transient")], 1)
        ingest(&t, &l, [], 2)
        XCTAssertTrue(l.events.isEmpty)
    }

    func testSuspensionDropsUnobservedUsage() {
        var t = MessageTracker(); var l = Ledger()
        ingest(&t, &l, [], 0); t.suspend()
        let m = [VisibleMessage(.user, "while paused")]
        ingest(&t, &l, m, 1); ingest(&t, &l, m, 5)
        XCTAssertTrue(l.events.isEmpty)
    }

    func testPreviouslySeenHistoryReappearingAfterEmptySnapshotIsNotCounted() throws {
        var t = MessageTracker(); var l = Ledger()
        let history = [VisibleMessage(.user, "old request"), VisibleMessage(.assistant, "old response")]
        ingest(&t, &l, history, 0)
        // Persist history fingerprints, restart, observe a temporarily empty transcript.
        l = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(l))
        t = MessageTracker()
        ingest(&t, &l, [], 1)
        ingest(&t, &l, history, 2); ingest(&t, &l, history, 3); ingest(&t, &l, history, 9)
        XCTAssertTrue(l.events.isEmpty)
    }

    func testMultipleTurnsKeepCorrectParentRequests() {
        var t = MessageTracker(); var l = Ledger()
        ingest(&t, &l, [], 0)
        let messages = [VisibleMessage(.user, "one"), VisibleMessage(.assistant, "answer one"),
                        VisibleMessage(.user, "two"), VisibleMessage(.assistant, "answer two")]
        ingest(&t, &l, messages, 1); ingest(&t, &l, messages, 2); ingest(&t, &l, messages, 8)
        XCTAssertEqual(l.events.count, 4)
        XCTAssertEqual(l.events[0].requestID, l.events[1].requestID)
        XCTAssertEqual(l.events[2].requestID, l.events[3].requestID)
        XCTAssertNotEqual(l.events[0].requestID, l.events[2].requestID)
    }
}
