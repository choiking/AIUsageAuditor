import Foundation

public struct Ledger: Codable, Equatable {
    public var schemaVersion = 1
    public var events: [UsageEvent] = []
    /// Session + prompt fingerprint + occurrence; includes baseline history, never raw text.
    public var observedUserKeys: Set<String> = []
    public init() {}
    public func today(at date: Date = Date(), calendar: Calendar = .current, app: AIApp? = nil) -> UsageTotals {
        UsageTotals(events: events.filter { calendar.isDate($0.observedAt, inSameDayAs: date) && (app == nil || $0.app == app) })
    }
    public func session(_ id: String?) -> UsageTotals {
        UsageTotals(events: events.filter { $0.sessionID == id })
    }
}

public final class LedgerStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: url.path) else { return Ledger() }
        let result = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
        guard result.schemaVersion == 1 else {
            throw NSError(domain: "AuditorStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported ledger version. Original file preserved."])
        }
        return result
    }
    public func save(_ ledger: Ledger) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
