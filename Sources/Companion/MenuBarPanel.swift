import AppKit
import CompanionCore
import SwiftUI

// MARK: - View

/// ZOOBIE's settings: status, shortcuts, brain, voice, approvals and permissions (shown in the notch's Settings tab).
struct MenuBarPanelView: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var buddy: BuddyModel
    let openOnboarding: () -> Void
    var embedded = false

    init(controller: CompanionController, buddy: BuddyModel, openOnboarding: @escaping () -> Void, embedded: Bool = false) {
        self.controller = controller
        self.buddy = buddy
        self.openOnboarding = openOnboarding
        self.embedded = embedded
    }

    @State private var permissions = Permissions.Kind.allCases.map { ($0, $0.isGranted) }
    @State private var editingKey = false
    @State private var keyDraft = ""
    @State private var hasKey = APIKeyStore.read() != nil
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private static let claudeModels = [("claude-opus-5-5", "Opus 5.5 — smartest"), ("claude-sonnet-5-5", "Sonnet 5.5 — faster"), ("claude-haiku-4-5", "Haiku 4.5 — fastest")]
    private static let neuralVoices = [("bf_emma", "Emma · British"), ("bf_isabella", "Isabella · British"), ("bf_alice", "Alice · British"),
                                       ("bf_lily", "Lily · British"), ("af_heart", "Heart · American"), ("af_bella", "Bella · American"),
                                       ("bm_george", "George · British male")]
    private static let appleVoices = ["Moira", "Samantha", "Daniel", "Karen"]

    private var missingPermissions: [Permissions.Kind] { permissions.filter { !$0.1 }.map(\.0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded { header }
            shortcuts
            if !missingPermissions.isEmpty || (controller.config.brain == "claude" && !hasKey) { setupBanner }
            brainSection
            voiceSection
            actingSection
            permissionsSection
            footer
        }
        .padding(embedded ? 4 : 16)
        .frame(maxWidth: embedded ? .infinity : 340)
        .onReceive(tick) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func refresh() {
        permissions = Permissions.Kind.allCases.map { ($0, $0.isGranted) }
        hasKey = APIKeyStore.read() != nil
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZoobieMark(size: 18)
            Text("ZOOBIE").font(.system(size: 15, weight: .bold)).tracking(1.2).foregroundStyle(DS.Colors.textPrimary)
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            if !missingPermissions.isEmpty { return ("Needs setup", DS.Colors.warning) }
            switch buddy.mode {
            case .listening: return ("Listening", DS.Colors.accentBright)
            case .thinking: return ("Thinking", DS.Colors.accentBright)
            case .speaking: return ("Speaking", DS.Colors.accentBright)
            case .idle: return ("Ready", DS.Colors.success)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Colors.surface2))
    }

    private var shortcuts: some View {
        HStack(spacing: 12) {
            keycap("⌃⌥", "hold to talk")
            keycap("⌃⌥Space", "type")
            keycap("esc", "stop")
        }
    }

    private func keycap(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(DS.Colors.surface3))
            Text(label).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private var setupBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(DS.Colors.accentBright)
            VStack(alignment: .leading, spacing: 1) {
                Text("Finish setting up").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textPrimary)
                Text("A couple of steps so I can see, hear and act.").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer()
            Button("Continue", action: openOnboarding).buttonStyle(DSButtonStyle(kind: .primary, compact: true))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Colors.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium).strokeBorder(DS.Colors.accent.opacity(0.35)))
    }

    // MARK: Brain

    private var brainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionLabel(text: "Brain")
            DSSegmented(options: [("claude", "Claude"), ("local", "Local only")], selection: Binding(
                get: { controller.config.brain }, set: { value in controller.update { $0.brain = value } }
            ))
            if controller.config.brain == "claude" {
                settingRow("Model") {
                    Picker("", selection: Binding(get: { controller.config.claudeModel }, set: { id in controller.update { $0.claudeModel = id } })) {
                        ForEach(Self.claudeModels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                apiKeyRow
            } else {
                settingRow("Model") {
                    Picker("", selection: Binding(get: { controller.config.chatModel }, set: { controller.selectChatModel($0) })) {
                        ForEach(controller.models.map(\.name), id: \.self) { Text($0).tag($0) }
                        if controller.models.isEmpty { Text(controller.config.chatModel).tag(controller.config.chatModel) }
                    }
                }
                Text("Private: nothing leaves your Mac. Less capable than Claude.")
                    .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
            }
        }
    }

    @ViewBuilder private var apiKeyRow: some View {
        if editingKey {
            HStack(spacing: 6) {
                SecureField("sk-ant-…", text: $keyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.Colors.surface2))
                    .onSubmit(saveKey)
                Button("Save", action: saveKey).buttonStyle(DSButtonStyle(kind: .primary, compact: true))
                Button("Cancel") { editingKey = false; keyDraft = "" }.buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
            }
        } else {
            settingRow("API key") {
                HStack(spacing: 6) {
                    Text(hasKey ? "Saved in Keychain" : "Not set")
                        .font(.system(size: 11))
                        .foregroundStyle(hasKey ? DS.Colors.textSecondary : DS.Colors.warning)
                    Button(hasKey ? "Change" : "Add key") { editingKey = true }.buttonStyle(DSButtonStyle(kind: hasKey ? .secondary : .primary, compact: true))
                }
            }
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        controller.setAPIKey(key)
        keyDraft = ""
        editingKey = false
        refresh()
    }

    // MARK: Voice

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionLabel(text: "Voice")
            settingRow("Voice") {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { controller.config.voice }, set: { id in
                        controller.update { $0.voice = id }
                        controller.previewVoice()
                    })) {
                        Section("Neural (on-device)") {
                            ForEach(Self.neuralVoices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Section("Apple") {
                            ForEach(Self.appleVoices, id: \.self) { Text($0).tag("system:\($0)") }
                        }
                    }
                    Button { controller.previewVoice() } label: { Image(systemName: "play.fill") }
                        .buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                        .help("Preview")
                }
            }
            toggle("Speak answers to voice questions", \.speakReplies)
            toggle("Speak answers to typed questions", \.speakTypedReplies)
            toggle("Show the pointer when idle", \.showBuddy)
        }
    }

    // MARK: Acting

    private var actingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionLabel(text: "Ask before acting")
            DSSegmented(options: [(ApprovalPolicy.risky, "Risky only"), (.always, "Always"), (.never, "Never")], selection: Binding(
                get: { controller.config.approvalPolicy }, set: { value in controller.update { $0.approvalPolicy = value } }
            ))
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionLabel(text: "Permissions")
            ForEach(permissions, id: \.0) { kind, granted in
                HStack(spacing: 8) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(granted ? DS.Colors.success : DS.Colors.warning)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.textPrimary)
                        Text(kind.purpose).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
                    }
                    Spacer()
                    if !granted {
                        Button("Grant") { NSWorkspace.shared.open(kind.settingsURL) }.buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                        Button("Reset") {
                            Permissions.reset(kind)
                            NSWorkspace.shared.open(kind.settingsURL)
                        }
                        .buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                        .help("Already switched on but still missing? This clears macOS's stale entry so you can grant it once more.")
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button("History", action: controller.showHistory).buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
            Button("Settings file") { NSWorkspace.shared.open(CompanionConfig.fileURL) }.buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
            Spacer()
            Button("Quit ZOOBIE") { NSApp.terminate(nil) }.buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
        }
        .padding(.top, 2)
    }

    // MARK: Building blocks

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            content()
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
        }
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<CompanionConfig, Bool>) -> some View {
        Toggle(isOn: Binding(get: { controller.config[keyPath: keyPath] }, set: { value in controller.update { $0[keyPath: keyPath] = value } })) {
            Text(title).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(DS.Colors.accent)
    }
}
