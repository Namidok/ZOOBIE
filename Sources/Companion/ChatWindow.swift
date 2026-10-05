import AppKit
import CompanionCore
import SwiftUI

// MARK: - Window

/// A borderless floating panel that takes keyboard focus without activating the app, so the user's
/// own app stays frontmost.
final class ChatPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }

    /// The panel never activates the app, so the Edit menu doesn't see ⌘V and friends — route them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector? = switch key {
            case "v": #selector(NSText.paste(_:))
            case "c": #selector(NSText.copy(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": Selector(("undo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ChatWindowModel: ObservableObject {
    enum Banner: Equatable {
        case notice(String)
        case setup([Permissions.Kind])
        case toast(String)
    }

    /// The open conversation: nil is ZOOBIE itself, otherwise a specialist.
    @Published var selected: Specialist.ID?
    @Published var showSettings = false
    @Published var banner: Banner?
    @Published var search = ""
    /// Bumped to move keyboard focus into the message field.
    @Published var focusToken = 0
}

/// ZOOBIE's home: a chat window that drops down from the MacBook notch (top centre of the screen on
/// Macs without one), with ZOOBIE and the four specialists in a sidebar and the conversation beside it.
///
/// It opens when the user hovers the notch, clicks the menu bar icon or presses ⌃⌥Space, and by itself
/// for every request so the conversation is visible. When it opened by itself, it tucks back up a few
/// seconds after ZOOBIE goes quiet unless the user is using it; opened on purpose, it stays.
@MainActor
final class ChatWindowController {
    static let defaultSize = CGSize(width: 900, height: 600)

    let model = ChatWindowModel()
    /// True while ZOOBIE has nothing in progress (set by the controller); the window only tucks away then.
    var isIdle: () -> Bool = { true }
    private let panel: ChatPanel
    private var bannerTimer: DispatchWorkItem?
    private var timer: Timer?
    private var screenObserver: Any?
    private enum Opening { case user, automatic, hover }
    private var opening = Opening.user
    private var lastActive = Date()
    private var hoverStarted: Date?

    init(controller: CompanionController, agents: AgentManager) {
        panel = ChatPanel(contentRect: CGRect(origin: .zero, size: Self.defaultSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1) // hangs from the menu bar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: ChatRootView(
            model: model, controller: controller, agents: agents, timers: controller.timers, buddy: controller.buddy.model,
            close: { [weak self] in self?.close() }
        ))
        panel.onEscape = { [weak controller] in controller?.escape() }
    }

    /// Starts watching the notch for hovers and placing the window under it.
    func start() {
        position()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    /// Shows the window on purpose (it stays until closed); with `focus`, the message field takes the keyboard.
    func open(focus: Bool) {
        show(.user)
        if focus {
            panel.makeKeyAndOrderFront(nil)
            model.focusToken += 1
        }
    }

    /// Opens on a conversation (nil = ZOOBIE).
    func open(_ conversation: Specialist.ID?, focus: Bool) {
        model.selected = conversation
        open(focus: focus)
    }

    /// Drops down for a request so the user can follow it, without taking the keyboard. Tucks away
    /// again once ZOOBIE is quiet. Leaves an already-open window (and its selection) alone.
    func openAutomatically(_ conversation: Specialist.ID? = nil) {
        guard !panel.isVisible else { return }
        model.selected = conversation
        show(.automatic)
    }

    func close() {
        model.showSettings = false
        hoverStarted = nil
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { close() } else { open(focus: true) }
    }

    func openSettings() {
        model.showSettings = true
        open(focus: true)
    }

    /// A problem or missing permission: a banner at the top of the chat, opening the window if needed.
    func showBanner(_ banner: ChatWindowModel.Banner, autoHideAfter delay: TimeInterval? = nil) {
        bannerTimer?.cancel()
        model.banner = banner
        if !panel.isVisible { show(.automatic) }
        if let delay { scheduleBannerHide(after: delay, banner) }
    }

    func dismissBanner() {
        bannerTimer?.cancel()
        model.banner = nil
    }

    /// Good news (a timer, a finished agent): a banner while the window is open, else a status line
    /// next to the cursor when nothing else is showing there.
    func toast(_ text: String, seconds: TimeInterval = 6, buddy: BuddyOverlay) {
        if panel.isVisible {
            bannerTimer?.cancel()
            model.banner = .toast(text)
            scheduleBannerHide(after: seconds, .toast(text))
        } else if buddy.model.caption == nil && buddy.model.mode == .idle {
            buddy.setCaption(text, style: .status)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if buddy.model.caption == text { buddy.setCaption(nil) }
            }
        }
    }

    private func scheduleBannerHide(after delay: TimeInterval, _ banner: ChatWindowModel.Banner) {
        let work = DispatchWorkItem { [weak self] in
            if self?.model.banner == banner { self?.model.banner = nil }
        }
        bannerTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Placement, hover and tucking away

    private func show(_ how: Opening) {
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
            opening = how
        } else if how == .user {
            opening = .user // opened on purpose now: stop tucking it away
        }
        lastActive = Date()
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// The notch (or the middle of the menu bar on Macs without one), widened a little so it's easy to hit.
    private var notchRect: CGRect {
        guard let screen else { return .zero }
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        var width: CGFloat = 200
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width {
            width = screen.frame.width - left - right
        }
        return CGRect(x: screen.frame.midX - width / 2 - 16, y: screen.frame.maxY - height, width: width + 32, height: height)
    }

    /// Centred under the notch, just below the menu bar.
    private func position() {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(Self.defaultSize.width, visible.width - 40), height: min(Self.defaultSize.height, visible.height - 24))
        panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: visible.maxY - size.height - 6, width: size.width, height: size.height), display: true)
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        guard panel.isVisible else {
            // Hovering the notch for a moment opens the chat, like the old notch island did.
            if notchRect.contains(mouse) {
                if hoverStarted == nil { hoverStarted = now }
                if let started = hoverStarted, now.timeIntervalSince(started) > 0.2 {
                    hoverStarted = nil
                    show(.hover)
                }
            } else {
                hoverStarted = nil
            }
            return
        }
        guard opening != .user else { return }
        let inUse = panel.frame.insetBy(dx: -10, dy: -10).contains(mouse) || notchRect.contains(mouse) || panel.isKeyWindow
            || model.showSettings || model.banner != nil || !isIdle()
        if inUse {
            lastActive = now
        } else if now.timeIntervalSince(lastActive) > (opening == .hover ? 0.6 : 4) {
            close()
        }
    }
}

// MARK: - Root

private struct ChatRootView: View {
    @ObservedObject var model: ChatWindowModel
    @ObservedObject var controller: CompanionController
    @ObservedObject var agents: AgentManager
    @ObservedObject var timers: TimerManager
    @ObservedObject var buddy: BuddyModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, controller: controller, agents: agents, timers: timers)
                .frame(width: 256)
            Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
            ChatPane(model: model, controller: controller, agents: agents, buddy: buddy, close: close)
        }
        .background(DS.Colors.background)
        .clipShape(PixelRect(step: DS.Radius.large))
        .overlay(PixelRect(step: DS.Radius.large).strokeBorder(DS.Colors.borderStrong.opacity(0.7), lineWidth: 2))
        .overlay { if model.showSettings { SettingsSheet(model: model, controller: controller, buddy: buddy) } }
        .animation(.easeOut(duration: 0.16), value: model.showSettings)
        .animation(.easeOut(duration: 0.16), value: model.banner)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: ChatWindowModel
    @ObservedObject var controller: CompanionController
    @ObservedObject var agents: AgentManager
    @ObservedObject var timers: TimerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZoobieMark(size: 17)
                Text("ZOOBIE").font(DS.Fonts.pixel(19, weight: .bold)).tracking(1.5).foregroundStyle(DS.Colors.textPrimary)
                    .shadow(color: DS.glow.opacity(0.45), radius: 6)
                Spacer()
            }
            .padding(.top, 4)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
                    TextField("Search", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(PixelRect(step: DS.Radius.medium).fill(DS.Colors.surface2))
                Button {
                    controller.clear()
                    model.selected = nil
                    model.focusToken += 1
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                .help("New conversation with ZOOBIE")
            }
            if !timers.timers.isEmpty { TimerChips(timers: timers) }
            ScrollView {
                VStack(spacing: 4) {
                    if matches("ZOOBIE") { ZoobieRow(model: model, controller: controller) }
                    ForEach(Specialist.all.filter { matches(agents.name($0.id)) }) { specialist in
                        SpecialistRow(id: specialist.id, model: model, controller: controller, agents: agents)
                    }
                }
            }
            Spacer(minLength: 0)
            ProfileRow(model: model, controller: controller)
        }
        .padding(12)
        .background(ZStack { DS.Colors.surface1; DitherPattern(cell: 3, opacity: 0.05) })
    }

    private func matches(_ name: String) -> Bool {
        let query = model.search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }
}

private struct TimerChips: View {
    @ObservedObject var timers: TimerManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(timers.timers) { timer in
                    HStack(spacing: 6) {
                        Image(systemName: "timer").foregroundStyle(DS.Colors.accentBright)
                        Text(timer.label).foregroundStyle(DS.Colors.textSecondary).lineLimit(1)
                        Spacer()
                        Text(TimerManager.format(timer.remaining)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Button { _ = timers.cancel(timer.label) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(DS.Colors.textTertiary).help("Cancel timer")
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(8)
            .background(PixelRect(step: DS.Radius.medium).fill(DS.Colors.accent.opacity(0.08)))
        }
    }
}

/// One conversation in the sidebar: avatar, name, when it last moved, and a one-line preview.
private struct ConversationRow<Avatar: View>: View {
    let name: String
    let time: Date?
    let preview: String
    let selected: Bool
    var attention = false
    @ViewBuilder let avatar: () -> Avatar
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            avatar()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name).font(DS.Fonts.pixel(14)).foregroundStyle(DS.Colors.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    if attention {
                        Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(DS.Colors.warning)
                    } else if let time {
                        Text(ConversationTime.short(time)).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
                    }
                }
                Text(preview).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            PixelRect(step: DS.Radius.medium)
                .fill(selected ? DS.Colors.accent.opacity(0.16) : (hovering ? DS.Colors.surface2 : .clear))
        )
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(DS.Colors.accent).frame(width: 3, height: 24).shadow(color: DS.glow.opacity(0.8), radius: 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .dsPointerOnHover()
    }
}

enum ConversationTime {
    /// "Now", "5m", "3h", then the weekday, then the date.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if Calendar.current.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct ZoobieRow: View {
    @ObservedObject var model: ChatWindowModel
    @ObservedObject var controller: CompanionController

    var body: some View {
        ConversationRow(name: "ZOOBIE", time: controller.messages.last?.date, preview: preview, selected: model.selected == nil,
                        attention: controller.pendingAction != nil) {
            ZoobieAvatar(size: 34, busy: controller.isBusy)
        } select: {
            model.selected = nil
            model.focusToken += 1
        }
    }

    private var preview: String {
        if controller.pendingAction != nil { return "Needs your OK" }
        if controller.isBusy { return "Thinking…" }
        if let focused = controller.focused { return "Talking with \(controller.agents.name(focused))" }
        let last = controller.messages.last { $0.kind == .assistant && !$0.text.isEmpty }?.text
        return last.map { ReplyParsing.stripMarkdown($0.components(separatedBy: "\n").first ?? $0) } ?? "Ask anything, or tell me to do it"
    }
}

private struct SpecialistRow: View {
    let id: Specialist.ID
    @ObservedObject var model: ChatWindowModel
    @ObservedObject var controller: CompanionController
    @ObservedObject var agents: AgentManager

    var body: some View {
        let runs = agents.runs(for: id)
        let waiting = agents.approvals.contains { $0.agent == id }
        ConversationRow(name: agents.name(id), time: runs.map { $0.finishedAt ?? $0.createdAt }.max(),
                        preview: waiting ? "Needs your OK" : agents.statusLine(id), selected: model.selected == id, attention: waiting) {
            SpecialistAvatar(id: id, agents: agents, size: 34, busy: agents.current(id) != nil || controller.focused == id)
        } select: {
            model.selected = id
            model.focusToken += 1
        }
    }
}

private struct ProfileRow: View {
    @ObservedObject var model: ChatWindowModel
    @ObservedObject var controller: CompanionController

    var body: some View {
        HStack(spacing: 10) {
            Text(initials)
                .font(DS.Fonts.pixel(13, weight: .bold)).foregroundStyle(DS.Colors.textPrimary)
                .frame(width: 30, height: 30)
                .background(PixelRect(step: DS.Radius.small).fill(DS.Colors.surface3))
                .overlay(PixelRect(step: DS.Radius.small).strokeBorder(DS.Colors.borderStrong, lineWidth: 2))
            VStack(alignment: .leading, spacing: 1) {
                Text(NSFullUserName()).font(DS.Fonts.pixel(13)).foregroundStyle(DS.Colors.textPrimary).lineLimit(1)
                Text(brain).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: controller.openOnboarding) { Image(systemName: "questionmark.circle") }
                .buttonStyle(.plain).foregroundStyle(DS.Colors.textSecondary).help("Setup guide").dsPointerOnHover()
            Button { model.showSettings = true } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(.plain).foregroundStyle(DS.Colors.textSecondary).help("Settings").dsPointerOnHover()
        }
        .font(.system(size: 14))
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1) }
    }

    private var initials: String {
        let parts = NSFullUserName().split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var brain: String {
        controller.usesClaude && controller.hasAPIKey ? "Claude · \(controller.config.claudeModel)" : "Local · \(controller.config.chatModel)"
    }
}

// MARK: - Chat pane

private struct ChatPane: View {
    @ObservedObject var model: ChatWindowModel
    @ObservedObject var controller: CompanionController
    @ObservedObject var agents: AgentManager
    @ObservedObject var buddy: BuddyModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.banner {
                BannerView(banner: banner, dismiss: { model.banner = nil })
                    .padding(.horizontal, 16).padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let id = model.selected {
                SpecialistThread(id: id, agents: agents)
            } else {
                ZoobieThread(controller: controller)
            }
            Composer(model: model, controller: controller, agents: agents, buddy: buddy)
        }
        .background(
            // A faint hologram glow high in the frame over the avatars' checker texture.
            ZStack {
                DitherPattern(cell: 3, opacity: 0.035)
                RadialGradient(colors: [DS.Colors.accent.opacity(0.06), .clear], center: .top, startRadius: 0, endRadius: 420)
            }
        )
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 8) {
                if let id = model.selected {
                    SpecialistAvatar(id: id, agents: agents, size: 26, busy: agents.current(id) != nil)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(agents.name(id)).font(DS.Fonts.pixel(15, weight: .bold)).foregroundStyle(DS.Colors.textPrimary)
                        Text(Specialist.get(id).role).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
                    }
                } else {
                    ZoobieAvatar(size: 26, busy: controller.isBusy)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("ZOOBIE").font(DS.Fonts.pixel(15, weight: .bold)).foregroundStyle(DS.Colors.textPrimary)
                        Text(controller.isBusy ? "Working…" : "Answers and acts on your Mac").font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
                    }
                }
            }
            .frame(maxWidth: 360)
            HStack(spacing: 6) {
                Spacer()
                headerActions
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(DS.Colors.textSecondary).help("Close (Esc)").dsPointerOnHover()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1) }
    }

    @ViewBuilder private var headerActions: some View {
        if let id = model.selected {
            if id == .german {
                Toggle(isOn: $agents.germanSpeechInput) {
                    Text("I'll speak German").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                }
                .toggleStyle(.switch).controlSize(.mini).tint(DS.Colors.accent)
            }
            let talking = controller.focused == id
            Button(talking ? "Talking" : "Talk") { controller.talk(to: talking ? nil : id) }
                .buttonStyle(DSButtonStyle(kind: talking ? .primary : .secondary, compact: true))
                .help(talking ? "Your voice goes to \(agents.name(id)) — click to go back to ZOOBIE" : "Talk with \(agents.name(id)) by voice")
            Menu {
                Button("Clear finished tasks") { agents.clearFinished(id) }
                Button("Forget memory and conversation") { agents.clearMemory(id) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(DS.Colors.textSecondary)
        } else {
            if let focused = controller.focused {
                Button("Back to ZOOBIE") { controller.talk(to: nil) }.buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                    .help("You're talking with \(agents.name(focused))")
            }
            Button(action: controller.clear) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(DS.Colors.textSecondary).help("Clear conversation").dsPointerOnHover()
        }
    }
}

// MARK: - ZOOBIE conversation

private struct ZoobieThread: View {
    @ObservedObject var controller: CompanionController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.messages.isEmpty { EmptyChatHint() }
                    ForEach(controller.messages) { message in
                        ChatMessageRow(message: message).id(message.id)
                    }
                    if controller.isBusy, controller.pendingAction == nil, !isStreamingText {
                        WorkingRow(since: controller.busySince ?? Date())
                    }
                    if let action = controller.pendingAction {
                        ApprovalCard(title: "\(action.title)?", action: action,
                                     stop: { controller.decide(.stop) }, skip: { controller.decide(.skip) }, run: { controller.decide(.run) })
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: controller.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: controller.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: controller.pendingAction) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// While the reply is visibly streaming, the bubble itself shows progress.
    private var isStreamingText: Bool {
        guard let last = controller.messages.last else { return false }
        return last.kind == .assistant && !last.text.isEmpty
    }
}

private struct EmptyChatHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What do you need?").font(DS.Fonts.pixel(26, weight: .bold)).foregroundStyle(DS.Colors.textPrimary)
            Text("Ask a question, or tell ZOOBIE to do something on your Mac. Say “agent: …” to hand a longer job to a specialist.")
                .font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                KeyHint(key: "⌃⌥", label: "hold to talk")
                KeyHint(key: "⌃⌥Space", label: "open and type")
                KeyHint(key: "esc", label: "stop or close")
            }
            .padding(.top, 4)
        }
        .padding(.top, 40)
        .frame(maxWidth: 460, alignment: .leading)
    }
}

private struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(DS.Colors.textPrimary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(PixelRect(step: DS.Radius.small).fill(DS.Colors.surface3))
            Text(label).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
        }
    }
}

struct ChatMessageRow: View {
    let message: DisplayMessage

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text).font(.system(size: 13)).foregroundStyle(DS.Colors.onAccent).textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(PixelRect(step: DS.Radius.large).fill(DS.accentGradient))
                    .shadow(color: DS.glow.opacity(0.25), radius: 6, y: 2)
            }
        case .assistant:
            if !message.text.isEmpty {
                HStack {
                    MarkdownView(text: message.text)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(PixelRect(step: DS.Radius.large).fill(DS.Colors.surface2))
                        .overlay(PixelRect(step: DS.Radius.large).strokeBorder(DS.Colors.borderSubtle))
                    Spacer(minLength: 60)
                }
            }
        case .step:
            if let action = message.action { StepCard(action: action, state: message.stepState ?? .awaiting).frame(maxWidth: 520, alignment: .leading) }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(DS.Colors.danger).textSelection(.enabled)
        case .note:
            Text(message.text).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// "● ● ●  Working on it · 7s"
struct WorkingRow: View {
    let since: Date

    var body: some View {
        HStack(spacing: 10) {
            TypingIndicator()
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(PixelRect(step: DS.Radius.small).fill(DS.Colors.surface2))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Working on it · \(max(0, Int(context.date.timeIntervalSince(since))))s")
                    .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
            }
        }
    }
}

// MARK: - Specialist conversation

private struct SpecialistThread: View {
    let id: Specialist.ID
    @ObservedObject var agents: AgentManager

    var body: some View {
        let runs = agents.runs(for: id).sorted { $0.createdAt < $1.createdAt }
        // Re-read when the thread changes (memoryVersion bumps on every new exchange).
        let thread = agents.memoryVersion >= 0 ? Array(agents.memory.thread(id).suffix(30)) : []
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if runs.isEmpty && thread.isEmpty {
                        SpecialistIntro(id: id, agents: agents)
                    }
                    ForEach(Array(thread.enumerated()), id: \.offset) { _, message in
                        ChatMessageRow(message: DisplayMessage(kind: message.role == .user ? .user : .assistant, text: message.content))
                    }
                    ForEach(runs) { run in RunExchange(run: run, agents: agents) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: runs.last?.steps.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: runs.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct SpecialistIntro: View {
    let id: Specialist.ID
    @ObservedObject var agents: AgentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SpecialistAvatar(id: id, agents: agents, size: 52)
            Text(agents.name(id)).font(DS.Fonts.pixel(26, weight: .bold)).foregroundStyle(DS.Colors.textPrimary)
            Text(Specialist.get(id).role).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Give it a task below. It works in the background, shows its progress here, and tells you when it's done.")
                .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 30)
        .frame(maxWidth: 460, alignment: .leading)
    }
}

/// One background task as a chat exchange: the task, its progress, then the result.
private struct RunExchange: View {
    let run: AgentRun
    @ObservedObject var agents: AgentManager
    @State private var showSteps = false
    @State private var showReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChatMessageRow(message: DisplayMessage(kind: .user, text: run.task))
            if !run.steps.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.15)) { showSteps.toggle() } } label: {
                    Label("\(run.steps.count) progress message\(run.steps.count == 1 ? "" : "s")", systemImage: showSteps ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain).dsPointerOnHover()
                if showSteps {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                            Label(step, systemImage: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary).lineLimit(2)
                        }
                    }
                    .padding(.leading, 6)
                }
            }
            result
        }
    }

    @ViewBuilder private var result: some View {
        switch run.status {
        case .queued:
            Label("Queued — starts after the current task", systemImage: "clock").font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
        case .running:
            HStack {
                WorkingRow(since: run.createdAt)
                Button("Stop") { agents.cancel(run.id) }.buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
            }
        case .waiting:
            ForEach(agents.approvals.filter { $0.runID == run.id }) { approval in
                ApprovalCard(title: "\(approval.agent.map(agents.name) ?? "Your agent") wants to: \(approval.action.title)", action: approval.action,
                             stop: { agents.decide(approval.id, .stop) }, skip: { agents.decide(approval.id, .skip) }, run: { agents.decide(approval.id, .run) })
            }
        case .done:
            VStack(alignment: .leading, spacing: 8) {
                ChatMessageRow(message: DisplayMessage(kind: .assistant, text: run.summary ?? "Done."))
                if let report = run.report, !report.isEmpty {
                    HStack(spacing: 6) {
                        Button(showReport ? "Hide report" : "Read report") { withAnimation(.easeOut(duration: 0.15)) { showReport.toggle() } }
                            .buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                        if let path = run.reportPath {
                            Button("Open file") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                        .buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                    }
                    if showReport {
                        MarkdownView(text: report)
                            .padding(12)
                            .background(PixelRect(step: DS.Radius.large).fill(DS.Colors.surface1))
                            .overlay(PixelRect(step: DS.Radius.large).strokeBorder(DS.Colors.borderSubtle))
                    }
                }
            }
        case .failed, .cancelled:
            HStack(spacing: 8) {
                Label(run.error ?? (run.status == .failed ? "Failed" : "Stopped"), systemImage: run.status == .failed ? "exclamationmark.triangle.fill" : "stop.circle")
                    .font(.system(size: 12)).foregroundStyle(run.status == .failed ? DS.Colors.danger : DS.Colors.textTertiary)
                    .textSelection(.enabled)
                Button { agents.remove(run.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(DSButtonStyle(kind: .ghost, compact: true)).help("Remove")
            }
        }
    }
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var model: ChatWindowModel
    @ObservedObject var controller: CompanionController
    @ObservedObject var agents: AgentManager
    @ObservedObject var buddy: BuddyModel
    @State private var taskDraft = ""
    @State private var taskError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let taskError {
                Text(taskError).font(.system(size: 11)).foregroundStyle(DS.Colors.warning).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                MicButton(listening: buddy.mode == .listening, action: controller.toggleVoice)
                HStack(alignment: .bottom, spacing: 8) {
                    if model.selected == nil {
                        Button { controller.includeScreen.toggle() } label: {
                            Image(systemName: controller.includeScreen ? "eye" : "eye.slash").frame(height: 20)
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.Colors.textTertiary).dsPointerOnHover()
                        .help(controller.includeScreen ? "ZOOBIE may read your screen when you ask about it" : "Screen reading is off")
                    }
                    TextField(placeholder, text: text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(send)
                        .disabled(model.selected == nil && controller.pendingAction != nil)
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Colors.onAccent)
                            .frame(width: 26, height: 26)
                            .background(PixelRect(step: DS.Radius.small).fill(canSend ? DS.Colors.accent : DS.Colors.surface3))
                    }
                    .buttonStyle(.plain).disabled(!canSend).dsPointerOnHover().help("Send (Return)")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(PixelRect(step: DS.Radius.large).fill(DS.Colors.surface1))
                .overlay(PixelRect(step: DS.Radius.large)
                    .strokeBorder(focused ? DS.Colors.accent.opacity(0.7) : DS.Colors.borderStrong.opacity(0.6), lineWidth: focused ? 1.5 : 1))
                .shadow(color: focused ? DS.glow.opacity(0.18) : .clear, radius: 8)
                if showsStop {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.system(size: 12)).foregroundStyle(DS.Colors.textPrimary)
                            .frame(width: 38, height: 38).background(PixelRect(step: DS.Radius.medium).fill(DS.Colors.surface3))
                    }
                    .buttonStyle(.plain).dsPointerOnHover().help("Stop (Esc)")
                }
            }
            Text("Return to send · Shift-Return for a new line · hold ⌃⌥ to talk")
                .font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        .onChange(of: model.focusToken, initial: true) { focused = true }
        .onChange(of: model.selected) { taskError = nil }
    }

    private var placeholder: String {
        if let id = model.selected { return "Give \(agents.name(id)) a task…" }
        if let focused = controller.focused { return "Message \(agents.name(focused))…" }
        return controller.pendingAction != nil ? "Waiting for your OK…" : "Message ZOOBIE…"
    }

    private var text: Binding<String> {
        model.selected == nil ? $controller.input : $taskDraft
    }

    private var canSend: Bool { !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var showsStop: Bool {
        if let id = model.selected { return agents.current(id) != nil }
        return controller.isBusy
    }

    private func send() {
        guard canSend else { return }
        if let id = model.selected {
            let task = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = task.split(separator: " ").prefix(6).joined(separator: " ")
            taskError = agents.delegate(to: id, title: title, task: task)
            if taskError == nil { taskDraft = "" }
        } else {
            controller.submitInput()
        }
    }

    private func stop() {
        if let id = model.selected, let run = agents.current(id) { agents.cancel(run.id) } else { controller.cancelWork() }
    }
}

private struct MicButton: View {
    let listening: Bool
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.Colors.onAccent)
                .frame(width: 42, height: 42)
                .background(PixelRect(step: DS.Radius.medium).fill(DS.accentGradient))
                .overlay(PixelRect(step: DS.Radius.medium).strokeBorder(DS.Colors.accentBright.opacity(listening ? 1 : 0.5), lineWidth: 2))
                .shadow(color: DS.glow.opacity(listening ? 0.9 : 0.45), radius: listening ? 14 : 7)
                .scaleEffect(listening && pulse ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .dsPointerOnHover()
        .help(listening ? "Stop listening and send" : "Click to talk (or hold ⌃⌥ anywhere)")
        .onChange(of: listening, initial: true) { _, now in
            if now {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { pulse = false }
            }
        }
    }
}

// MARK: - Cards and banners

/// "Okay to do this?" for ZOOBIE's own steps and the specialists' — Return runs, ⌘S skips.
private struct ApprovalCard: View {
    let title: String
    let action: AgentAction
    let stop: () -> Void
    let skip: () -> Void
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(DS.Colors.warning)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.textPrimary).lineLimit(2)
                if action.isDestructive {
                    Text("CAUTION").font(.system(size: 9, weight: .heavy)).foregroundStyle(DS.Colors.danger)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .overlay(PixelRect(step: 1).strokeBorder(DS.Colors.danger))
                }
                Spacer()
            }
            ScrollView {
                Text(action.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(DS.Colors.codeText)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130).fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(PixelRect(step: DS.Radius.medium).fill(DS.Colors.codeBackground))
            HStack(spacing: 8) {
                Text("↩ run · ⌘S skip · esc stop").font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
                Spacer()
                Button("Stop", action: stop).buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                Button("Skip", action: skip).keyboardShortcut("s", modifiers: .command).buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                Button("Run", action: run).keyboardShortcut(.defaultAction)
                    .buttonStyle(DSButtonStyle(kind: action.isDestructive ? .destructive : .primary, compact: true))
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(PixelRect(step: DS.Radius.large).fill(DS.Colors.surface1))
        .overlay(PixelRect(step: DS.Radius.large).strokeBorder(DS.Colors.warning.opacity(0.5)))
    }
}

private struct BannerView: View {
    let banner: ChatWindowModel.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch banner {
            case .notice(let text):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DS.Colors.warning)
                Text(text).font(.system(size: 12)).foregroundStyle(DS.Colors.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .toast(let text):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.Colors.success)
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.textPrimary)
            case .setup(let missing):
                Image(systemName: "lock.shield.fill").foregroundStyle(DS.Colors.accentBright)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ZOOBIE needs permission to act").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textPrimary)
                    ForEach(missing, id: \.self) { kind in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textPrimary)
                                Text(kind.purpose).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                            }
                            Spacer()
                            Button("Open Settings") { NSWorkspace.shared.open(kind.settingsURL) }.buttonStyle(DSButtonStyle(kind: .primary, compact: true))
                        }
                    }
                    Text("Turn ZOOBIE on in each list (remove any old “Companion” entry first). Screen Recording needs a relaunch.")
                        .font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(DS.Colors.textTertiary).dsPointerOnHover()
        }
        .padding(12)
        .background(PixelRect(step: DS.Radius.large).fill(DS.Colors.surface2))
        .overlay(PixelRect(step: DS.Radius.large).strokeBorder(DS.Colors.borderSubtle))
    }
}

private struct SettingsSheet: View {
    @ObservedObject var model: ChatWindowModel
    @ObservedObject var controller: CompanionController
    @ObservedObject var buddy: BuddyModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { model.showSettings = false }
            VStack(spacing: 0) {
                HStack {
                    Text("Settings").font(DS.Fonts.pixel(18, weight: .bold)).foregroundStyle(DS.Colors.textPrimary)
                    Spacer()
                    Button { model.showSettings = false } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(DS.Colors.textSecondary).dsPointerOnHover()
                }
                .padding(14)
                ScrollView {
                    MenuBarPanelView(controller: controller, buddy: buddy, openOnboarding: controller.openOnboarding, embedded: true)
                        .padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
            .frame(width: 480, height: 500)
            .background(PixelRect(step: DS.Radius.large).fill(DS.Colors.surface1))
            .overlay(PixelRect(step: DS.Radius.large).strokeBorder(DS.Colors.borderSubtle))
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
        .transition(.opacity)
    }
}

// MARK: - Avatars

/// ZOOBIE's face: its pixel pointer on a dithered tile.
struct ZoobieAvatar: View {
    var size: CGFloat = 34
    var busy = false

    var body: some View {
        ZStack {
            PixelRect(step: DS.Radius.medium).fill(DS.Colors.surface3)
            DitherPattern(cell: 2, opacity: 0.1).clipShape(PixelRect(step: DS.Radius.medium))
            ZoobieMark(size: size * 0.55).offset(x: size * 0.05, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .overlay(PixelRect(step: DS.Radius.medium).strokeBorder(busy ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: 2))
        .shadow(color: busy ? DS.glow.opacity(0.55) : .clear, radius: busy ? 6 : 0)
    }
}

/// A specialist's face in a square pixel frame, like the portraits: its avatar image (Resources/avatars or the
/// user's own), otherwise its symbol.
struct SpecialistAvatar: View {
    let id: Specialist.ID
    @ObservedObject var agents: AgentManager
    var size: CGFloat = 34
    var busy = false

    var body: some View {
        ZStack {
            if let image = agents.avatar(id) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                PixelRect(step: DS.Radius.medium).fill(DS.Colors.surface3)
                Image(systemName: Specialist.get(id).symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(DS.accentGradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(PixelRect(step: DS.Radius.medium))
        .overlay(PixelRect(step: DS.Radius.medium).strokeBorder(busy ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: 2))
        .shadow(color: busy ? DS.glow.opacity(0.55) : .clear, radius: busy ? 6 : 0)
    }
}

// MARK: - Design previews

#if DEBUG
extension ChatWindowController {
    /// Draws the window (ZOOBIE's conversation, then a specialist's) to PNGs without showing it.
    /// Part of `Companion --render-previews <dir>`.
    static func renderPreviews(controller: CompanionController, to directory: URL) throws {
        for (name, selected) in [("chat-zoobie", nil), ("chat-specialist", Specialist.ID.jobs)] as [(String, Specialist.ID?)] {
            let model = ChatWindowModel()
            model.selected = selected
            let root = ChatRootView(model: model, controller: controller, agents: controller.agents, timers: controller.timers,
                                    buddy: controller.buddy.model, close: {})
            // An offscreen window renders text fields and scroll views, which ImageRenderer can't.
            let host = NSHostingView(rootView: root.frame(width: defaultSize.width, height: defaultSize.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: defaultSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .clear
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
#endif
