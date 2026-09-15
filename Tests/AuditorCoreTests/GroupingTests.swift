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
