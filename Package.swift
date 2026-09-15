// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentMeter",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AuditorCore", targets: ["AuditorCore"]),
        .library(name: "AccessibilityKit", targets: ["AccessibilityKit"]),
        .executable(name: "AgentMeter", targets: ["AgentMeter"]),
        .executable(name: "AXInspector", targets: ["AXInspector"]),
        .executable(name: "LogInspector", targets: ["LogInspector"])
    ],
    targets: [
        .target(name: "AuditorCore"),
        .target(name: "AccessibilityKit", dependencies: ["AuditorCore"]),
        .executableTarget(name: "AgentMeter", dependencies: ["AuditorCore", "AccessibilityKit"]),
        .executableTarget(name: "AXInspector", dependencies: ["AuditorCore", "AccessibilityKit"]),
        .executableTarget(name: "LogInspector", dependencies: ["AuditorCore"]),
        .testTarget(name: "AuditorCoreTests", dependencies: ["AuditorCore"])
    ]
)
