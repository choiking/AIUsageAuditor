import Foundation
import CryptoKit

public enum MessageRole: String, Codable { case user, assistant }

public struct VisibleMessage: Equatable {
    public var role: MessageRole
    public var text: String
    public init(_ role: MessageRole, _ text: String) { self.role = role; self.text = text }
    public var fingerprint: String { digest(role.rawValue + "\u{0}" + text) }
}

public func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// One visible message, not a model invocation or a billable API usage record.
public struct UsageEvent: Codable, Identifiable, Equatable {
    public var id: UUID
    public var requestID: UUID
    public var sessionID: String
    /// Missing in v1 ledgers, which contained only ChatGPT events.
    public var appID: AIApp?
    public var app: AIApp { appID ?? .chatgpt }
    public var observedAt: Date
    public var updatedAt: Date
    public var role: MessageRole
    public var visibleTokens: Int
    public var tokenizerID: String
    public var accuracy: String = "estimated"
    public var contentHash: String
    public var cacheCandidateTokens: Int?
    public var model: String?
    public var reasoningLevel: String?

    public init(id: UUID, requestID: UUID, sessionID: String, observedAt: Date, updatedAt: Date,
                role: MessageRole, visibleTokens: Int, tokenizerID: String, contentHash: String,
                cacheCandidateTokens: Int? = nil, model: String? = nil, reasoningLevel: String? = nil, app: AIApp = .chatgpt) {
        self.appID = app
        self.id = id; self.requestID = requestID; self.sessionID = sessionID
        self.observedAt = observedAt; self.updatedAt = updatedAt; self.role = role
        self.visibleTokens = visibleTokens; self.tokenizerID = tokenizerID; self.contentHash = contentHash
        self.cacheCandidateTokens = cacheCandidateTokens; self.model = model; self.reasoningLevel = reasoningLevel
    }
}

public struct UsageTotals: Equatable {
    public var input = 0
    public var output = 0
    public var requests = 0
    public init(events: [UsageEvent]) {
        input = events.filter { $0.role == .user }.reduce(0) { $0 + $1.visibleTokens }
        output = events.filter { $0.role == .assistant }.reduce(0) { $0 + $1.visibleTokens }
        requests = Set(events.filter { $0.role == .user }.map(\.requestID)).count
    }
}

public protocol CacheEstimating {
    /// Return nil when insufficient evidence exists; never interpret nil as zero.
    func candidateTokens(for messages: [VisibleMessage], tokenizer: any TokenCounting) -> Int?
}

public struct UnknownCacheEstimator: CacheEstimating {
    public init() {}
    public func candidateTokens(for messages: [VisibleMessage], tokenizer: any TokenCounting) -> Int? { nil }
}
