import AppKit
import Carbon.HIToolbox
import CompanionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = CompanionController()
    private let holdMonitor = ModifierHoldMonitor()
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Companion")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // ⌃⌥Space: type. Hold ⌃⌥: talk.
        hotKey = GlobalHotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            self?.holdMonitor.cancel()
            self?.controller.toggleInput()
        }
        holdMonitor.onBegin = { [weak self] in self?.controller.beginVoice() }
        holdMonitor.onEnd = { [weak self] in self?.controller.endVoice() }
        holdMonitor.onCancel = { [weak self] in self?.controller.cancelVoice() }
        holdMonitor.start()

        if !AXIsProcessTrusted() {
            Permissions.promptAccessibility()
            // Event monitors installed before trust is granted stay deaf; reinstall once it is.
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    timer.invalidate()
                    self?.holdMonitor.start()
                }
            }
        }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = controller.config
        let models = controller.models

        menu.addItem(ClosureMenuItem("Ask Companion  ⌃⌥Space") { [weak self] in self?.controller.toggleInput() })
        menu.addItem(disabled("Hold ⌃⌥ to talk · start with \"agent:\" to run tasks"))
        menu.addItem(ClosureMenuItem("Show History") { [weak self] in self?.controller.showHistory() })
        menu.addItem(.separator())

        menu.addItem(brainMenu(config))
        menu.addItem(submenu("Local model", models.map(\.name), current: config.chatModel) { [weak self] name in
            self?.controller.selectChatModel(name)
        })
        let visionItem = NSMenuItem(title: "Vision model", action: nil, keyEquivalent: "")
        let visionMenu = NSMenu()
        let auto = models.first(where: \.supportsVision)?.name
        visionMenu.addItem(ClosureMenuItem("Auto" + (auto.map { " (\($0))" } ?? " — none installed"),
                                           checked: config.visionMode != .never && config.visionModel == nil) { [weak self] in
            self?.controller.update { $0.visionModel = nil; $0.visionMode = .auto }
        })
        for name in models.filter(\.supportsVision).map(\.name) {
            visionMenu.addItem(ClosureMenuItem(name, checked: config.visionMode != .never && config.visionModel == name) { [weak self] in
                self?.controller.update { $0.visionModel = name; $0.visionMode = .auto }
            })
        }
        visionMenu.addItem(ClosureMenuItem("Off (OCR only)", checked: config.visionMode == .never) { [weak self] in
            self?.controller.update { $0.visionMode = .never }
        })
        if auto == nil {
            visionMenu.addItem(.separator())
            visionMenu.addItem(disabled("Install one: ollama pull qwen2.5vl:3b"))
        }
        visionItem.submenu = visionMenu
        menu.addItem(visionItem)
        menu.addItem(.separator())

        menu.addItem(voiceMenu(config))
        let approvalItem = NSMenuItem(title: "Ask before acting", action: nil, keyEquivalent: "")
        let approvalMenu = NSMenu()
        for (policy, title) in [(ApprovalPolicy.risky, "Only for risky actions"), (.always, "Always"), (.never, "Never")] {
            approvalMenu.addItem(ClosureMenuItem(title, checked: config.approvalPolicy == policy) { [weak self] in
                self?.controller.update { $0.approvalPolicy = policy }
            })
        }
        approvalItem.submenu = approvalMenu
        menu.addItem(approvalItem)
        menu.addItem(ClosureMenuItem("Speak answers to voice questions", checked: config.speakReplies) { [weak self] in
            self?.controller.update { $0.speakReplies.toggle() }
        })
        menu.addItem(ClosureMenuItem("Speak answers to typed questions", checked: config.speakTypedReplies) { [weak self] in
            self?.controller.update { $0.speakTypedReplies.toggle() }
        })
        menu.addItem(ClosureMenuItem("Show cursor buddy when idle", checked: config.showBuddy) { [weak self] in
            self?.controller.update { $0.showBuddy.toggle() }
        })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Check Setup…") { [weak self] in self?.controller.checkSetup(reportIfFine: true) })
        let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let permissionsMenu = NSMenu()
        for kind in Permissions.Kind.allCases {
            let mark = kind.isGranted ? "✓" : "✗"
            permissionsMenu.addItem(ClosureMenuItem("\(mark) \(kind.rawValue) — \(kind.purpose)") {
                NSWorkspace.shared.open(kind.settingsURL)
            })
        }
        permissionsItem.submenu = permissionsMenu
        menu.addItem(permissionsItem)
        menu.addItem(ClosureMenuItem("Edit config.json…") {
            NSWorkspace.shared.open(CompanionConfig.fileURL)
        })
        menu.addItem(ClosureMenuItem("Reload config") { [weak self] in self?.controller.reloadConfig() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Companion", key: "q") { NSApp.terminate(nil) })

        Task { await controller.refreshModels(warmUp: false) }
    }

    private func brainMenu(_ config: CompanionConfig) -> NSMenuItem {
        let usingClaude = config.brain == "claude" && controller.hasAPIKey
        let item = NSMenuItem(title: "Brain: \(usingClaude ? "Claude" : "Local")", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Claude — sees your screen, most capable", checked: config.brain == "claude") { [weak self] in
            guard let self else { return }
            self.controller.update { $0.brain = "claude" }
            if !self.controller.hasAPIKey { self.promptForAPIKey() }
        })
        menu.addItem(ClosureMenuItem("Local only — private, nothing leaves your Mac", checked: config.brain == "local") { [weak self] in
            self?.controller.update { $0.brain = "local" }
        })
        menu.addItem(.separator())
        menu.addItem(disabled("Claude model"))
        for (id, title) in [("claude-opus-5-5", "Opus 5.5 — smartest"), ("claude-sonnet-5-5", "Sonnet 5.5 — faster, cheaper"), ("claude-haiku-4-5", "Haiku 4.5 — fastest")] {
            menu.addItem(ClosureMenuItem(title, checked: config.claudeModel == id) { [weak self] in
                self?.controller.update { $0.claudeModel = id }
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(controller.hasAPIKey ? "Claude API Key… (saved)" : "Claude API Key…") { [weak self] in self?.promptForAPIKey() })
        item.submenu = menu
        return item
    }

    /// Asks for the key in a secure field; it goes straight to the Keychain.
    private func promptForAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = "Paste your key from console.anthropic.com. It's stored in your macOS Keychain. Screenshots and questions are sent to Anthropic when Claude is the brain; switch to Local only any time for full privacy."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if controller.hasAPIKey { alert.addButton(withTitle: "Remove Key") }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { controller.setAPIKey(key) }
        case .alertThirdButtonReturn:
            controller.setAPIKey(nil)
        default:
            break
        }
    }

    private func voiceMenu(_ config: CompanionConfig) -> NSMenuItem {
        let server = controller.voiceServer
        let item = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let neural: [(String, String)] = [
            ("bf_emma", "Emma — British"), ("bf_isabella", "Isabella — British"), ("bf_alice", "Alice — British"),
            ("bf_lily", "Lily — British"), ("af_heart", "Heart — American"), ("af_bella", "Bella — American"),
            ("bm_george", "George — British male"),
        ]
        menu.addItem(disabled(server.isReady ? "Neural (on-device)" : server.isInstalled ? "Neural — starting…" : "Neural — run scripts/setup-voice.sh"))
        for (id, title) in neural {
            let entry = ClosureMenuItem(title, checked: config.voice == id) { [weak self] in
                self?.controller.update { $0.voice = id }
                self?.controller.previewVoice()
            }
            entry.isEnabled = server.isReady
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(disabled("Apple voices"))
        for name in ["Moira", "Samantha", "Daniel", "Karen"] {
            menu.addItem(ClosureMenuItem(name, checked: config.voice == "system:\(name)") { [weak self] in
                self?.controller.update { $0.voice = "system:\(name)" }
                self?.controller.previewVoice()
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Preview") { [weak self] in self?.controller.previewVoice() })
        item.submenu = menu
        return item
    }

    private func submenu(_ title: String, _ names: [String], current: String, select: @escaping (String) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(current)", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        if names.isEmpty { menu.addItem(disabled("No models found — is Ollama running?")) }
        for name in names {
            menu.addItem(ClosureMenuItem(name, checked: name == current) { select(name) })
        }
        item.submenu = menu
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate() // NSApplication holds its delegate weakly; this local lives until run() returns
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
