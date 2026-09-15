import Foundation

/// Serializable, platform-independent snapshot, also used for fixture testing.
public struct AXNode: Codable, Equatable {
    public var role: String
    public var identifier: String
    public var label: String
    public var value: String
    public var document: String
    public var children: [AXNode]
    public init(role: String = "AXGroup", identifier: String = "", label: String = "",
                value: String = "", document: String = "", children: [AXNode] = []) {
        self.role = role; self.identifier = identifier; self.label = label
        self.value = value; self.document = document; self.children = children
    }
}

public struct NodeRule: Codable {
    public var roles: [String]
    public var identifierPattern: String?
    public var labelPattern: String?
    public init(roles: [String] = [], identifierPattern: String? = nil, labelPattern: String? = nil) {
        self.roles = roles; self.identifierPattern = identifierPattern; self.labelPattern = labelPattern
    }
    public func matches(_ node: AXNode) -> Bool {
        if !roles.isEmpty && !roles.contains(node.role) { return false }
        let patterns = [(identifierPattern, node.identifier), (labelPattern, node.label)]
        let supplied = patterns.filter { $0.0 != nil }
        // A role-only rule is allowed; empty rules match nothing.
        if supplied.isEmpty { return !roles.isEmpty }
        return supplied.contains { pattern, value in
            guard let pattern, let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
    }
}

public struct AdapterConfiguration: Codable {
    public var bundleIdentifier = "com.openai.chat"
    public var userRules: [NodeRule] = [
        NodeRule(identifierPattern: "(?i)^(user[-_]message|message[-_]user)([-_:].*)?$"),
        NodeRule(roles: ["AXGroup"], labelPattern: "(?i)^(you said|你说)[:：]?$")
    ]
    public var assistantRules: [NodeRule] = [
        NodeRule(identifierPattern: "(?i)^(assistant[-_]message|message[-_]assistant)([-_:].*)?$"),
        NodeRule(roles: ["AXGroup"], labelPattern: "(?i)^(chatgpt said|ChatGPT 说)[:：]?$")
    ]
    public var generationRules: [NodeRule] = [
        NodeRule(roles: ["AXButton"], labelPattern: "(?i)^(stop generating|stop response|停止生成|停止回答)$")
    ]
    /// Leave empty only if the window contains exclusively conversation content.
    public var conversationRules: [NodeRule] = []
    public var excludedRoles = ["AXTextArea", "AXTextField", "AXComboBox", "AXButton", "AXMenu", "AXToolbar"]
    public var textRoles = ["AXStaticText"]
    public var maxDepth = 40
    public var maxNodes = 6000
    public var pollInterval: Double = 1.5
    public var settlingSeconds: Double = 3
    public var app: AIApp? { AIApp(bundleIdentifier: bundleIdentifier) }
    public init(app: AIApp = .chatgpt) {
        bundleIdentifier = app.bundleIdentifier
        if app == .claude {
            // Observed desktop AX structure: Chat messages > Message N of M > role heading + body.
            conversationRules = [NodeRule(roles: ["AXGroup"], labelPattern: "^Chat messages$")]
            userRules = [NodeRule(roles: ["AXHeading"], labelPattern: "(?i)^You said:")]
            assistantRules = [NodeRule(roles: ["AXHeading"], labelPattern: "(?i)^Claude responded:")]
            generationRules = [NodeRule(roles: ["AXButton"], labelPattern: "(?i)^(stop response|stop generating|停止生成|停止回答)$")]
        }
    }
    public func validate() throws {
        guard app != nil, maxDepth > 0, maxDepth <= 80,
              maxNodes > 0, maxNodes <= 20000, pollInterval >= 0.5, pollInterval <= 30,
              settlingSeconds >= 1, settlingSeconds <= 30, !userRules.isEmpty, !assistantRules.isEmpty,
              textRoles.allSatisfy({ $0 == "AXStaticText" || $0 == "AXHeading" }) else {
            throw MatchingError.invalidConfiguration
        }
        for rule in userRules + assistantRules + generationRules + conversationRules {
            for pattern in [rule.identifierPattern, rule.labelPattern].compactMap({ $0 }) {
                guard pattern.count < 512 else { throw MatchingError.invalidConfiguration }
                _ = try NSRegularExpression(pattern: pattern)
            }
        }
    }
}

public enum MatchingError: Error, LocalizedError {
    case invalidConfiguration, ambiguousRoles, multipleConversations, unrecognizedMessage
    public var errorDescription: String? {
        switch self {
        case .unrecognizedMessage: return "无法确认消息角色；请校准匹配配置。"
        case .invalidConfiguration: return "匹配配置无效；请检查范围、bundle ID 和正则表达式。"
        case .ambiguousRoles: return "同一节点匹配到多个消息角色；已停止本次计数。"
        case .multipleConversations: return "匹配到多个会话容器；请收紧 conversationRules。"
        }
    }
}

public struct ParsedConversation {
    public var messages: [VisibleMessage]
    public var documentID: String?
    public var isGenerating: Bool
}

public typealias ChatGPTMatcher = ConversationMatcher

public struct ConversationMatcher {
    public let configuration: AdapterConfiguration
    public init(configuration: AdapterConfiguration = .init()) { self.configuration = configuration }
    public func parse(_ root: AXNode) throws -> ParsedConversation {
        try configuration.validate()
        let app = configuration.app!
        var documentIDs = Set<String>()
        var generating = false
        func metadata(_ node: AXNode) {
            if let url = URL(string: node.document),
               (app == .chatgpt ? ["chatgpt.com", "chat.openai.com"] : ["claude.ai"]).contains(url.host ?? ""),
               let index = url.pathComponents.firstIndex(of: app == .chatgpt ? "c" : "chat"), url.pathComponents.count > index + 1 {
                documentIDs.insert(digest(url.pathComponents[index + 1]))
            }
            if configuration.generationRules.contains(where: { $0.matches(node) }) { generating = true }
            // AX snapshots do not contain editable values, but also skip their descendants.
            if ["AXTextArea", "AXTextField", "AXComboBox"].contains(node.role) { return }
            node.children.forEach(metadata)
        }
        metadata(root)
        guard documentIDs.count <= 1 else { throw MatchingError.multipleConversations }
        var scopes: [AXNode] = []
        func findScope(_ node: AXNode) {
            if configuration.conversationRules.contains(where: { $0.matches(node) }) { scopes.append(node); return }
            node.children.forEach(findScope)
        }
        if configuration.conversationRules.isEmpty { scopes = [root] } else { findScope(root) }
        guard scopes.count <= 1 else { throw MatchingError.multipleConversations }
        var messages: [VisibleMessage] = []
        func collectText(_ node: AXNode) -> [String] {
            if configuration.excludedRoles.contains(node.role) { return [] }
            if node.role == "AXLink", node.children.isEmpty, !node.label.isEmpty { return [node.label] }
            if configuration.textRoles.contains(node.role) {
                let text = node.value.isEmpty ? node.label : node.value
                // Prefer a text node's own value over its duplicate text descendants.
                if !text.isEmpty { return [text] }
            }
            return node.children.flatMap(collectText)
        }
        func visit(_ node: AXNode) throws {
            if configuration.excludedRoles.contains(node.role) { return }
            if app == .claude {
                // Do not use message order to guess roles. Only the first accessibility
                // heading of a numbered message establishes its role; exclude that
                // preview heading from text to avoid counting the opening words twice.
                let messageRule = NodeRule(roles: ["AXGroup"], labelPattern: "^Message [0-9]+ of [0-9]+$")
                if messageRule.matches(node) {
                    let content: AXNode
                    if let first = node.children.first, first.role == "AXHeading" { content = node }
                    else if let first = node.children.first, first.children.first?.role == "AXHeading" { content = first }
                    else { throw MatchingError.unrecognizedMessage }
                    guard let heading = content.children.first else { throw MatchingError.unrecognizedMessage }
                    let user = configuration.userRules.contains { $0.matches(heading) }
                    let assistant = configuration.assistantRules.contains { $0.matches(heading) }
                    guard user != assistant else {
                        throw user ? MatchingError.ambiguousRoles : MatchingError.unrecognizedMessage
                    }
                    let text = content.children.dropFirst().flatMap(collectText).joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { messages.append(VisibleMessage(user ? .user : .assistant, text)) }
                    return
                }
                try node.children.forEach(visit)
                return
            }
            let user = configuration.userRules.contains { $0.matches(node) }
            let assistant = configuration.assistantRules.contains { $0.matches(node) }
            if user && assistant { throw MatchingError.ambiguousRoles }
            if user || assistant {
                let text = collectText(node).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { messages.append(VisibleMessage(user ? .user : .assistant, text)) }
                return
            }
            try node.children.forEach(visit)
        }
        if let scope = scopes.first { try visit(scope) }
        return ParsedConversation(messages: messages, documentID: documentIDs.first, isGenerating: generating)
    }
}
