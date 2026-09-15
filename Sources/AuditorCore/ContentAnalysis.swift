import Foundation

public enum ContentCategory: String, CaseIterable, Identifiable {
    /// Raw values are stable keys, not display text: they identify the category
    /// in the LogInspector report regardless of the interface language.
    case development, debugging, research, writing, design, planning, other
    public var id: String { rawValue }
    public func name(_ language: AppLanguage = .system) -> String {
        switch self {
        case .development: return language.pick("编程开发", "Coding")
        case .debugging: return language.pick("排错测试", "Debugging & tests")
        case .research: return language.pick("研究问答", "Research & Q&A")
        case .writing: return language.pick("写作翻译", "Writing & translation")
        case .design: return language.pick("设计创作", "Design")
        case .planning: return language.pick("规划管理", "Planning")
        case .other: return language.pick("其他", "Other")
        }
    }
    public var symbol: String {
        switch self {
        case .development: return "chevron.left.forwardslash.chevron.right"
        case .debugging: return "ladybug"
        case .research: return "magnifyingglass"
        case .writing: return "text.alignleft"
        case .design: return "paintpalette"
        case .planning: return "checklist"
        case .other: return "square.grid.2x2"
        }
    }
    public static func classify(_ text: String) -> ContentCategory {
        let text = text.lowercased()
        // Ordered ties favor specific tasks over generic programming vocabulary.
        let rules: [(ContentCategory, [String])] = [
            (.debugging, ["bug", "debug", "fix", "error", "test", "tests", "crash", "failing", "broken", "报错", "排错", "修复", "测试", "故障", "崩溃"]),
            (.writing, ["translate", "translation", "rewrite", "proofread", "summarize", "readme", "essay", "翻译", "润色", "文案", "写作", "总结", "摘要", "文章"]),
            (.design, ["design", "layout", "screenshot", "image", "logo", "css", "mockup", "设计", "界面", "截图", "配色", "图片", "排版"]),
            (.planning, ["plan", "schedule", "roadmap", "organize", "todo", "任务安排", "计划", "规划", "日程", "整理", "待办"]),
            (.development, ["implement", "build", "code", "function", "api", "swift", "python", "javascript", "typescript", "commit", "push", "deploy", "代码", "开发", "实现", "功能", "编译", "部署", "加一个", "添加"]),
            (.research, ["research", "search", "explain", "compare", "why", "what", "how", "调查", "搜索", "解释", "比较", "为什么", "什么", "如何", "分析", "查询"])
        ]
        var best = ContentCategory.other, bestScore = 0
        for (category, keywords) in rules {
            let score = keywords.reduce(0) { score, keyword in
                let matches: Bool
                if keyword.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    matches = text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: keyword) + "\\b", options: .regularExpression) != nil
                } else { matches = text.contains(keyword) }
                return score + (matches ? 1 : 0)
            }
            if score > bestScore { best = category; bestScore = score }
        }
        return best
    }
}

public struct ContentRecord: Identifiable {
    public enum Kind { case prompt, reply, tool, toolError }
    public var id: String
    public var session: String
    public var date: Date
    public var source: LogSource
    public var kind: Kind
    public var text: String = ""
    public var category: ContentCategory = .other
    public var toolName: String = ""
    // Used only to reconcile duplicate Codex event/response representations.
    var eventRepresentation = false
    var textDigest = ""
}

public struct ContentAnalysisResult {
    public var records: [ContentRecord] = []
    public var files = 0
    public var errors = 0
    public var skipped = 0
    public var pendingFiles = 0
    public var checkedAt = Date()
    public init() {}
    public func filtered(today: Bool, now: Date = Date(), calendar: Calendar = .current) -> [ContentRecord] {
        records.filter { !today || calendar.isDate($0.date, inSameDayAs: now) }
    }
}

struct ContentFileState {
    var inode: UInt64 = 0, size: UInt64 = 0, offset: UInt64 = 0
    var modified = Date.distantPast
    var dropping = false
    var session: String
    var source: LogSource
    var skipped = 0
    var internalSession = false
    var records: [String: ContentRecord] = [:]
}

/// An on-demand, in-memory index. Never writes prompts, responses, or paths to disk.
/// Removed files are removed from content history, unlike the numeric usage archive.
public final class ContentAnalysisScanner {
    private let roots: LogRoots
    private var files: [String: ContentFileState] = [:]
    public init(roots: LogRoots = .standard) { self.roots = roots }
    public func scan() -> ContentAnalysisResult {
        var result = ContentAnalysisResult()
        var seen = Set<String>()
        let fm = FileManager.default
        for (root, tool) in [(roots.claude, LogTool.claudeCode), (roots.codex, .codex), (roots.codexArchive, .codex)] {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants], errorHandler: { _, _ in result.errors += 1; return true }) else { result.errors += 1; continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl", tool != .codex || url.lastPathComponent.hasPrefix("rollout-") else { continue }
                let key = digest(tool.rawValue + url.standardizedFileURL.path)
                guard seen.insert(key).inserted else { continue }
                do {
                    let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
                    result.files += 1
                    let attrs = try fm.attributesOfItem(atPath: url.path)
                    let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                    let modified = attrs[.modificationDate] as? Date ?? .distantPast
                    var state = files[key] ?? ContentFileState(session: key, source: tool == .claudeCode ? .claudeUnknown : .codexUnknown)
                    if state.inode != inode || size < state.size || (size == state.size && state.modified != modified) {
                        state = ContentFileState(session: key, source: tool == .claudeCode ? .claudeUnknown : .codexUnknown)
                    }
                    if size > state.offset { try read(url, state: &state, tool: tool, size: size) }
                    state.inode = inode; state.size = size; state.modified = modified
                    files[key] = state
                    if state.offset < size { result.pendingFiles += 1 }
                } catch { result.errors += 1 }
            }
        }
        files = files.filter { seen.contains($0.key) }
        var unique: [String: ContentRecord] = [:]
        for state in files.values {
            result.skipped += state.skipped
            for record in state.records.values {
                // Prefer recognized attribution when an archive copy lacks metadata.
                if let old = unique[record.id], old.source != .claudeUnknown && old.source != .codexUnknown { continue }
                unique[record.id] = record
            }
        }
        let records = Array(unique.values)
        let responses = Dictionary(grouping: records.filter { !$0.eventRepresentation && ($0.kind == .prompt || $0.kind == .reply) },
                                   by: { $0.session + ":" + $0.textDigest })
        result.records = records.filter { r in
            guard r.eventRepresentation else { return true }
            return !(responses[r.session + ":" + r.textDigest] ?? []).contains {
                $0.kind == r.kind && abs($0.date.timeIntervalSince(r.date)) <= 5
            }
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        return result
    }

    private func read(_ url: URL, state: inout ContentFileState, tool: LogTool, size: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        let end = min(size, state.offset + 32 * 1024 * 1024)
        var position = state.offset, line = Data()
        while position < end {
            guard let data = try handle.read(upToCount: Int(min(64 * 1024, end - position))), !data.isEmpty else { break }
            var start = data.startIndex
            while start < data.endIndex {
                let newline = data[start...].firstIndex(of: 10), stop = newline ?? data.endIndex
                if !state.dropping {
                    if line.count + stop - start > 8 * 1024 * 1024 {
                        line.removeAll(); state.dropping = true; state.skipped += 1
                    } else { line.append(contentsOf: data[start..<stop]) }
                }
                if let newline {
                    if !state.dropping && !line.isEmpty { Self.ingest(line, tool: tool, state: &state) }
                    line.removeAll(keepingCapacity: true); state.dropping = false
                    state.offset = position + UInt64(newline + 1); start = newline + 1
                } else { start = data.endIndex }
            }
            position += UInt64(data.count)
            if state.dropping { state.offset = position }
        }
    }

    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    static func ingest(_ data: Data, tool: LogTool, state: inout ContentFileState) {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { state.skipped += 1; return }
        let type = r["type"] as? String ?? ""
        let p = r["payload"] as? [String: Any] ?? [:]
        if tool == .codex && type == "session_meta" {
            if let id = p["id"] as? String ?? p["session_id"] as? String { state.session = digest("codex:" + id) }
            state.source = LogSource.classify(p["originator"] as? String, tool: .codex).0
            state.internalSession = p["thread_source"] as? String == "guardian_review" ||
                (p["source"] as? [String: Any])?["subagent"] != nil
            return
        }
        guard !state.internalSession else { return }
        if tool == .claudeCode {
            if let id = r["sessionId"] as? String { state.session = digest("claude:" + id) }
            if let origin = r["entrypoint"] as? String { state.source = LogSource.classify(origin, tool: .claudeCode).0 }
        }
        guard let timestamp = r["timestamp"] as? String,
              let date = isoFraction.date(from: timestamp) ?? iso.date(from: timestamp) else { return }
        func record(_ kind: ContentRecord.Kind, key: String, text: String = "", name: String = "", event: Bool = false) -> ContentRecord {
            let cleaned = kind == .prompt ? cleanPrompt(text) : text
            let preview = String(cleaned.prefix(12_000))
            return ContentRecord(id: digest(tool.rawValue + ":" + key), session: state.session, date: date,
                source: state.source, kind: kind, text: kind == .prompt ? preview : "",
                category: kind == .prompt ? ContentCategory.classify(preview) : .other,
                toolName: String(name.prefix(120)), eventRepresentation: event, textDigest: digest(cleaned))
        }
        var additions: [ContentRecord] = []
        if tool == .claudeCode {
            let m = r["message"] as? [String: Any] ?? [:]
            let blocks = m["content"] as? [[String: Any]] ?? []
            let text = m["content"] as? String ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let key = r["uuid"] as? String ?? (state.session + timestamp + digest(text))
            if type == "user", r["isSidechain"] as? Bool != true, r["isMeta"] as? Bool != true,
               !blocks.contains(where: { $0["type"] as? String == "tool_result" }), !text.isEmpty {
                let origin = r["origin"] as? [String: Any]
                if origin == nil || origin?["kind"] as? String == "human" { additions.append(record(.prompt, key: key, text: text)) }
            }
            if type == "assistant" {
                let messageID = m["id"] as? String ?? key
                if m["model"] as? String != "<synthetic>" {
                    additions.append(record(.reply, key: "reply:" + messageID))
                }
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    additions.append(record(.tool, key: "tool:" + id, name: name))
                }
            }
            for block in blocks where block["type"] as? String == "tool_result" && block["is_error"] as? Bool == true {
                if let id = block["tool_use_id"] as? String { additions.append(record(.toolError, key: "error:" + id)) }
            }
        } else {
            let subtype = p["type"] as? String ?? ""
            if type == "event_msg", subtype == "user_message" || subtype == "agent_message" {
                let text = p["message"] as? String ?? ""
                if !text.isEmpty {
                    additions.append(record(subtype == "user_message" ? .prompt : .reply,
                        key: state.session + ":event:" + subtype + timestamp + digest(text), text: text, event: true))
                }
            }
            if type == "response_item" {
                let id = p["id"] as? String ?? (state.session + timestamp + digest(String(data: data, encoding: .utf8) ?? ""))
                if subtype == "message", let role = p["role"] as? String, role == "user" || role == "assistant" {
                    let blocks = p["content"] as? [[String: Any]] ?? []
                    let text = blocks.filter { ["input_text", "output_text", "text"].contains($0["type"] as? String ?? "") }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { additions.append(record(role == "user" ? .prompt : .reply, key: "message:" + id, text: text)) }
                }
                if subtype == "function_call" || subtype == "custom_tool_call" {
                    if let name = p["name"] as? String {
                        additions.append(record(.tool, key: "tool:" + (p["call_id"] as? String ?? id), name: name))
                    }
                }
                // Codex tool output schemas vary; never infer failure from text such as "error".
            }
        }
        for item in additions where item.kind != .prompt || !item.text.isEmpty { state.records[item.id] = item }
    }

    static func cleanPrompt(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["[Request interrupted by user]", "[Request interrupted by user for tool use]"].contains(value) { return "" }
        if value.hasPrefix("The following is the Codex agent history whose request action you are assessing.") { return "" }
        // Remove known client context wrappers, never interpret their contents as instructions.
        for tag in ["environment_context", "recommended_plugins", "permissions instructions", "system-reminder", "skills_instructions"] {
            let escaped = NSRegularExpression.escapedPattern(for: tag)
            value = value.replacingOccurrences(of: "(?s)<" + escaped + ">.*?</" + escaped + ">", with: "", options: .regularExpression)
        }
        if value.hasPrefix("# AGENTS.md instructions") || value.hasPrefix("<turn_aborted>") || value.hasPrefix("<local-command-") { return "" }
        if let range = value.range(of: "## My request:") { value = String(value[range.upperBound...]) }
        if value.hasPrefix("<send_user_message_question_reply>"),
           let end = value.range(of: "</send_user_message_question_reply>") {
            let body = value.replacingOccurrences(of: "<send_user_message_question_reply>", with: "")
            let raw = String(body.prefix(body.count - value[end.lowerBound...].count))
            if let data = raw.data(using: .utf8), let answers = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                value = answers.compactMap { $0["answer"] as? String }.joined(separator: "\n")
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
