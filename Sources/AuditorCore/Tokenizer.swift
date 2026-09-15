import Foundation

public protocol TokenCounting {
    var identifier: String { get }
    func count(_ text: String) -> Int
}

/// Offline heuristic: ASCII runs ≈ 4 characters/token; CJK ≈ 1.5 tokens/scalar;
/// other non-ASCII scalars ≈ 1 token. Not a model-compatible BPE tokenizer.
public struct ApproximateTokenizer: TokenCounting {
    public let identifier = "visible-heuristic-v1"
    public init() {}
    public func count(_ text: String) -> Int {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        var units = 0.0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0...127: units += 0.25
            case 0x3400...0x9FFF, 0x20000...0x3134F: units += 1.5
            default: units += 1
            }
        }
        return Int(ceil(units))
    }
}
