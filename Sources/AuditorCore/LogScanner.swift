import Foundation

public struct LogArchive: Codable, Equatable {
    public var schemaVersion = 1
    public var files: [String: LogFileState] = [:]
    public init() {}
}

public struct LogRoots {
    public var claude: URL
    public var codex: URL
    public var codexArchive: URL
    public init(claude: URL, codex: URL, codexArchive: URL) {
        self.claude = claude; self.codex = codex; self.codexArchive = codexArchive
    }
    public static var standard: LogRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let claude = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        let codex = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return LogRoots(claude: claude.appendingPathComponent("projects"),
            codex: codex.appendingPathComponent("sessions"), codexArchive: codex.appendingPathComponent("archived_sessions"))
    }
}

public struct LogScanResult {
    public var summary: LogSummary
    public var filesByTool: [LogTool: Int]
    public var errors: Int
    public var invalidLines: Int
    public var incompleteUsage: Int
    public var pendingFiles: Int
    public var checkedAt: Date
    public var changed: Bool
    public init(summary: LogSummary, filesByTool: [LogTool: Int], errors: Int, invalidLines: Int,
                incompleteUsage: Int, pendingFiles: Int, checkedAt: Date, changed: Bool) {
        self.summary = summary; self.filesByTool = filesByTool; self.errors = errors
        self.invalidLines = invalidLines; self.incompleteUsage = incompleteUsage; self.pendingFiles = pendingFiles
        self.checkedAt = checkedAt; self.changed = changed
    }
}

/// Stores numeric records, hashes and read checkpoints, never JSONL bodies or paths.
/// The full snapshot is replaced atomically. Rebuilding never appends to old totals.
public final class LogScanner {
    public let roots: LogRoots
    public private(set) var archive: LogArchive
    private let storeURL: URL?
    private var cachedSummary: LogSummary?
    public init(roots: LogRoots = .standard, storeURL: URL? = nil) throws {
        self.roots = roots; self.storeURL = storeURL
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                archive = try JSONDecoder().decode(LogArchive.self, from: Data(contentsOf: storeURL))
                guard archive.schemaVersion == 1 else { throw LogScanError.unsupportedStore }
            } catch { throw LogScanError.unreadableStore }
        } else { archive = LogArchive() }
    }
    public func scan() throws -> LogScanResult {
        var next = archive
        var counts: [LogTool: Int] = [.claudeCode: 0, .codex: 0]
        var errors = 0, pending = 0
        let manager = FileManager.default
        var visited: Set<String> = []
        for (root, tool) in [(roots.claude, LogTool.claudeCode), (roots.codex, .codex), (roots.codexArchive, .codex)] {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants], errorHandler: { _, _ in errors += 1; return true }) else { errors += 1; continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl", tool != .codex || url.lastPathComponent.hasPrefix("rollout-") else { continue }
                do {
                    let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
                    let key = digest(tool.rawValue + "\u{0}" + url.standardizedFileURL.path)
                    guard visited.insert(key).inserted else { continue }
                    counts[tool, default: 0] += 1
                    let attributes = try manager.attributesOfItem(atPath: url.path)
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let modified = attributes[.modificationDate] as? Date ?? .distantPast
                    var state = next.files[key] ?? LogFileState(tool: tool)
                    if state.inode != inode || size < state.size || (size == state.size && modified != state.modified) {
                        state = LogFileState(tool: tool)
                    }
                    if size > state.offset {
                        try Self.read(url, state: &state, availableSize: size)
                    }
                    state.inode = inode; state.size = size; state.modified = modified
                    if state.offset < size { pending += 1 }
                    next.files[key] = state
                } catch { errors += 1 }
            }
        }
        // Retain sanitized history when source logs are rotated/deleted. Moved copies
        // are deduplicated by request/event identity rather than by their paths.
        let changed = next != archive
        if changed, let storeURL {
            do {
                try manager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(next)
                try data.write(to: storeURL, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            } catch { throw LogScanError.writeFailed }
        }
        archive = next
        let files = Array(archive.files.values)
        if changed || cachedSummary == nil { cachedSummary = LogSummary.build(files.flatMap(\.records)) }
        return LogScanResult(summary: cachedSummary!, filesByTool: counts,
            errors: errors, invalidLines: files.reduce(0) { $0 + $1.invalidLines },
            incompleteUsage: files.reduce(0) { $0 + $1.incompleteUsage }, pendingFiles: pending,
            checkedAt: Date(), changed: changed)
    }

    private static func read(_ url: URL, state: inout LogFileState, availableSize: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        let limit = 8 * 1024 * 1024
        // Limit work per file per scan; remaining bytes are picked up next time.
        let budget: UInt64 = 32 * 1024 * 1024
        let end = min(availableSize, state.offset + budget)
        var readPosition = state.offset
        var line = Data()
        while readPosition < end {
            guard let data = try handle.read(upToCount: Int(min(64 * 1024, end - readPosition))), !data.isEmpty else { break }
            var start = data.startIndex
            while start < data.endIndex {
                let newline = data[start...].firstIndex(of: 10)
                let stop = newline ?? data.endIndex
                if !state.droppingLongLine {
                    if line.count + stop - start > limit {
                        line.removeAll(keepingCapacity: false)
                        state.droppingLongLine = true; state.invalidLines += 1
                    } else { line.append(contentsOf: data[start..<stop]) }
                }
                if let newline {
                    if !state.droppingLongLine && !line.isEmpty { LogParser.ingest(line, state: &state) }
                    line.removeAll(keepingCapacity: true); state.droppingLongLine = false
                    state.offset = readPosition + UInt64(newline + 1)
                    start = newline + 1
                } else { start = data.endIndex }
            }
            readPosition += UInt64(data.count)
            if state.droppingLongLine { state.offset = readPosition }
        }
        // A partial line is intentionally not checkpointed; reread it after append.
    }
}

public enum LogScanError: LocalizedError {
    case unsupportedStore, unreadableStore, writeFailed, writerRunning
    public var errorDescription: String? {
        switch self {
        case .unsupportedStore, .unreadableStore: return "日志账本损坏或版本不支持；原文件已保留。"
        case .writeFailed: return "日志账本保存失败；未发布本轮计数。"
        case .writerRunning: return "已有 Auditor 实例正在写入日志账本。请关闭另一个实例。"
        }
    }
}
