import Foundation
import AuditorCore
import AccessibilityKit

let args = Array(CommandLine.arguments.dropFirst())
func argument(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), args.count > index + 1 else { return nil }
    return args[index + 1]
}
if args.contains("--help") {
    print("""
    AXInspector [--app chatgpt|claude] [--config path] [--include-text] [--json] [--prompt]
    Read the selected app's main AX window once. Default: redacted tree to stdout.
    --include-text includes labels, identifiers and visible message text (never drafts).
    --json requires --include-text and emits an AXNode fixture for local debugging.
    --prompt explicitly requests Accessibility access for the invoking app/terminal.
    --write-default-config PATH writes configuration without accessing any app.
    """)
    exit(0)
}
do {
    let appName = argument("--app") ?? "chatgpt"
    guard let app = AIApp(rawValue: appName) else {
        throw NSError(domain: "AXInspector", code: 2, userInfo: [NSLocalizedDescriptionKey: "--app must be chatgpt or claude"])
    }
    if let output = argument("--write-default-config") {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(AdapterConfiguration(app: app)).write(to: URL(fileURLWithPath: output), options: .atomic)
        exit(0)
    }
    let config: AdapterConfiguration
    if let path = argument("--config") {
        config = try JSONDecoder().decode(AdapterConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } else { config = AdapterConfiguration(app: app) }
    try config.validate()
    if argument("--app") != nil && config.app != app { throw MatchingError.invalidConfiguration }
    if args.contains("--prompt") { AccessibilityPermission.request() }
    if args.contains("--json") && !args.contains("--include-text") {
        throw NSError(domain: "AXInspector", code: 2, userInfo: [NSLocalizedDescriptionKey: "--json requires --include-text; output can contain private conversation text."])
    }
    let capture = try AXReader().capture(configuration: config)
    if args.contains("--json") {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(capture.root), as: UTF8.self))
    } else {
        print(AXDump.text(capture.root, includeText: args.contains("--include-text")))
        let parsed = try ConversationMatcher(configuration: config).parse(capture.root)
        print("\nNodes: \(capture.nodeCount); user messages: \(parsed.messages.filter { $0.role == .user }.count); assistant messages: \(parsed.messages.filter { $0.role == .assistant }.count); stable document ID: \(parsed.documentID != nil)")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
