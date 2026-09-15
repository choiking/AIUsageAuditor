import Foundation

/// Conservative append-only tracker. Opening history is a baseline, not new usage.
/// Text stays in memory; the ledger stores only hashes and counts.
public struct MessageTracker {
    private var sessionID: String?
    private var previous: [VisibleMessage] = []
    private var bindings: [Int: UUID] = [:]
    private var requestID: UUID?
    private var changedAt: [Int: Date] = [:]
    private var firstSeen: [Int: Date] = [:]
    private var candidate: [VisibleMessage]?
    private var candidateAt: Date?
    private let settling: TimeInterval
    public private(set) var status = "等待消息基线"

    public init(settling: TimeInterval = 3) { self.settling = settling }
    public mutating func suspend() {
        sessionID = nil; previous = []; bindings = [:]; requestID = nil
        changedAt = [:]; firstSeen = [:]; candidate = nil; candidateAt = nil
    }

    public mutating func ingest(session rawSession: String, messages: [VisibleMessage], isGenerating: Bool,
                                now: Date, ledger: inout Ledger, tokenizer: any TokenCounting,
                                cacheEstimator: any CacheEstimating = UnknownCacheEstimator(), app: AIApp = .chatgpt) {
        let session = app.scopedSession(rawSession)
        var occurrences: [String: Int] = [:]
        var userKeys: [Int: String] = [:]
        for (index, message) in messages.enumerated() where message.role == .user {
            occurrences[message.fingerprint, default: 0] += 1
            userKeys[index] = digest(session + ":" + message.fingerprint + ":" + String(occurrences[message.fingerprint]!))
        }
        if sessionID != session {
            suspend(); sessionID = session; previous = messages
            ledger.observedUserKeys.formUnion(userKeys.values)
            status = "已建立基线；仅统计此后新增消息"
            return
        }
        // Any non-tail mutation, history pagination, shrinking, or branch switch rebases.
        let overlap = min(previous.count, messages.count)
        let compatible = messages.count >= previous.count && (0..<overlap).allSatisfy { i in
            previous[i] == messages[i] ||
            (i == previous.count - 1 && previous[i].role == .assistant && messages[i].role == .assistant)
        }
        guard compatible else {
            suspend(); sessionID = session; previous = messages
            ledger.observedUserKeys.formUnion(userKeys.values)
            status = "历史/分支发生变化，已重新建立基线"
            return
        }
        // New nodes must survive a second snapshot; partial AX layouts are not sends.
        if messages.count > previous.count {
            let signature = messages.map { $0.role == .assistant ? VisibleMessage(.assistant, "") : $0 }
            if candidate != signature {
                candidate = signature; candidateAt = now
                status = "正在确认新增消息"
                return
            }
            guard now.timeIntervalSince(candidateAt ?? now) >= 0.5 else { return }
        }
        candidate = nil; candidateAt = nil

        for i in messages.indices {
            let message = messages[i]
            if i >= previous.count {
                changedAt[i] = now; firstSeen[i] = now
                if message.role == .user {
                    if let key = userKeys[i], ledger.observedUserKeys.insert(key).inserted {
                        requestID = UUID()
                        bindings[i] = UUID()
                    } else {
                        // A previously observed history node reappeared after scrolling/restart.
                        requestID = nil
                    }
                } else if requestID != nil {
                    bindings[i] = UUID()
                }
            } else if previous[i] != message {
                changedAt[i] = now
            }
            guard let eventID = bindings[i], let request = requestID else { continue }
            if message.role == .assistant {
                // The final assistant waits for generation to end + a quiet period.
                if i == messages.count - 1 && (isGenerating || now.timeIntervalSince(changedAt[i] ?? now) < settling) { continue }
            }
            let count = tokenizer.count(message.text)
            if let existing = ledger.events.firstIndex(where: { $0.id == eventID }) {
                if ledger.events[existing].contentHash != message.fingerprint {
                    ledger.events[existing].visibleTokens = count
                    ledger.events[existing].contentHash = message.fingerprint
                    ledger.events[existing].updatedAt = now
                }
            } else {
                // Bind to the nearest already-recorded user, not the current loop's last user.
                let parent = message.role == .user ? request : ledger.events.last(where: {
                    $0.sessionID == session && $0.app == app && $0.role == .user
                })?.requestID
                guard let parent else { continue }
                ledger.events.append(UsageEvent(id: eventID, requestID: parent, sessionID: session,
                    observedAt: firstSeen[i] ?? now, updatedAt: now, role: message.role,
                    visibleTokens: count, tokenizerID: tokenizer.identifier, contentHash: message.fingerprint,
                    cacheCandidateTokens: message.role == .user ? cacheEstimator.candidateTokens(for: Array(messages[...i]), tokenizer: tokenizer) : nil, app: app))
            }
        }
        previous = messages
        status = isGenerating ? "正在生成；输出稳定后更新" : "监测中 · visible tokens ≈"
    }
}
