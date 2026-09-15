import Foundation

/// Published per-million-token rates for one model.
///
/// Cache rates follow Anthropic's published multipliers on the base input rate:
/// reads ~0.1x, writes 1.25x for a 5-minute TTL and 2x for a 1-hour TTL. Claude
/// logs report the two write TTLs separately, so they are priced separately
/// rather than assumed.
public struct ModelRate: Codable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double

    public init(input: Double, output: Double, cacheRead: Double? = nil,
                cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * 0.1
        self.cacheWrite5m = cacheWrite5m ?? input * 1.25
        self.cacheWrite1h = cacheWrite1h ?? input * 2.0
    }
}

/// What a set of usage records would have cost at published API list rates.
///
/// This is deliberately not called "spend". The logs record no billing mode, so
/// a subscription user pays a flat fee regardless of what this says. See
/// `PricingTable.estimate`.
public struct CostEstimate: Equatable {
    public var amount: Double = 0
    /// Records priced against a known rate.
    public var pricedRecords = 0
    /// Records whose model has no rate in the table.
    public var unpricedRecords = 0
    /// Records that reported no model at all.
    public var unknownModelRecords = 0
    /// Models seen with no rate, for display.
    public var unpricedModels: Set<String> = []
    /// Priced input tokens whose cache-write TTL was not reported, and so were
    /// billed at the cheaper 5-minute rate.
    public var assumedShortTTLTokens: Int64 = 0

    public var isComplete: Bool { unpricedRecords == 0 && unknownModelRecords == 0 }
    public var hasAnything: Bool { pricedRecords > 0 }
}

public struct PricingTable: Codable, Equatable {
    /// Rates in USD per million tokens, keyed by the model string in the log.
    public var rates: [String: ModelRate]
    /// When the bundled rates were taken from published pricing.
    public var effective: String

    public init(rates: [String: ModelRate], effective: String) {
        self.rates = rates
        self.effective = effective
    }

    /// Anthropic list pricing. Codex/OpenAI models are deliberately absent: this
    /// project has no authoritative rate source for them, and inventing numbers
    /// would be worse than reporting them as unpriced. Add them via
    /// `~/Library/Application Support/AIUsageAuditor/pricing.json`.
    public static let bundled = PricingTable(rates: [
        "claude-fable-5":  ModelRate(input: 10, output: 50),
        "claude-mythos-5": ModelRate(input: 10, output: 50),
        "claude-opus-5":   ModelRate(input: 5,  output: 25),
        "claude-opus-4-8": ModelRate(input: 5,  output: 25),
        "claude-opus-4-7": ModelRate(input: 5,  output: 25),
        "claude-opus-4-6": ModelRate(input: 5,  output: 25),
        "claude-sonnet-5": ModelRate(input: 2,  output: 10),
        "claude-sonnet-4-6": ModelRate(input: 3, output: 15),
        "claude-haiku-4-5": ModelRate(input: 1, output: 5)
    ], effective: "2026-06-24")

    /// Dated model ids (`claude-haiku-4-5-20251001`) price as their base model.
    /// Returns nil rather than guessing when no prefix matches.
    public func rate(for model: String) -> ModelRate? {
        if let exact = rates[model] { return exact }
        let matches = rates.keys.filter { model.hasPrefix($0) }
        guard let longest = matches.max(by: { $0.count < $1.count }) else { return nil }
        return rates[longest]
    }

    /// Merges user-supplied rates over the bundled ones. A malformed file is
    /// ignored rather than silently zeroing the table.
    public static func load(from url: URL?) -> PricingTable {
        guard let url, let data = try? Data(contentsOf: url),
              let user = try? JSONDecoder().decode(PricingTable.self, from: data) else { return bundled }
        var table = bundled
        for (model, rate) in user.rates { table.rates[model] = rate }
        table.effective = user.effective
        return table
    }

    /// Prices events at list rates. Records with no model, or a model this table
    /// does not know, are counted separately and contribute nothing — the same
    /// fail-closed rule the token scanner uses for unrecognized sources.
    public func estimate(_ events: [LogEvent]) -> CostEstimate {
        var result = CostEstimate()
        for event in events {
            guard let model = event.model, !model.isEmpty else {
                result.unknownModelRecords += 1; continue
            }
            guard let rate = self.rate(for: model) else {
                result.unpricedRecords += 1; result.unpricedModels.insert(model); continue
            }
            let t = event.tokens
            let read = t.cacheRead ?? 0
            let write = t.cacheWrite ?? 0
            // Claude reports input as uncached + read + write; bill each at its own rate.
            let uncached = max(0, t.input - read - write)
            let write1h = t.cacheWrite1h ?? 0
            let write5m = max(0, write - write1h)
            if t.cacheWrite1h == nil && write > 0 { result.assumedShortTTLTokens += write }

            var cents = Double(uncached) * rate.input
            cents += Double(read) * rate.cacheRead
            cents += Double(write5m) * rate.cacheWrite5m
            cents += Double(write1h) * rate.cacheWrite1h
            cents += Double(t.output) * rate.output
            result.amount += cents / 1_000_000
            result.pricedRecords += 1
        }
        return result
    }
}
