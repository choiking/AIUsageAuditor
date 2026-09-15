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

    /// OpenAI publishes only input / cached-input / output. Tokens written to
    /// cache carry no premium there, so both write rates are the input rate.
    public init(openAI input: Double, output: Double, cached: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cached
        self.cacheWrite5m = input
        self.cacheWrite1h = input
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

    /// Published list rates, USD per million tokens.
    ///
    /// Anthropic: platform.claude.com/docs/en/about-claude/pricing
    /// OpenAI:    developers.openai.com/api/docs/pricing
    ///
    /// Every figure is transcribed from those tables rather than derived from a
    /// multiplier, because the multipliers have exceptions — Fable 5.1 and
    /// Mythos 5.1 read cache at 0.025x base, not the usual 0.1x.
    ///
    /// OpenAI publishes no cache-write premium: cached input is discounted and
    /// everything else bills at the base input rate, so both write rates equal
    /// `input` for those models.
    public static let bundled = PricingTable(rates: [
        // — Anthropic —
        "claude-fable-5-1":  ModelRate(input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.50, cacheWrite1h: 20),
        "claude-mythos-5-1": ModelRate(input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.50, cacheWrite1h: 20),
        "claude-fable-5":    ModelRate(input: 10, output: 50, cacheRead: 1,    cacheWrite5m: 12.50, cacheWrite1h: 20),
        "claude-mythos-5":   ModelRate(input: 10, output: 50, cacheRead: 1,    cacheWrite5m: 12.50, cacheWrite1h: 20),
        "claude-opus-5":     ModelRate(input: 5,  output: 25, cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
        "claude-opus-4-8":   ModelRate(input: 5,  output: 25, cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
        "claude-opus-4-7":   ModelRate(input: 5,  output: 25, cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
        "claude-opus-4-6":   ModelRate(input: 5,  output: 25, cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
        "claude-opus-4-5":   ModelRate(input: 5,  output: 25, cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
        "claude-opus-4-1":   ModelRate(input: 15, output: 75, cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30),
        "claude-opus-4":     ModelRate(input: 15, output: 75, cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30),
        "claude-sonnet-5":   ModelRate(input: 2,  output: 10, cacheRead: 0.20, cacheWrite5m: 2.50,  cacheWrite1h: 4),
        "claude-sonnet-4-6": ModelRate(input: 3,  output: 15, cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-sonnet-4-5": ModelRate(input: 3,  output: 15, cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-sonnet-4":   ModelRate(input: 3,  output: 15, cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
        "claude-haiku-4-5":  ModelRate(input: 1,  output: 5,  cacheRead: 0.10, cacheWrite5m: 1.25,  cacheWrite1h: 2),
        "claude-haiku-3-5":  ModelRate(input: 0.80, output: 4, cacheRead: 0.08, cacheWrite5m: 1,    cacheWrite1h: 1.60),

        // — OpenAI —
        "gpt-6-astra":    ModelRate(openAI: 10,   output: 50,   cached: 1),
        "gpt-5.6-sol":    ModelRate(openAI: 4,    output: 20,   cached: 0.40),
        "gpt-5.6-terra":  ModelRate(openAI: 2,    output: 12,   cached: 0.20),
        "gpt-5.6-luna":   ModelRate(openAI: 0.20, output: 1.20, cached: 0.02),
        "gpt-5.5":        ModelRate(openAI: 5,    output: 30,   cached: 0.50),
        "gpt-5.5-pro":    ModelRate(openAI: 30,   output: 180,  cached: 30),
        "gpt-5.4":        ModelRate(openAI: 2.50, output: 15,   cached: 0.25),
        "gpt-5.4-mini":   ModelRate(openAI: 0.75, output: 4.50, cached: 0.075),
        "gpt-5.4-nano":   ModelRate(openAI: 0.20, output: 1.25, cached: 0.02),
        "gpt-5.4-pro":    ModelRate(openAI: 30,   output: 180,  cached: 30),
        "gpt-5.3-codex":  ModelRate(openAI: 1.75, output: 14,   cached: 0.175),
        "gpt-5.2":        ModelRate(openAI: 1.75, output: 14,   cached: 0.175),
        "gpt-5.2-pro":    ModelRate(openAI: 21,   output: 168,  cached: 21),
        "gpt-5.1":        ModelRate(openAI: 1.25, output: 10,   cached: 0.125),
        "gpt-5":          ModelRate(openAI: 1.25, output: 10,   cached: 0.125),
        "gpt-5-mini":     ModelRate(openAI: 0.25, output: 2,    cached: 0.025),
        "gpt-5-nano":     ModelRate(openAI: 0.05, output: 0.40, cached: 0.005),
        "gpt-5-pro":      ModelRate(openAI: 15,   output: 120,  cached: 15),
        "gpt-5-search-api": ModelRate(openAI: 1.25, output: 10, cached: 0.125)
    ], effective: "2026-09-16")

    /// Exact match, or the same id with a trailing `-YYYYMMDD` snapshot date
    /// removed, since `claude-haiku-4-5-20251001` is that same model.
    ///
    /// General prefix matching would be wrong: `gpt-5-codex` is not `gpt-5`, and
    /// the codex variants are priced differently from the base models they share
    /// a prefix with. An unrecognized id returns nil and is reported as unpriced.
    public func rate(for model: String) -> ModelRate? {
        if let exact = rates[model] { return exact }
        let parts = model.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            return rates[parts.dropLast().joined(separator: "-")]
        }
        return nil
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
