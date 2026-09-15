import Foundation
import AuditorCore

// Same native reader as the app. Prints aggregate metadata only.
let args = CommandLine.arguments
let store: URL? = args.firstIndex(of: "--state").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
do {
    let scanner = try LogScanner(storeURL: store)
    let result = try scanner.scan()
    let records = result.summary.events
    let report: [String: Any] = [
        "records": records.count, "excludedSessions": result.summary.excludedSessions.count,
        "duplicates": result.summary.duplicates, "readErrors": result.errors, "invalidLines": result.invalidLines,
        "incompleteUsage": result.incompleteUsage, "pendingFiles": result.pendingFiles,
        "changed": result.changed,
        "sources": LogSource.allCases.compactMap { source -> [String: Any]? in
            let events = records.filter { $0.source == source }
            guard !events.isEmpty else { return nil }
            let totals = LogTotals(events: events)
            return ["source": source.rawValue, "provenance": Set(events.map(\.provenance)).sorted(),
                    "records": totals.records, "input": totals.input, "output": totals.output,
                    "total": totals.total, "cacheRead": totals.cacheRead, "cacheWrite": totals.cacheWrite,
                    "reasoning": totals.reasoning, "undatedRecords": events.filter { $0.occurredAt == nil }.count]
        }
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch { fputs("Log scan failed; no source contents printed.\n", stderr); exit(1) }
