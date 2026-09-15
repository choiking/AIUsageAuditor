import Foundation

/// UI language. Display text is the only thing this switches: stored ledgers,
/// diagnostics keys and log parsing stay language-independent.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, chinese, english
    public var id: String { rawValue }

    /// The language actually rendered. `.system` follows the user's preferred
    /// languages: Chinese for any zh variant, English for everything else,
    /// since those are the only two translations that exist.
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .chinese : .english
    }

    /// Picks between a Chinese and an English literal. Every localized string in
    /// the app funnels through here, so there is exactly one place where the
    /// choice is made.
    public func pick(_ chinese: String, _ english: String) -> String {
        resolved == .chinese ? chinese : english
    }

    /// Menu label. The two concrete languages name themselves in their own
    /// script so the option stays readable whichever language is active.
    public var menuLabel: String {
        switch self {
        case .system: return pick("跟随系统", "Follow system")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

public enum LogProvenance {
    /// Stored when a log reported no recognizable entrypoint. A stable token
    /// rather than display text; ledgers written before the English UI existed
    /// hold the old Chinese literal, which `display` still recognizes.
    public static let unreported = "unreported"
    private static let legacyUnreported = "未提供或未识别"

    /// Raw entrypoint values are shown verbatim — they are what the log says.
    /// Only the sentinel is translated.
    public static func display(_ value: String, _ language: AppLanguage) -> String {
        guard value == unreported || value == legacyUnreported else { return value }
        return language.pick("未提供或未识别", "not reported")
    }
}
