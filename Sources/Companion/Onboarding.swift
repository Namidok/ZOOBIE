import AppKit
import CompanionCore
import SwiftUI

/// The first-run setup window. Progress is stored so the relaunch macOS forces after granting
/// Screen Recording resumes on the same step.
@MainActor
final class OnboardingController {
    static let completedKey = "onboardingComplete"
    static let stepKey = "onboardingStep"
    static var isComplete: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    private let controller: CompanionController
    private var window: NSWindow?

    init(controller: CompanionController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 470),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(DS.Colors.background)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: OnboardingView(controller: controller) { [weak self] in self?.finish() })
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
        controller.checkSetup(reportIfFine: false)
    }
}

// MARK: - View

private enum Step: Int, CaseIterable {
    case welcome, accessibility, screenRecording, voice, brain, tryIt
}

private struct OnboardingView: View {
    @ObservedObject var controller: CompanionController
    let finish: () -> Void

    @AppStorage(OnboardingController.stepKey) private var stepIndex = 0
    @State private var granted: [Permissions.Kind: Bool] = [:]
    @State private var keyDraft = ""
    @State private var answersAtTryIt = 0
    @State private var voiceError: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var step: Step { Step(rawValue: stepIndex) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 34)
            Spacer(minLength: 12)
            content
                .frame(maxWidth: 420)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                .id(step)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 32)
        .frame(width: 560, height: 470)
        .background(DS.Colors.background)
        .animation(.easeInOut(duration: 0.25), value: stepIndex)
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        for kind in Permissions.Kind.allCases { granted[kind] = kind.isGranted }
    }

    private func isGranted(_ kind: Permissions.Kind) -> Bool { granted[kind] ?? false }

    private func next() {
        stepIndex = min(stepIndex + 1, Step.allCases.count - 1)
        if step == .tryIt { answersAtTryIt = controller.completedRequests }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                PixelRect(step: DS.Radius.small)
                    .fill(item.rawValue <= stepIndex ? DS.Colors.accent : DS.Colors.surface3)
                    .frame(width: item == step ? 22 : 8, height: 6)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        case .voice: voice
        case .brain: brain
        case .tryIt: tryIt
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            ZoobieMark(size: 54).padding(.bottom, 6)
            title("Hi, I'm ZOOBIE.")
            subtitle("I live next to your cursor. I can see your screen, talk with you, point at things, and get stuff done on your Mac — just hold ⌃⌥ and ask.")
            Button("Let's get set up") {
                controller.say("Hi, I'm ZOOBIE. Let's get you set up.")
                next()
            }
            .buttonStyle(DSButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
        }
    }

    private var accessibility: some View {
        permissionStep(
            icon: "hand.point.up.left.fill",
            heading: "Let me hear your shortcut and act for you",
            body: "Accessibility lets ZOOBIE notice when you hold ⌃⌥, and click, type and press keys when you ask it to do something.",
            kind: .accessibility,
            action: ("Open Accessibility Settings", { Permissions.promptAccessibility(); NSWorkspace.shared.open(Permissions.Kind.accessibility.settingsURL) }),
            note: "Switch ZOOBIE on in the list. If you see an old “Companion” entry, remove it."
        )
    }

    private var screenRecording: some View {
        permissionStep(
            icon: "rectangle.dashed.badge.record",
            heading: "Let me see your screen",
            body: "Screen Recording lets ZOOBIE look at what you're working on when you ask. It only captures when you invoke it, and never records video.",
            kind: .screenRecording,
            action: ("Open Screen Recording Settings", { Permissions.requestScreenRecordingOnce(); NSWorkspace.shared.open(Permissions.Kind.screenRecording.settingsURL) }),
            note: "After you switch it on, macOS asks to quit and reopen ZOOBIE — choose Quit & Reopen. I'll pick up right here."
        )
    }

    private var voice: some View {
        let ready = isGranted(.microphone) && isGranted(.speech)
        return VStack(spacing: 16) {
            stepIcon("waveform", done: ready)
            title("Let me hear you")
            subtitle("Your voice is transcribed on your Mac by Apple's on-device speech recognition. Nothing is recorded or stored.")
            statusRow("Microphone", isGranted(.microphone))
            statusRow("Speech Recognition", isGranted(.speech))
            if let voiceError { Text(voiceError).font(.system(size: 11)).foregroundStyle(DS.Colors.warning).multilineTextAlignment(.center) }
            HStack(spacing: 10) {
                if ready {
                    Button("Continue", action: next).buttonStyle(DSButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Allow microphone & speech") {
                        Task {
                            do { try await SpeechInput.requestPermissions(); voiceError = nil } catch { voiceError = error.localizedDescription }
                            refresh()
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    Button("Skip — I'll type", action: next).buttonStyle(DSButtonStyle(kind: .ghost))
                }
            }
        }
    }

    private var brain: some View {
        let hasKey = controller.hasAPIKey
        return VStack(spacing: 14) {
            stepIcon("brain.head.profile", done: hasKey || controller.config.brain == "local")
            title("Pick my brain")
            subtitle("Claude sees your screen and acts reliably — it's what makes ZOOBIE feel like FRIDAY. Local keeps everything on your Mac but is much less capable.")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Claude API key").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textPrimary)
                    Spacer()
                    Link("Get a key ↗", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.accentBright)
                }
                if hasKey {
                    Label("Saved in your Keychain", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.success)
                } else {
                    HStack(spacing: 8) {
                        SecureField("sk-ant-…", text: $keyDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(PixelRect(step: DS.Radius.small).fill(DS.Colors.surface2))
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey).buttonStyle(DSButtonStyle(kind: .primary, compact: true))
                    }
                }
                Text("Stored in your macOS Keychain. Screenshots and questions go to Anthropic when Claude is the brain.")
                    .font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
            }
            .padding(12)
            .dsSurface(radius: DS.Radius.medium)
            HStack(spacing: 10) {
                if hasKey {
                    Button("Continue") { controller.update { $0.brain = "claude" }; next() }
                        .buttonStyle(DSButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                }
                Button("Use local only") { controller.update { $0.brain = "local" }; next() }
                    .buttonStyle(DSButtonStyle(kind: hasKey ? .ghost : .secondary))
            }
        }
    }

    private var tryIt: some View {
        let answered = controller.completedRequests > answersAtTryIt
        return VStack(spacing: 18) {
            stepIcon(answered ? "checkmark" : "mic.fill", done: answered)
            title(answered ? "You're all set." : "Try it")
            if answered {
                subtitle("That's it. I'll be right here next to your cursor whenever you need me.")
            } else {
                subtitle("Point at anything on your screen, then hold the keys and ask out loud:")
                HStack(spacing: 8) {
                    bigKey("⌃ control")
                    Text("+").foregroundStyle(DS.Colors.textTertiary)
                    bigKey("⌥ option")
                }
                Text("“What am I looking at?”")
                    .font(.system(size: 15, weight: .medium)).italic()
                    .foregroundStyle(DS.Colors.accentBright)
                Text("Prefer typing? Press ⌃⌥Space.").font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
            }
            Button(answered ? "Finish" : "Skip for now", action: finish)
                .buttonStyle(DSButtonStyle(kind: answered ? .primary : .ghost))
                .keyboardShortcut(answered ? .defaultAction : .cancelAction)
        }
    }

    // MARK: Building blocks

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        controller.setAPIKey(key)
        keyDraft = ""
    }

    private func permissionStep(icon: String, heading: String, body: String, kind: Permissions.Kind,
                                action: (String, () -> Void), note: String) -> some View {
        let done = isGranted(kind)
        return VStack(spacing: 16) {
            stepIcon(icon, done: done)
            title(heading)
            subtitle(body)
            statusRow(kind.rawValue, done)
            HStack(spacing: 10) {
                if done {
                    Button("Continue", action: next).buttonStyle(DSButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                } else {
                    Button(action.0, action: action.1).buttonStyle(DSButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    Button("Skip", action: next).buttonStyle(DSButtonStyle(kind: .ghost))
                }
            }
            if !done {
                Text(note).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).multilineTextAlignment(.center)
                Button("Already on but still waiting? Reset it") {
                    Permissions.reset(kind)
                    action.1()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.accentBright)
                .dsPointerOnHover()
            }
        }
    }

    private func stepIcon(_ symbol: String, done: Bool) -> some View {
        ZStack {
            PixelRect(step: DS.Radius.large).fill(done ? DS.Colors.success.opacity(0.15) : DS.Colors.accent.opacity(0.15)).frame(width: 64, height: 64)
            Image(systemName: done ? "checkmark" : symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(done ? DS.Colors.success : DS.Colors.accentBright)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: done)
    }

    private func statusRow(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? DS.Colors.success : DS.Colors.textTertiary)
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            Text(ok ? "Granted" : "Waiting…").font(.system(size: 11)).foregroundStyle(ok ? DS.Colors.success : DS.Colors.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 300)
        .dsSurface(radius: DS.Radius.medium)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 22, weight: .bold)).foregroundStyle(DS.Colors.textPrimary).multilineTextAlignment(.center)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(DS.Colors.textSecondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    private func bigKey(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PixelRect(step: DS.Radius.medium).fill(DS.Colors.surface2))
            .overlay(PixelRect(step: DS.Radius.medium).strokeBorder(DS.Colors.borderStrong))
    }
}
