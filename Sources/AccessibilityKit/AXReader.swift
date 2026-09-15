import AppKit
import ApplicationServices
import AuditorCore

public enum AXReadError: Error, LocalizedError {
    case permissionDenied, appNotRunning, noWindow, incomplete(String)
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要辅助功能权限。授权后若状态未更新，请重启 Auditor。"
        case .appNotRunning: return "目标应用未运行，请打开所选应用。"
        case .noWindow: return "目标应用没有可读取的主窗口。"
        case .incomplete(let reason): return "AX 快照不完整，本轮跳过：\(reason)"
        }
    }
}

public struct AXCapture {
    public var root: AXNode
    public var windowTitle: String
    public var nodeCount: Int
    public var accessibilityActivationResult: Int32?
    public var enhancedAccessibilityResult: Int32?
    public var appAccessibilityResult: Int32?
    public var roleCounts: [String: Int]
}

public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }
    public static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Reads message content. For Electron, requests its documented accessibility tree.
/// Never edits messages, activates controls, taps keys, or reads the clipboard.
public final class AXReader {
    public init() {}
    public func capture(configuration: AdapterConfiguration) throws -> AXCapture {
        try configuration.validate()
        guard AccessibilityPermission.isGranted else { throw AXReadError.permissionDenied }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: configuration.bundleIdentifier).first else {
            throw AXReadError.appNotRunning
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        // Electron otherwise exposes only its window shell. This requests the
        // renderer tree; it does not grant or bypass macOS Accessibility access.
        let activation: Int32? = configuration.app == .claude
            ? AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
            : nil
        var enhancedSettable = DarwinBoolean(false)
        let enhancedSupported = AXUIElementIsAttributeSettable(element, "AXEnhancedUserInterface" as CFString,
                                                              &enhancedSettable)
        let appActivation: Int32? = enhancedSupported == .success && enhancedSettable.boolValue
            ? AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue
            : (enhancedSupported == .success ? AXError.attributeUnsupported.rawValue : enhancedSupported.rawValue)
        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &windowRef)
        guard result == .success, let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            if result == .apiDisabled { throw AXReadError.permissionDenied }
            throw AXReadError.noWindow
        }
        let window = unsafeBitCast(windowRef, to: AXUIElement.self)
        // Chromium documents this window attribute for requesting its full tree.
        // Some Electron versions accept AXManualAccessibility before the renderer
        // is ready; the window-level request covers that path as well.
        let enhancedActivation: Int32? = configuration.app == .claude
            ? AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue
            : nil
        var count = 0
        var roleCounts: [String: Int] = [:]
        let deadline = Date().addingTimeInterval(2.5)
        var ancestors: [AXUIElement] = []
        func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
            switch error {
            case .success: return result
            case .attributeUnsupported, .noValue: return nil
            case .apiDisabled: throw AXReadError.permissionDenied
            default: throw AXReadError.incomplete("attribute \(attribute), AXError \(error.rawValue)")
            }
        }
        func string(_ element: AXUIElement, _ attribute: String) throws -> String {
            let raw = try value(element, attribute)
            return (raw as? String) ?? (raw as? URL)?.absoluteString ?? ""
        }
        func traverse(_ element: AXUIElement, depth: Int) throws -> AXNode {
            guard depth <= configuration.maxDepth, count < configuration.maxNodes, Date() < deadline else {
                throw AXReadError.incomplete("达到深度、节点数或时间上限")
            }
            if ancestors.contains(where: { CFEqual($0, element) }) { throw AXReadError.incomplete("循环节点") }
            count += 1; ancestors.append(element)
            defer { ancestors.removeLast() }
            let role = try string(element, kAXRoleAttribute)
            roleCounts[role, default: 0] += 1
            // Never inspect drafts, including inspector mode.
            if ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) {
                return AXNode(role: role, label: "[editable content excluded]")
            }
            let identifier = try string(element, "AXIdentifier")
            let description = try string(element, kAXDescriptionAttribute)
            let title = try string(element, kAXTitleAttribute)
            let textValue = configuration.textRoles.contains(role) ? try string(element, kAXValueAttribute) : ""
            var document = try string(element, kAXDocumentAttribute)
            if document.isEmpty && role == "AXWebArea" { document = try string(element, "AXURL") }
            // Toolbar/menu/button descendants cannot contain message bodies.
            let skipChildren = ["AXToolbar", "AXMenu", "AXButton"].contains(role)
            var children: [AXUIElement] = []
            if !skipChildren {
                // Native list/scroll containers can expose content through their
                // specialized attributes even when AXChildren is empty.
                let attributes = [kAXChildrenAttribute] +
                    (["AXScrollArea", "AXList", "AXTable", "AXOutline"].contains(role)
                     ? ["AXContents", "AXRows", "AXVisibleChildren"] : [])
                for attribute in attributes {
                    for child in ((try value(element, attribute)) as? [AXUIElement] ?? []) {
                        if !children.contains(where: { CFEqual($0, child) }) { children.append(child) }
                    }
                    // These attributes are alternate views of the same content.
                    // Combining a container with its rows would count it twice.
                    if !children.isEmpty { break }
                }
            }
            return AXNode(role: role, identifier: identifier, label: description.isEmpty ? title : description,
                          value: textValue, document: document,
                          children: try children.map { try traverse($0, depth: depth + 1) })
        }
        let root = try traverse(window, depth: 0)
        return AXCapture(root: root, windowTitle: root.label, nodeCount: count,
                         accessibilityActivationResult: activation,
                         enhancedAccessibilityResult: enhancedActivation,
                         appAccessibilityResult: appActivation, roleCounts: roleCounts)
    }
}

public enum AXDump {
    public static func text(_ root: AXNode, includeText: Bool = false) -> String {
        var lines: [String] = []
        func walk(_ node: AXNode, depth: Int) {
            func safe(_ value: String) -> String {
                String(value.prefix(200)).replacingOccurrences(of: "\n", with: "\\n")
            }
            // Default dump redacts labels/identifiers too: they can include user text.
            let details = includeText
                ? " id=\(safe(node.identifier)) label=\(safe(node.label)) value=\(safe(node.value)) document=\(safe(node.document))"
                : " idChars=\(node.identifier.count) labelChars=\(node.label.count) valueChars=\(node.value.count)"
            lines.append(String(repeating: "  ", count: depth) + node.role + details)
            node.children.forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return lines.joined(separator: "\n")
    }
}
