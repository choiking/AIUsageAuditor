import XCTest
@testable import AuditorCore

final class PersistenceTests: XCTestCase {
    func testHeuristicHandlesEmptyASCIIChineseEmoji() {
        let tokenizer = ApproximateTokenizer()
        XCTAssertEqual(tokenizer.count(""), 0)
        XCTAssertEqual(tokenizer.count("  \n"), 0)
        XCTAssertEqual(tokenizer.count("abcdefgh"), 2)
        XCTAssertEqual(tokenizer.count("你好"), 3)
        XCTAssertGreaterThan(tokenizer.count("👩‍💻"), 0)
        XCTAssertNil(UnknownCacheEstimator().candidateTokens(for: [], tokenizer: tokenizer))
    }
    func testAtomicRoundTripAndOptionalMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LedgerStore(url: directory.appendingPathComponent("usage.json"))
        XCTAssertTrue(try store.load().events.isEmpty)
        var ledger = Ledger()
        ledger.events = [UsageEvent(id: UUID(), requestID: UUID(), sessionID: "hashed-session",
            observedAt: Date(), updatedAt: Date(), role: .user, visibleTokens: 42,
            tokenizerID: "test", contentHash: digest("private text"))]
        try store.save(ledger)
        XCTAssertEqual(try store.load().events, ledger.events)
        let contents = try String(contentsOf: store.url)
        XCTAssertFalse(contents.contains("private text"))
        XCTAssertNil(try store.load().events.first?.cacheCandidateTokens)
    }
    func testCorruptionIsReportedAndNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try LedgerStore(url: url).load())
        XCTAssertEqual(try String(contentsOf: url), "broken")
    }
    func testLocalDayBoundary() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let midnight = calendar.startOfDay(for: now)
        var ledger = Ledger()
        for date in [midnight.addingTimeInterval(-1), midnight] {
            ledger.events.append(UsageEvent(id: UUID(), requestID: UUID(), sessionID: "a", observedAt: date,
                updatedAt: date, role: .user, visibleTokens: 10, tokenizerID: "test", contentHash: "hash"))
        }
        XCTAssertEqual(ledger.today(at: now, calendar: calendar).input, 10)
        XCTAssertEqual(ledger.today(at: now, calendar: calendar).requests, 1)
    }
}
