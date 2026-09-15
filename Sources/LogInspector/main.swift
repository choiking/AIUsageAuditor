import Foundation
import AuditorCore

// Same native reader as the app. Prints aggregate metadata only.
let args = CommandLine.arguments
if args.contains("--analysis") {
    let scanner = ContentAnalysisScanner()
    var result = scanner.scan()
    for _ in 0..<15 where result.pendingFiles > 0 { result = scanner.scan() }
    let prompts = result.records.filter { $0.kind == .prompt }
    let report: [String: Any] = [
        "files": result.files, "readErrors": result.errors, "skipped": result.skipped,
        "pendingFiles": result.pendingFiles, "prompts": prompts.count,
        "todayPrompts": result.filtered(today: true).filter { $0.kind == .prompt }.count,
        "sessions": Set(prompts.map(\.session)).count,
        "replies": result.records.filter { $0.kind == .reply }.count,
        "toolCalls": result.records.filter { $0.kind == .tool }.count,
        "claudeToolErrors": result.records.filter { $0.kind == .toolError }.count,
        "categories": Dictionary(uniqueKeysWithValues: ContentCategory.allCases.map { category in
            (category.rawValue, prompts.filter { $0.category == category }.count)
        })
    ]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}
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
