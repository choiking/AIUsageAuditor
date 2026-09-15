import XCTest
@testable import AuditorCore

final class GroupingTests: XCTestCase {
    private func event(_ source: LogSource, input: Int64, output: Int64) -> LogEvent {
        LogEvent(id: UUID().uuidString, source: source, provenance: source.rawValue,
                 observedAt: Date(), occurredAt: Date(),
                 tokens: LogTokens(input: input, output: output, cacheRead: 0, cacheWrite: 0,
                                   total: input + output),
                 model: source.tool == .claudeCode ? "claude-opus-5" : "gpt-5.4")
    }

    private func makeSample() -> [LogEvent] {
        [event(.claudeDesktop, input: 100, output: 10),
         event(.claudeCLI, input: 200, output: 20),
         event(.claudeIDE, input: 5, output: 1),
         event(.codexDesktop, input: 1000, output: 100),
         event(.codexCLI, input: 2000, output: 200)]
    }

    func testToolTotalsEqualTheSumOfTheirSources() {
        let events = makeSample()
        for tool in LogTool.allCases {
            let toolTotals = LogTotals(events: events.filter { $0.source.tool == tool })
            var summed = (input: Int64(0), output: Int64(0), records: 0)
            for source in LogSource.allCases where source.tool == tool {
                let t = LogTotals(events: events.filter { $0.source == source })
                summed.input += t.input; summed.output += t.output; summed.records += t.records
            }
            XCTAssertEqual(toolTotals.input, summed.input, "\(tool) input")
            XCTAssertEqual(toolTotals.output, summed.output, "\(tool) output")
            XCTAssertEqual(toolTotals.records, summed.records, "\(tool) records")
        }
    }

    func testEveryToolTotalTogetherEqualsTheGrandTotal() {
        let events = makeSample()
        let grand = LogTotals(events: events)
        let byTool = LogTool.allCases.map { tool in LogTotals(events: events.filter { $0.source.tool == tool }) }
        XCTAssertEqual(byTool.reduce(0) { $0 + $1.input }, grand.input)
        XCTAssertEqual(byTool.reduce(0) { $0 + $1.output }, grand.output)
        XCTAssertEqual(byTool.reduce(0) { $0 + $1.records }, grand.records)
    }

    func testEverySourceBelongsToExactlyOneTool() {
        for source in LogSource.allCases {
            let owners = LogTool.allCases.filter { source.tool == $0 }
            XCTAssertEqual(owners.count, 1, "\(source.rawValue) must belong to exactly one tool")
        }
    }

    func testToolCostEqualsTheSumOfItsSourceCosts() {
        let events = makeSample()
        let table = PricingTable.bundled
        for tool in LogTool.allCases {
            let toolCost = table.estimate(events.filter { $0.source.tool == tool }).amount
            var summed = 0.0
            for source in LogSource.allCases where source.tool == tool {
                summed += table.estimate(events.filter { $0.source == source }).amount
            }
            XCTAssertEqual(toolCost, summed, accuracy: 0.000001, "\(tool) cost")
        }
    }

    func testToolNamesAndProvenanceKeys() {
        XCTAssertEqual(LogTool.claudeCode.name, "Claude Code")
        XCTAssertEqual(LogTool.codex.name, "Codex")
        XCTAssertEqual(LogTool.claudeCode.provenanceKey, "entrypoint")
        XCTAssertEqual(LogTool.codex.provenanceKey, "originator")
    }
}

final class BreakdownTests: XCTestCase {
    private func claude(input: Int64, read: Int64, write: Int64, write1h: Int64?, output: Int64) -> LogEvent {
        // Claude reports input as uncached + read + write.
        LogEvent(id: UUID().uuidString, source: .claudeCLI, provenance: "cli",
                 observedAt: Date(), occurredAt: Date(),
                 tokens: LogTokens(input: input + read + write, output: output, cacheRead: read,
                                   cacheWrite: write, total: input + read + write + output,
                                   cacheWrite1h: write1h),
                 model: "claude-opus-5")
    }

    func testClaudePartsSumToInput() {
        let totals = LogTotals(events: [claude(input: 2, read: 27_389, write: 12_740, write1h: 12_740, output: 115)])
        XCTAssertEqual(totals.uncachedInput, 2)
        XCTAssertEqual(totals.cacheRead, 27_389)
        XCTAssertEqual(totals.cacheWrite, 12_740)
        XCTAssertEqual(totals.uncachedInput + totals.cacheRead + totals.cacheWrite, totals.input)
        XCTAssertEqual(totals.output, 115)
    }

    func testCacheWriteTTLsSumToCacheWrite() {
        let totals = LogTotals(events: [claude(input: 0, read: 0, write: 1_000, write1h: 400, output: 0)])
        XCTAssertEqual(totals.cacheWrite1h, 400)
        XCTAssertEqual(totals.cacheWrite5m, 600)
        XCTAssertEqual(totals.cacheWrite1h + totals.cacheWrite5m, totals.cacheWrite)
        XCTAssertFalse(totals.missingWriteTTL)
    }

    func testAbsentTTLSplitFallsEntirelyToShortAndIsFlagged() {
        let totals = LogTotals(events: [claude(input: 0, read: 0, write: 1_000, write1h: nil, output: 0)])
        XCTAssertEqual(totals.cacheWrite1h, 0)
        XCTAssertEqual(totals.cacheWrite5m, 1_000)
        XCTAssertTrue(totals.missingWriteTTL)
    }

    func testZeroCacheWriteDoesNotFlagMissingTTL() {
        let totals = LogTotals(events: [claude(input: 5, read: 0, write: 0, write1h: nil, output: 1)])
        XCTAssertFalse(totals.missingWriteTTL)
    }

    func testCodexCacheCountersAreSubsetsOfInput() {
        // Codex reports input_tokens as already inclusive of its cache counters.
        let event = LogEvent(id: "c", source: .codexCLI, provenance: "codex_cli_rs",
                             observedAt: Date(), occurredAt: Date(),
                             tokens: LogTokens(input: 20_464, output: 205, cacheRead: 11_520,
                                               cacheWrite: 0, reasoning: 52, total: 20_669),
                             model: "gpt-5.4")
        let totals = LogTotals(events: [event])
        XCTAssertEqual(totals.uncachedInput, 8_944)
        XCTAssertEqual(totals.uncachedInput + totals.cacheRead + totals.cacheWrite, totals.input)
        XCTAssertEqual(totals.reasoning, 52)
        XCTAssertEqual(totals.total, 20_669)
    }

    func testUncachedInputNeverGoesNegative() {
        // A malformed record claiming more cache than input must floor at zero.
        let event = LogEvent(id: "x", source: .codexCLI, provenance: "codex_cli_rs",
                             observedAt: Date(), occurredAt: Date(),
                             tokens: LogTokens(input: 10, output: 0, cacheRead: 999,
                                               cacheWrite: 999, total: 10),
                             model: "gpt-5.4")
        XCTAssertEqual(LogTotals(events: [event]).uncachedInput, 0)
    }
}
