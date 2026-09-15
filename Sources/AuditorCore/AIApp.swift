import Foundation

public enum AIApp: String, Codable, CaseIterable, Identifiable {
    case chatgpt, claude
    public var id: String { rawValue }
    public var name: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    public var bundleIdentifier: String {
        self == .chatgpt ? "com.openai.chat" : "com.anthropic.claudefordesktop"
    }
    public init?(bundleIdentifier: String) {
        guard let app = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self = app
    }
    public var configurationFilename: String { self == .chatgpt ? "adapter.json" : "adapter.claude.json" }
    public func scopedSession(_ session: String) -> String {
        // Preserve legacy ChatGPT IDs and deduplication keys on upgrade.
        self == .chatgpt || session.hasPrefix("claude:") ? session : "claude:" + session
    }
}
