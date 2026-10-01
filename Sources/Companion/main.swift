import AppKit
import Carbon.HIToolbox
import CompanionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = CompanionController()
    private let holdMonitor = ModifierHoldMonitor()
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var accessibilityTimer: Timer?
    private lazy var onboarding = OnboardingController(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image()
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
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

        installEditMenu()
        if !AXIsProcessTrusted() {
            // No system prompt here: onboarding asks in context, and afterwards the notch shows a setup note.
            // Event monitors installed before trust is granted stay deaf; reinstall once it is.
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    timer.invalidate()
                    self?.holdMonitor.start()
                }
            }
        }
        controller.openOnboarding = { [weak self] in
            self?.controller.notch.collapse()
            self?.onboarding.show()
        }
        controller.start()
        if !OnboardingController.isComplete {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.onboarding.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    /// Menu-bar apps have no menu bar, and ⌘V/⌘C/⌘X/⌘A/⌘Z only work through an Edit menu's key equivalents.
    /// This one is never visible, but it makes copy and paste work in every ZOOBIE text field.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func togglePanel() {
        controller.notch.toggle(tab: .settings)
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
