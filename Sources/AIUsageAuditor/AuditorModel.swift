import SwiftUI
import AppKit
import AuditorCore
import Darwin

private actor LogWorker {
    private var scanner: LogScanner?
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

enum LogPeriod: String, CaseIterable { case today = "今日", all = "已导入历史" }

@MainActor
final class AuditorModel: ObservableObject {
    static let shared = AuditorModel()
    @Published var period: LogPeriod = .today
    @Published var selectedSource: LogSource = .codexDesktop
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
    var totals: LogTotals { LogTotals(events: filtered()) }
    var today: LogTotals { LogTotals(events: filtered(today: true)) }
    func totals(for source: LogSource) -> LogTotals { LogTotals(events: filtered(source)) }
    var selectedTotals: LogTotals { totals(for: selectedSource) }
    var lastUsage: Date? { events.filter { $0.source == selectedSource }.map(\.observedAt).max() }
    var provenance: String {
        let values = Set(events.filter { $0.source == selectedSource }.map(\.provenance)).sorted()
        let key = selectedSource.tool == .claudeCode ? "entrypoint" : "originator"
        return key + " = " + (values.isEmpty ? "未发现记录" : values.joined(separator: ", "))
    }
    var menuTitle: String {
        guard result != nil else { return error == nil ? "◌ Logs" : "! Logs" }
        return "\(error == nil ? "" : "! ")↑\(today.input.formatted(.number.notation(.compactName))) ↓\(today.output.formatted(.number.notation(.compactName)))"
    }
    var status: String {
        if error != nil { return "采集失败 · 显示上次成功结果" }
        if demo { return "演示模式 · 模拟日志数据" }
        if scanning { return "正在读取本地日志…" }
        if paused { return "采集已暂停 · 恢复后补读日志" }
        if result == nil { return "等待首次导入" }
        if result!.filesByTool.values.reduce(0, +) == 0 { return "未发现日志 · 仅显示已保存历史" }
        return "日志采集中 · 每 5 秒检查新增记录"
    }
    var warnings: [String] {
        guard let r = result else { return [] }
        var lines: [String] = []
        if !r.summary.excludedSessions.isEmpty { lines.append("\(r.summary.excludedSessions.count) 个 Codex 会话的计数出现回退，已排除；当前合计不完整。") }
        if r.errors > 0 { lines.append("\(r.errors) 处日志无法读取，本轮结果可能不完整。") }
        if r.incompleteUsage + r.summary.ambiguousMessages > 0 {
            lines.append("\(r.incompleteUsage) 条用量字段不完整，\(r.summary.ambiguousMessages) 条消息快照冲突，已跳过。")
        }
        if r.invalidLines > 0 { lines.append("已跳过 \(r.invalidLines) 条无效或过长记录。") }
        let unallocated = events.filter { $0.occurredAt == nil }.count
        if unallocated > 0 { lines.append("\(unallocated) 条历史累计记录无法确定发生日期，仅计入历史合计。") }
        return lines
    }

    init() {
        demo = ProcessInfo.processInfo.arguments.contains("--demo")
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
                self.clock = Date()
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
        guard !scanning else { return }
        scanning = true
        do { result = try await worker.scan(directory: directory); error = nil }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "日志读取失败。" }
        scanning = false
        writeDiagnostics()
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("diagnostics.json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Diagnostics must not affect saved usage. */ }
    }
    func openDataFolder() { NSWorkspace.shared.open(directory) }
    func openLogFolder() {
        NSWorkspace.shared.open(selectedSource.tool == .claudeCode ? LogRoots.standard.claude : LogRoots.standard.codex)
    }
}
