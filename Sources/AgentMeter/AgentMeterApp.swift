import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var demoWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // One writer per bundle; a second instance must not race the local JSON ledger.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--show") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Agent Meter · Logs"
            window.contentView = NSHostingView(rootView: AuditorPanel(model: AuditorModel.shared))
            window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            demoWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct AgentMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AuditorModel.shared
    var body: some Scene {
        MenuBarExtra {
            AuditorPanel(model: model)
        } label: {
            Text(model.menuTitle)
                .accessibilityLabel("今日日志上报 token：输入 \(model.today.input)，输出 \(model.today.output)")
        }
        .menuBarExtraStyle(.window)
        Window("AI Usage Auditor · Preview", id: "preview") {
            AuditorPanel(model: model)
        }
        .defaultSize(width: 460, height: 780)
    }
}
