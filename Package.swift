// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (Foundation only): Ollama client, prompts, screen context, agent loop.
        .target(name: "CompanionCore"),
        // The menu-bar app: hotkeys, capture/OCR, speech, panel and cursor buddy.
        .executableTarget(name: "Companion", dependencies: ["CompanionCore"]),
        // Latency benchmark for the local brain: `swift run -c release Bench [model …]`.
        .executableTarget(name: "Bench", dependencies: ["CompanionCore"]),
        // Run via scripts/test.sh — it adds the Swift Testing paths the Command Line Tools need.
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
    ],
    swiftLanguageModes: [.v5]
)
