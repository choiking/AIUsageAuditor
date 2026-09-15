import XCTest
@testable import AuditorCore

final class PricingTests: XCTestCase {
    private func event(_ tokens: LogTokens, model: String?) -> LogEvent {
        LogEvent(id: UUID().uuidString, source: .claudeDesktop, provenance: "claude-desktop",
                 observedAt: Date(), occurredAt: Date(), tokens: tokens, model: model)
    }

    func testUncachedInputAndOutputPriceAtListRates() {
        // Opus 5: $5/1M input, $25/1M output.
        let tokens = LogTokens(input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheWrite: 0)
        let estimate = PricingTable.bundled.estimate([event(tokens, model: "claude-opus-5")])
        XCTAssertEqual(estimate.amount, 30, accuracy: 0.0001)
        XCTAssertEqual(estimate.pricedRecords, 1)
        XCTAssertTrue(estimate.isComplete)
    }

    func testCacheReadsPriceAtOneTenthOfInput() {
        // Input already includes the cache read; it must not also bill as uncached.
        let tokens = LogTokens(input: 1_000_000, output: 0, cacheRead: 1_000_000, cacheWrite: 0)
        let estimate = PricingTable.bundled.estimate([event(tokens, model: "claude-opus-5")])
        XCTAssertEqual(estimate.amount, 0.5, accuracy: 0.0001)
    }

    func testCacheWriteTTLsPriceDifferently() {
        let short = LogTokens(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 1_000_000,
                              cacheWrite1h: 0)
        let long = LogTokens(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 1_000_000,
                             cacheWrite1h: 1_000_000)
        XCTAssertEqual(PricingTable.bundled.estimate([event(short, model: "claude-opus-5")]).amount,
                       6.25, accuracy: 0.0001)
        XCTAssertEqual(PricingTable.bundled.estimate([event(long, model: "claude-opus-5")]).amount,
                       10, accuracy: 0.0001)
    }

    func testMissingTTLSplitBillsShortAndIsReported() {
        let tokens = LogTokens(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 1_000_000)
        let estimate = PricingTable.bundled.estimate([event(tokens, model: "claude-opus-5")])
        XCTAssertEqual(estimate.amount, 6.25, accuracy: 0.0001)
        XCTAssertEqual(estimate.assumedShortTTLTokens, 1_000_000)
    }

    func testUnknownModelContributesNothingAndIsCounted() {
        let tokens = LogTokens(input: 5_000_000, output: 5_000_000, cacheRead: 0, cacheWrite: 0)
        let estimate = PricingTable.bundled.estimate([event(tokens, model: "gpt-6-astra")])
        XCTAssertEqual(estimate.amount, 0)
        XCTAssertEqual(estimate.pricedRecords, 0)
        XCTAssertEqual(estimate.unpricedRecords, 1)
        XCTAssertEqual(estimate.unpricedModels, ["gpt-6-astra"])
        XCTAssertFalse(estimate.isComplete)
    }

    func testAbsentModelIsCountedSeparatelyFromUnpricedModel() {
        let tokens = LogTokens(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let estimate = PricingTable.bundled.estimate([event(tokens, model: nil)])
        XCTAssertEqual(estimate.amount, 0)
        XCTAssertEqual(estimate.unknownModelRecords, 1)
        XCTAssertEqual(estimate.unpricedRecords, 0)
    }

    func testDatedModelIdPricesAsItsBaseModel() {
        let tokens = LogTokens(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let estimate = PricingTable.bundled.estimate([event(tokens, model: "claude-haiku-4-5-20251001")])
        XCTAssertEqual(estimate.amount, 1, accuracy: 0.0001)
        XCTAssertEqual(estimate.pricedRecords, 1)
    }

    func testUnrelatedPrefixDoesNotMatch() {
        XCTAssertNil(PricingTable.bundled.rate(for: "claude"))
        XCTAssertNil(PricingTable.bundled.rate(for: "gpt-5.4"))
    }

    func testUserTableOverridesAndExtendsBundledRates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rates-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"effective":"2026-09-15","rates":{
          "gpt-6-astra":{"input":4,"output":16,"cacheRead":0.4,"cacheWrite5m":5,"cacheWrite1h":8},
          "claude-opus-5":{"input":99,"output":99,"cacheRead":9.9,"cacheWrite5m":99,"cacheWrite1h":99}}}
        """
        try Data(json.utf8).write(to: url)
        let table = PricingTable.load(from: url)
        XCTAssertEqual(table.effective, "2026-09-15")
        XCTAssertEqual(table.rate(for: "gpt-6-astra")?.output, 16)
        XCTAssertEqual(table.rate(for: "claude-opus-5")?.input, 99)
        // Untouched bundled entries survive the merge.
        XCTAssertEqual(table.rate(for: "claude-sonnet-5")?.input, 2)
    }

    func testMalformedUserTableFallsBackToBundled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(PricingTable.load(from: url), PricingTable.bundled)
        XCTAssertEqual(PricingTable.load(from: nil), PricingTable.bundled)
    }

    func testMixedEventsPriceOnlyWhatIsKnown() {
        let priced = LogTokens(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let estimate = PricingTable.bundled.estimate([
            event(priced, model: "claude-opus-5"),
            event(priced, model: "gpt-5.4"),
            event(priced, model: nil)
        ])
        XCTAssertEqual(estimate.amount, 5, accuracy: 0.0001)
        XCTAssertEqual(estimate.pricedRecords, 1)
        XCTAssertEqual(estimate.unpricedRecords, 1)
        XCTAssertEqual(estimate.unknownModelRecords, 1)
        XCTAssertTrue(estimate.hasAnything)
    }
}
