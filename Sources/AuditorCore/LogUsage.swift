import Foundation
import CoreFoundation

public enum LogTool: String, Codable, CaseIterable, Identifiable {
    case claudeCode, codex
    public var id: String { rawValue }
    /// Top-level grouping label; the per-entrypoint rows sit under it.
    public var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
    /// The entrypoint field this tool records its origin in.
    public var provenanceKey: String {
        switch self {
        case .claudeCode: return "entrypoint"
        case .codex: return "originator"
        }
    }
}
public enum LogSource: String, Codable, CaseIterable, Identifiable {
    case claudeDesktop, claudeCLI, claudeIDE, claudeSDK, claudeUnknown
    case codexDesktop, codexCLI, codexIDE, codexSDK, codexBrowser, codexUnknown
    public var id: String { rawValue }
    public var tool: LogTool { rawValue.hasPrefix("claude") ? .claudeCode : .codex }
    public var name: String {
        switch self {
        case .claudeDesktop: return "Claude Code · Desktop"
        case .claudeCLI: return "Claude Code · CLI"
        case .claudeIDE: return "Claude Code · IDE"
        case .claudeSDK: return "Claude Code · SDK"
        case .claudeUnknown: return "Claude Code · 来源未知"
        case .codexDesktop: return "Codex · Desktop"
        case .codexCLI: return "Codex · CLI / Exec"
        case .codexIDE: return "Codex · VS Code"
        case .codexSDK: return "Codex · SDK"
        case .codexBrowser: return "Codex · 浏览器扩展"
        case .codexUnknown: return "Codex · 来源未知"
        }
    }
    public static func classify(_ value: String?, tool: LogTool) -> (LogSource, String) {
        // originator is authoritative; source=vscode alone does not prove IDE origin.
        let mapping: [String: LogSource] = tool == .claudeCode ? [
            "claude-desktop": .claudeDesktop, "cli": .claudeCLI,
            "claude-vscode": .claudeIDE, "vscode": .claudeIDE,
            "sdk-cli": .claudeSDK, "sdk": .claudeSDK
        ] : [
            "Codex Desktop": .codexDesktop, "codex_work_desktop": .codexDesktop,
            "codex_cli_rs": .codexCLI, "codex-tui": .codexCLI, "codex_exec": .codexCLI,
            "codex_vscode": .codexIDE, "codex_sdk_ts": .codexSDK,
            "codex-chrome-extension-sidepanel": .codexBrowser
        ]
        if let value, let source = mapping[value] { return (source, value) }
        return (tool == .claudeCode ? .claudeUnknown : .codexUnknown, "未提供或未识别")
    }
}

public struct LogTokens: Codable, Equatable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64? = nil
    public var cacheWrite: Int64? = nil
    public var reasoning: Int64? = nil
    public var total: Int64 = 0
    /// Subset of `cacheWrite` written with a 1-hour TTL, which bills at 2x base
    /// input instead of 1.25x. nil when the log did not report the split.
    public var cacheWrite1h: Int64? = nil
    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64? = nil,
                cacheWrite: Int64? = nil, reasoning: Int64? = nil, total: Int64 = 0,
                cacheWrite1h: Int64? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.reasoning = reasoning; self.total = total
        self.cacheWrite1h = cacheWrite1h
    }
    static func number(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let d = value.doubleValue
        guard d.isFinite, d >= 0, d <= 1_000_000_000_000, d.rounded() == d else { return nil }
        return value.int64Value
    }
    static func parse(_ object: Any?, tool: LogTool) -> LogTokens? {
        guard let u = object as? [String: Any], let input = number(u["input_tokens"]),
              let output = number(u["output_tokens"]) else { return nil }
        let readKey = tool == .claudeCode ? "cache_read_input_tokens" : "cached_input_tokens"
        let writeKey = tool == .claudeCode ? "cache_creation_input_tokens" : "cache_write_input_tokens"
        for key in [readKey, writeKey, "reasoning_output_tokens"] where u[key] != nil {
            guard number(u[key]) != nil else { return nil }
        }
        let read = number(u[readKey]), write = number(u[writeKey])
        if tool == .claudeCode {
            guard let read, let write else { return nil }
            // Only trust the split when it is present and consistent with the total.
            var write1h: Int64? = nil
            if let creation = u["cache_creation"] as? [String: Any],
               let long = number(creation["ephemeral_1h_input_tokens"]), long <= write {
                write1h = long
            }
            return LogTokens(input: input + read + write, output: output, cacheRead: read,
                             cacheWrite: write, total: input + read + write + output,
                             cacheWrite1h: write1h)
        }
        guard let total = number(u["total_tokens"]) else { return nil }
        return LogTokens(input: input, output: output, cacheRead: read, cacheWrite: write,
                         reasoning: number(u["reasoning_output_tokens"]), total: total)
    }
    func regresses(from p: LogTokens) -> Bool {
        input < p.input || output < p.output || total < p.total ||
        zip([cacheRead, cacheWrite, reasoning], [p.cacheRead, p.cacheWrite, p.reasoning]).contains {
            if let a = $0.0, let b = $0.1 { return a < b }; return false
        }
    }
    func delta(from p: LogTokens) -> LogTokens {
        func subtract(_ a: Int64?, _ b: Int64?) -> Int64? {
            guard let a else { return nil }; return a - (b ?? 0)
        }
        return LogTokens(input: input - p.input, output: output - p.output,
                         cacheRead: subtract(cacheRead, p.cacheRead), cacheWrite: subtract(cacheWrite, p.cacheWrite),
                         reasoning: subtract(reasoning, p.reasoning), total: total - p.total)
    }
    var fingerprint: String {
        [Optional(input), output, cacheRead, cacheWrite, reasoning, total]
            .map { $0.map(String.init) ?? "?" }.joined(separator: ":")
    }
}

public struct LogRecord: Codable, Equatable {
    public var key: String
    public var session: String
    public var time: Date
    public var source: LogSource
    public var provenance: String
    public var tokens: LogTokens
    public var last: LogTokens?
    /// Model string as recorded in the log; nil when it was absent.
    public var model: String?
    public init(key: String, session: String, time: Date, source: LogSource,
                provenance: String, tokens: LogTokens, last: LogTokens? = nil,
                model: String? = nil) {
        self.key = key; self.session = session; self.time = time; self.source = source
        self.provenance = provenance; self.tokens = tokens; self.last = last
        self.model = model
    }
}

public struct LogFileState: Codable, Equatable {
    public var tool: LogTool
    public var offset: UInt64 = 0
    public var inode: UInt64 = 0
    public var size: UInt64 = 0
    public var modified: Date = .distantPast
    public var droppingLongLine = false
    public var session: String?
    public var source: LogSource
    public var provenance = "未提供或未识别"
    /// Codex records the model per turn, not per usage event.
    public var model: String?
    public var records: [LogRecord] = []
    public var invalidLines = 0
    public var incompleteUsage = 0
    public init(tool: LogTool) {
        self.tool = tool; source = tool == .claudeCode ? .claudeUnknown : .codexUnknown
    }
}

public enum LogParser {
    public static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.count <= 40 else { return nil }
        // ISO8601DateFormatter accepts Z or an explicit offset. Reject local-only dates.
        guard text.hasSuffix("Z") || text.dropFirst(10).contains("+") || text.dropFirst(10).contains("-") else { return nil }
        return fractional.date(from: text) ?? ordinary.date(from: text)
    }
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let ordinary = ISO8601DateFormatter()
    public static func ingest(_ data: Data, state: inout LogFileState) {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            state.invalidLines += 1; return
        }
        if state.tool == .claudeCode {
            guard r["type"] as? String == "assistant", let m = r["message"] as? [String: Any], m["usage"] != nil else { return }
            guard let time = date(r["timestamp"]), let request = r["requestId"] as? String, !request.isEmpty,
                  let message = m["id"] as? String, !message.isEmpty, let tokens = LogTokens.parse(m["usage"], tool: .claudeCode) else {
                state.incompleteUsage += 1; return
            }
            let (source, provenance) = LogSource.classify(r["entrypoint"] as? String, tool: .claudeCode)
            let model = (m["model"] as? String).flatMap { $0.isEmpty || $0 == "<synthetic>" ? nil : $0 }
            state.records.append(LogRecord(key: digest("claude\u{0}" + request + "\u{0}" + message),
                session: digest("claude\u{0}" + (r["sessionId"] as? String ?? "unknown")), time: time,
                source: source, provenance: provenance, tokens: tokens, model: model))
        } else {
            guard let payload = r["payload"] as? [String: Any] else { return }
            if r["type"] as? String == "session_meta" {
                if let id = (payload["id"] ?? payload["session_id"]) as? String, !id.isEmpty {
                    state.session = digest("codex\u{0}" + id)
                }
                (state.source, state.provenance) = LogSource.classify(payload["originator"] as? String, tool: .codex)
            }
            if r["type"] as? String == "turn_context", let model = payload["model"] as? String, !model.isEmpty {
                state.model = model
            }
            guard r["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { return }
            guard let session = state.session, let time = date(r["timestamp"]),
                  let tokens = LogTokens.parse(info["total_token_usage"], tool: .codex) else {
                state.incompleteUsage += 1; return
            }
            let last = LogTokens.parse(info["last_token_usage"], tool: .codex)
            let key = digest("codex\u{0}\(time.timeIntervalSince1970)\u{0}\(tokens.fingerprint)\u{0}\(last?.fingerprint ?? "?")")
            state.records.append(LogRecord(key: key, session: session, time: time, source: state.source,
                provenance: state.provenance, tokens: tokens, last: last, model: state.model))
        }
    }
}

public struct LogEvent: Codable, Identifiable, Equatable {
    public var id: String
    public var source: LogSource
    public var provenance: String
    public var observedAt: Date
    /// nil for inherited/pruned cumulative history without a known invocation date.
    public var occurredAt: Date?
    public var tokens: LogTokens
    /// Model string as recorded in the log; nil when it was absent.
    public var model: String?
    public init(id: String, source: LogSource, provenance: String, observedAt: Date,
                occurredAt: Date?, tokens: LogTokens, model: String? = nil) {
        self.id = id; self.source = source; self.provenance = provenance; self.observedAt = observedAt
        self.occurredAt = occurredAt; self.tokens = tokens; self.model = model
    }
}

public struct LogSummary {
    public var events: [LogEvent] = []
    public var excludedSessions: Set<String> = []
    public var ambiguousMessages = 0
    public var duplicates = 0
    public init() {}
    public static func build(_ records: [LogRecord]) -> LogSummary {
        var result = LogSummary()
        var claude: [String: LogRecord] = [:]
        var ambiguous: Set<String> = []
        for r in records where r.source.tool == .claudeCode {
            if let p = claude[r.key] {
                result.duplicates += 1
                if r.time < p.time { continue }
                if r.time == p.time {
                    if r.tokens != p.tokens || r.source != p.source { ambiguous.insert(r.key) }
                    continue
                }
            }
            ambiguous.remove(r.key); claude[r.key] = r
        }
        result.ambiguousMessages = ambiguous.count
        for r in claude.values where !ambiguous.contains(r.key) {
            result.events.append(LogEvent(id: r.key, source: r.source, provenance: r.provenance,
                observedAt: r.time, occurredAt: r.time, tokens: r.tokens, model: r.model))
        }
        let groups = Dictionary(grouping: records.filter { $0.source.tool == .codex }, by: \.session)
        var candidates: [LogEvent] = []
        for (session, rows) in groups {
            var previous = LogTokens()
            var pending: [LogEvent] = []
            var seen: Set<String> = []
            var isFirst = true
            for r in rows.sorted(by: { $0.time == $1.time ? $0.key < $1.key : $0.time < $1.time }) {
                guard seen.insert(r.key).inserted else { result.duplicates += 1; continue }
                if r.tokens.regresses(from: previous) { result.excludedSessions.insert(session) }
                let delta = r.tokens.delta(from: previous)
                // An initial cumulative total may include copied or pruned history.
                let knownDate = !isFirst || (r.last?.input == r.tokens.input &&
                    r.last?.output == r.tokens.output && r.last?.total == r.tokens.total)
                previous = r.tokens; isFirst = false
                guard delta.input != 0 || delta.output != 0 || delta.total != 0 else { result.duplicates += 1; continue }
                pending.append(LogEvent(id: r.key, source: r.source, provenance: r.provenance,
                    observedAt: r.time, occurredAt: knownDate ? r.time : nil, tokens: delta, model: r.model))
            }
            if !result.excludedSessions.contains(session) { candidates.append(contentsOf: pending) }
        }
        var seen: Set<String> = []
        for e in candidates.sorted(by: { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }) {
            if seen.insert(e.id).inserted { result.events.append(e) } else { result.duplicates += 1 }
        }
        result.events.sort { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }
        return result
    }
}

public struct LogTotals {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var total: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var reasoning: Int64 = 0
    public var records = 0
    public var missingCache = false
    public var missingReasoning = false
    public init(events: [LogEvent]) {
        for e in events {
            input += e.tokens.input; output += e.tokens.output; total += e.tokens.total
            cacheRead += e.tokens.cacheRead ?? 0; cacheWrite += e.tokens.cacheWrite ?? 0
            reasoning += e.tokens.reasoning ?? 0; records += 1
            missingCache = missingCache || e.tokens.cacheRead == nil || e.tokens.cacheWrite == nil
            missingReasoning = missingReasoning || e.tokens.reasoning == nil
        }
    }
}
