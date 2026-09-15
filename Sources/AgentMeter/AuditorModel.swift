import SwiftUI
import AppKit
import AuditorCore
import Darwin

private actor LogWorker {
    private var scanner: LogScanner?
    private let contentScanner = ContentAnalysisScanner()
    func analyze() -> ContentAnalysisResult { contentScanner.scan() }
    private var lockDescriptor: Int32 = -1
    deinit { if lockDescriptor >= 0 { close(lockDescriptor) } }
    func scan(directory: URL) throws -> LogScanResult {
        if lockDescriptor < 0 {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(directory.appendingPathComponent("log-usage.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw LogScanError.writeFailed }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw LogScanError.writerRunning }
            lockDescriptor = descriptor
        }
        if scanner == nil { scanner = try LogScanner(storeURL: directory.appendingPathComponent("log-usage.json")) }
        return try scanner!.scan()
    }
}

enum AuditorTab: String, CaseIterable, Identifiable {
    case usage, analysis
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .usage: return "gauge.medium"
        case .analysis: return "text.magnifyingglass"
        }
    }
}

/// Either a whole tool (the top-level category) or one of its entrypoints.
enum MeterSelection: Hashable {
    case tool(LogTool)
    case source(LogSource)

    var tool: LogTool {
        switch self {
        case .tool(let tool): return tool
        case .source(let source): return source.tool
        }
    }
    func name(_ language: AppLanguage) -> String {
        switch self {
        case .tool(let tool): return tool.name
        case .source(let source): return source.name(language)
        }
    }
    func contains(_ source: LogSource) -> Bool {
        switch self {
        case .tool(let tool): return source.tool == tool
        case .source(let selected): return source == selected
        }
    }
}

private let languageDefaultsKey = "InterfaceLanguage"

/// Raw values are stable keys; the labels live in `Copy`. Diagnostics records
/// the key, so a report stays readable whatever the interface language is.
enum LogPeriod: String, CaseIterable { case today, all }

@MainActor
final class AuditorModel: ObservableObject {
    static let shared = AuditorModel()
    @Published var tab: AuditorTab = .usage { didSet { if tab == .analysis { requestedScan = true } } }
    @Published private(set) var analysis: ContentAnalysisResult?
    @Published private(set) var analyzing = false
    @Published var period: LogPeriod = .today
    /// Interface language. Persisted per user; nothing else about the ledger or
    /// the diagnostics report depends on it.
    @Published var language: AppLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageDefaultsKey) ?? "") ?? .system {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: languageDefaultsKey) }
    }
    var copy: Copy { Copy(language: language) }
    @Published var selection: MeterSelection = .tool(.claudeCode)
    @Published var clock = Date()
    @Published private(set) var result: LogScanResult?
    @Published private(set) var error: String?
    @Published private(set) var scanning = false
    @Published private(set) var paused = false
    let directory: URL
    let demo: Bool
    private let worker = LogWorker()
    private var loop: Task<Void, Never>?
    private var requestedScan = false
    /// Re-entrancy guard, deliberately not `@Published`: `scanning` is, and a
    /// steady-state rescan takes milliseconds, so flipping it on every cycle
    /// republished twice for a spinner nobody could see.
    private var refreshing = false

    var events: [LogEvent] { result?.summary.events ?? [] }
    var sources: [LogSource] {
        let present = Set(events.map(\.source)).union([.claudeDesktop, .codexDesktop])
        return LogSource.allCases.filter { present.contains($0) }
    }
    func filtered(_ source: LogSource? = nil, today: Bool? = nil) -> [LogEvent] {
        let daily = today ?? (period == .today)
        return events.filter { e in
            (source == nil || e.source == source) && (!daily || e.occurredAt.map { Calendar.current.isDate($0, inSameDayAs: clock) } == true)
        }
    }
    /// Tools that have a row; both are always shown so an empty one reads as
    /// "no records found" rather than silently disappearing.
    var tools: [LogTool] { LogTool.allCases }
    /// Categories start folded; expansion is per-run and deliberately not persisted.
    @Published private(set) var expandedTools: Set<LogTool> = []
    func isExpanded(_ tool: LogTool) -> Bool { expandedTools.contains(tool) }
    func toggleExpansion(_ tool: LogTool) {
        guard expandedTools.contains(tool) else { expandedTools.insert(tool); return }
        expandedTools.remove(tool)
        // Never leave the details pane describing a row the list no longer shows.
        if case .source(let source) = selection, source.tool == tool { selection = .tool(tool) }
    }
    func sources(in tool: LogTool) -> [LogSource] { sources.filter { $0.tool == tool } }
    func events(for selection: MeterSelection, today: Bool? = nil) -> [LogEvent] {
        let daily = today ?? (period == .today)
        return events.filter { e in
            selection.contains(e.source) &&
                (!daily || e.occurredAt.map { Calendar.current.isDate($0, inSameDayAs: clock) } == true)
        }
    }
    func totals(for selection: MeterSelection) -> LogTotals { LogTotals(events: events(for: selection)) }
    var totals: LogTotals { LogTotals(events: filtered()) }
    var today: LogTotals { LogTotals(events: filtered(today: true)) }
    func totals(for source: LogSource) -> LogTotals { LogTotals(events: filtered(source)) }
    var selectedTotals: LogTotals { totals(for: selection) }
    /// User rates override the bundled table; see Pricing.swift.
    private(set) lazy var pricing = PricingTable.load(from: directory.appendingPathComponent("pricing.json"))
    var cost: CostEstimate { pricing.estimate(filtered()) }
    var selectedCost: CostEstimate { pricing.estimate(events(for: selection)) }
    var lastUsage: Date? { events.filter { selection.contains($0.source) }.map(\.observedAt).max() }
    var provenance: String {
        let values = Set(events.filter { selection.contains($0.source) }.map(\.provenance)).sorted()
        let key = selection.tool.provenanceKey
        let shown = values.map { LogProvenance.display($0, language) }
        return key + " = " + (shown.isEmpty ? copy.noProvenance : shown.joined(separator: ", "))
    }
    var menuTitle: String {
        guard result != nil else { return error == nil ? "◌ Logs" : "! Logs" }
        return "\(error == nil ? "" : "! ")↑\(today.input.formatted(.number.notation(.compactName))) ↓\(today.output.formatted(.number.notation(.compactName)))"
    }
    var status: String {
        if error != nil { return copy.scanFailed }
        if demo { return copy.demoMode }
        if scanning { return copy.reading }
        if paused { return copy.pausedStatus }
        if result == nil { return copy.awaitingFirstImport }
        if result!.filesByTool.values.reduce(0, +) == 0 { return copy.noLogsFound }
        return copy.watching
    }
    var warnings: [String] {
        guard let r = result else { return [] }
        var lines: [String] = []
        if !r.summary.excludedSessions.isEmpty { lines.append(copy.excludedSessions(r.summary.excludedSessions.count)) }
        if r.errors > 0 { lines.append(copy.readErrors(r.errors)) }
        if r.incompleteUsage + r.summary.ambiguousMessages > 0 {
            lines.append(copy.incompleteUsage(r.incompleteUsage, ambiguous: r.summary.ambiguousMessages))
        }
        if r.invalidLines > 0 { lines.append(copy.invalidLines(r.invalidLines)) }
        let unallocated = events.filter { $0.occurredAt == nil }.count
        if unallocated > 0 { lines.append(copy.undatedRecords(unallocated)) }
        return lines
    }

    init() {
        demo = ProcessInfo.processInfo.arguments.contains("--demo")
        if ProcessInfo.processInfo.arguments.contains("--analysis") { tab = .analysis }
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Kept as "AIUsageAuditor" across the renames to Agent Meter and 码表 so that
            // ledgers written by earlier versions are not orphaned.
            .appendingPathComponent("AIUsageAuditor", isDirectory: true)
        if demo {
            var summary = LogSummary()
            summary.events = [
                LogEvent(id: "demo-a", source: .claudeDesktop, provenance: "claude-desktop", observedAt: Date(), occurredAt: Date(),
                    tokens: LogTokens(input: 12500, output: 1200, cacheRead: 9000, cacheWrite: 2500, total: 13700)),
                LogEvent(id: "demo-b", source: .codexDesktop, provenance: "Codex Desktop", observedAt: Date(), occurredAt: Date(),
                    tokens: LogTokens(input: 18600, output: 2500, cacheRead: 15000, cacheWrite: 0, reasoning: 800, total: 21100))]
            result = LogScanResult(summary: summary, filesByTool: [.claudeCode: 2, .codex: 4], errors: 0,
                invalidLines: 0, incompleteUsage: 0, pendingFiles: 0, checkedAt: Date(), changed: false)
            return
        }
        loop = Task { [weak self] in
            var next = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                // The clock only ever feeds same-day comparisons. Republishing
                // it twice a second rebuilt the whole panel — and any menu open
                // inside it — so it now moves only when the day does.
                let now = Date()
                if !Calendar.current.isDate(self.clock, inSameDayAs: now) { self.clock = now }
                if !self.paused && (Date() >= next || self.requestedScan) {
                    self.requestedScan = false
                    await self.refresh()
                    next = Date().addingTimeInterval(5)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    func refreshNow() { requestedScan = true }
    func togglePaused() { paused.toggle(); if !paused { requestedScan = true } }
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let scanIndicator = indicator { self.scanning = true }
        do { result = try await worker.scan(directory: directory); error = nil }
        catch { self.error = (error as? LogScanError)?.message(language) ?? copy.readFailed }
        scanIndicator.cancel()
        if scanning { scanning = false }
        if tab == .analysis {
            let analysisIndicator = indicator { self.analyzing = true }
            analysis = await worker.analyze()
            analysisIndicator.cancel()
            if analyzing { analyzing = false }
        }
        writeDiagnostics()
    }
    /// Announces work only once it is slow enough to be worth a spinner; work
    /// that finishes sooner never touches published state.
    private func indicator(_ show: @escaping () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            show()
        }
    }
    private func writeDiagnostics() {
        var report: [String: Any] = ["mode": "jsonl_logs", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", "status": status,
            "updatedAt": ISO8601DateFormatter().string(from: Date()), "processID": ProcessInfo.processInfo.processIdentifier,
            "error": error ?? "", "warnings": warnings]
        if let r = result {
            report["records"] = r.summary.events.count
            report["excludedCodexSessions"] = r.summary.excludedSessions.count
            report["duplicateSnapshots"] = r.summary.duplicates
            report["pendingFiles"] = r.pendingFiles
            report["sources"] = sources.map { source -> [String: Any] in
                let totals = self.totals(for: source)
                return ["source": source.rawValue, "period": period.rawValue, "input": totals.input,
                        "output": totals.output, "total": totals.total, "records": totals.records]
            }
        }
        if let analysis {
            report["analysis"] = ["prompts": analysis.records.filter { $0.kind == .prompt }.count,
                                  "files": analysis.files, "readErrors": analysis.errors,
                                  "skipped": analysis.skipped, "pendingFiles": analysis.pendingFiles]
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("diagnostics.json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Diagnostics must not affect saved usage. */ }
    }
    func openDataFolder() { NSWorkspace.shared.open(directory) }
    func openLogFolder() {
        NSWorkspace.shared.open(selection.tool == .claudeCode ? LogRoots.standard.claude : LogRoots.standard.codex)
    }
}
