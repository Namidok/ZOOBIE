import AppKit
import Combine
import CompanionCore
import SwiftUI

// MARK: - Window

final class NotchPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }

    /// The notch never activates the app, so the Edit menu doesn't see ⌘V and friends — route them here.
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
final class NotchModel: ObservableObject {
    enum Tab: String, CaseIterable { case assistant = "Assistant", agents = "Agents", settings = "Settings" }

    @Published var expanded = false
    @Published var tab: Tab = .assistant
    @Published var toast: String?
    @Published var hovering = false
    /// Measured size of the content shown under the notch (set by the view).
    @Published var contentSize: CGSize = .zero
    var notchSize = CGSize(width: 200, height: 32)
    var hasNotch = false
    /// The shape's current size, for hit-testing (written by the view, read by the controller).
    var currentShapeSize: CGSize = .zero
}

/// ZOOBIE's home: a black shape that grows out of the MacBook notch (or a pill at the top of the screen
/// on Macs without one). It shows live activity, captions, cards and approvals, and expands on hover
/// into the Assistant, Agents and Settings tabs. Clicks pass through everywhere outside the shape.
@MainActor
final class NotchController {
    static let canvas = CGSize(width: 760, height: 560)

    let model = NotchModel()
    let cardModel = CardModel()
    private let panel: NotchPanel
    private weak var controller: CompanionController?
    private var timer: Timer?
    private var hoverStarted: Date?
    private var leftAt: Date?
    private var outsideClickMonitor: Any?
    private var autoHide: DispatchWorkItem?
    private var screenObserver: Any?

    init(controller: CompanionController, agents: AgentManager) {
        self.controller = controller
        panel = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.canvas),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: NotchView(
            model: model, card: cardModel, controller: controller, buddy: controller.buddy.model, agents: agents
        ))
        panel.onEscape = { [weak controller] in controller?.escape() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
    }

    func start() {
        position()
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Card API (what used to be the cursor card)

    var content: CardModel.Content? { cardModel.content }
    var isVisible: Bool { cardModel.content != nil }
    var isKey: Bool { panel.isKeyWindow }

    func show(_ content: CardModel.Content, focus: Bool, autoHideAfter delay: TimeInterval? = nil) {
        autoHide?.cancel()
        cardModel.content = content
        if focus {
            panel.makeKeyAndOrderFront(nil)
            cardModel.focusToken += 1
            watchOutsideClicks()
        }
        if let delay {
            let work = DispatchWorkItem { [weak self] in
                if self?.cardModel.content == content { self?.hide() }
            }
            autoHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func hide() {
        autoHide?.cancel()
        cardModel.content = nil
        if !model.expanded { resignKey() }
    }

    func expand(tab: NotchModel.Tab) {
        model.tab = tab
        model.expanded = true
        panel.makeKeyAndOrderFront(nil)
        watchOutsideClicks()
    }

    func toggle(tab: NotchModel.Tab) {
        if model.expanded && model.tab == tab { collapse() } else { expand(tab: tab) }
    }

    func collapse() {
        model.expanded = false
        if cardModel.content == nil { resignKey() }
    }

    func toast(_ text: String, seconds: TimeInterval = 6) {
        model.toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.model.toast == text { self?.model.toast = nil }
        }
    }

    // MARK: Placement & mouse

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func position() {
        guard let screen else { return }
        let hasNotch = screen.safeAreaInsets.top > 0
        if hasNotch, let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width {
            model.notchSize = CGSize(width: screen.frame.width - left - right, height: screen.safeAreaInsets.top)
        } else {
            model.notchSize = CGSize(width: 190, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
        }
        model.hasNotch = hasNotch
        panel.setFrame(CGRect(x: screen.frame.midX - Self.canvas.width / 2, y: screen.frame.maxY - Self.canvas.height,
                              width: Self.canvas.width, height: Self.canvas.height), display: true)
    }

    /// The shape's rectangle in screen coordinates.
    private func shapeRect(margin: CGFloat = 0) -> CGRect {
        guard let screen else { return .zero }
        var size = model.currentShapeSize
        if size == .zero { size = model.notchSize }
        return CGRect(x: screen.frame.midX - size.width / 2 - margin, y: screen.frame.maxY - size.height - margin,
                      width: size.width + margin * 2, height: size.height + margin)
    }

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let inside = shapeRect(margin: model.expanded ? 0 : 6).contains(mouse)
        // Only the shape catches clicks; everything around it stays usable.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if model.hovering != inside { model.hovering = inside }

        if inside {
            leftAt = nil
            if !model.expanded {
                if hoverStarted == nil { hoverStarted = Date() }
                if let started = hoverStarted, Date().timeIntervalSince(started) > 0.18, cardModel.content == nil {
                    model.expanded = true
                }
            }
        } else {
            hoverStarted = nil
            // Collapse after the mouse leaves, unless the user is typing in it (then an outside click closes it).
            if model.expanded && !panel.isKeyWindow && !shapeRect(margin: 24).contains(mouse) {
                if leftAt == nil { leftAt = Date() }
                if let left = leftAt, Date().timeIntervalSince(left) > 0.35 {
                    model.expanded = false
                    leftAt = nil
                }
            }
        }
    }

    private func watchOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.expanded { self.model.expanded = false }
                if self.cardModel.content == .input { self.cardModel.content = nil }
                self.resignKey()
            }
        }
    }

    private func resignKey() {
        if panel.isKeyWindow { panel.resignKey() }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

// MARK: - Shape

/// Black notch silhouette: top corners curve outward into the menu bar, bottom corners round inward.
struct NotchShape: Shape {
    var topRadius: CGFloat = 6
    var bottomRadius: CGFloat = 14

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = min(bottomRadius, rect.height / 2, (rect.width - 2 * top) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct ContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - View

private struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var card: CardModel
    @ObservedObject var controller: CompanionController
    @ObservedObject var buddy: BuddyModel
    @ObservedObject var agents: AgentManager

    private enum Compact: Equatable {
        case card(CardModel.Content)
        case approval(UUID)
        case toast(String)
        case caption(String)
    }

    private static let wing: CGFloat = 46
    private static let expandedSize = CGSize(width: 640, height: 410)

    private var compact: Compact? {
        if let content = card.content { return .card(content) }
        if let approval = agents.approvals.first { return .approval(approval.id) }
        if let toast = model.toast { return .toast(toast) }
        if let caption = buddy.caption, !caption.isEmpty { return .caption(caption) }
        return nil
    }

    private var isActive: Bool { buddy.mode != .idle || agents.activeCount > 0 || compact != nil }

    private var shapeSize: CGSize {
        let notch = model.notchSize
        if model.expanded {
            return CGSize(width: Self.expandedSize.width, height: notch.height + Self.expandedSize.height)
        }
        if compact != nil {
            let width = max(notch.width + Self.wing * 2, min(600, model.contentSize.width + 32))
            return CGSize(width: width, height: notch.height + model.contentSize.height + 18)
        }
        if isActive || model.hovering { return CGSize(width: notch.width + Self.wing * 2, height: notch.height) }
        return notch
    }

    var body: some View {
        let size = shapeSize
        VStack(spacing: 0) {
            topBar
            if model.expanded {
                expandedContent
                    .frame(width: Self.expandedSize.width - 28, height: Self.expandedSize.height - 14)
                    .transition(.opacity)
            } else if let compact {
                compactContent(compact)
                    .fixedSize()
                    .background(GeometryReader { Color.clear.preference(key: ContentSizeKey.self, value: $0.size) })
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: 6, bottomRadius: model.expanded || compact != nil ? 22 : 12))
        .opacity(!model.hasNotch && !isActive && !model.expanded && !model.hovering ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ContentSizeKey.self) { model.contentSize = $0 }
        .onChange(of: size, initial: true) { _, newSize in model.currentShapeSize = newSize }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: size)
        .animation(.easeOut(duration: 0.18), value: model.expanded)
    }

    // MARK: Top bar (the notch row: wings on either side of the camera)

    private var topBar: some View {
        HStack(spacing: 0) {
            leftWing.frame(width: Self.wing)
            Spacer(minLength: model.notchSize.width)
            rightWing.frame(width: Self.wing)
        }
        .frame(height: model.notchSize.height)
        .opacity(isActive || model.expanded || model.hovering ? 1 : 0)
    }

    @ViewBuilder private var leftWing: some View {
        switch buddy.mode {
        case .listening: NotchWaveform(levels: buddy.levels)
        case .thinking: NotchSpinner()
        case .speaking: NotchSpeakingBars()
        case .idle: ZoobieMark(size: 13)
        }
    }

    @ViewBuilder private var rightWing: some View {
        if agents.activeCount > 0 {
            HStack(spacing: 4) {
                NotchSpinner(size: 10)
                Text("\(agents.activeCount)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(DS.Colors.textPrimary)
            }
            .help("\(agents.activeCount) agent(s) working")
        } else if !agents.approvals.isEmpty {
            Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(DS.Colors.warning)
        } else if buddy.mode == .listening {
            Circle().fill(DS.Colors.danger).frame(width: 7, height: 7)
        }
    }

    // MARK: Compact content (under the notch)

    @ViewBuilder private func compactContent(_ compact: Compact) -> some View {
        switch compact {
        case .card:
            CardView(model: card, controller: controller, embedded: true)
        case .approval(let id):
            if let approval = agents.approvals.first(where: { $0.id == id }) {
                AgentApprovalView(approval: approval, agents: agents).frame(width: 440)
            }
        case .toast(let text):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.Colors.success)
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Colors.textPrimary).lineLimit(2)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        case .caption(let text):
            Text(buddy.captionStyle == .user ? "“\(text)”" : text)
                .font(.system(size: 13, weight: buddy.captionStyle == .spoken ? .medium : .regular))
                .italic(buddy.captionStyle == .user)
                .foregroundStyle(buddy.captionStyle == .spoken ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 460)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .id(text)
        }
    }

    // MARK: Expanded

    private var expandedContent: some View {
        VStack(spacing: 10) {
            DSSegmented(options: NotchModel.Tab.allCases.map { tab -> (NotchModel.Tab, String) in
                if tab == .agents && agents.activeCount > 0 { return (tab, "Agents · \(agents.activeCount)") }
                return (tab, tab.rawValue)
            }, selection: $model.tab)
            .frame(width: 330)
            switch model.tab {
            case .assistant: AssistantTab(controller: controller, card: card)
            case .agents: AgentsTab(agents: agents, controller: controller)
            case .settings:
                ScrollView { MenuBarPanelView(controller: controller, buddy: buddy, openOnboarding: controller.openOnboarding, embedded: true) }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - Assistant tab

private struct AssistantTab: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var card: CardModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(DS.accentGradient)
                TextField("Ask ZOOBIE, or tell it to do something…", text: $controller.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { controller.submitInput() }
                Button { controller.includeScreen.toggle() } label: {
                    Image(systemName: controller.includeScreen ? "eye" : "eye.slash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Colors.textSecondary)
                .help(controller.includeScreen ? "Your screen is included" : "Your screen is not included")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Colors.surface1))

            if let content = card.content, content != .input {
                CardView(model: card, controller: controller, embedded: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let exchange = latestExchange {
                            Text(exchange.question).font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary)
                            MarkdownView(text: exchange.answer)
                        } else {
                            Text("Hold ⌃⌥ and talk, or type here. Ask a question, give it something to do, or say “start an agent to…”.")
                                .font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Full history", action: controller.showHistory).buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                Spacer()
                if controller.isBusy {
                    Button("Stop", action: controller.cancelWork).buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                }
            }
        }
        .onAppear { focused = false }
    }

    private var latestExchange: (question: String, answer: String)? {
        guard let answer = controller.messages.last(where: { $0.kind == .assistant && !$0.text.isEmpty }),
              let index = controller.messages.firstIndex(where: { $0.id == answer.id }),
              let question = controller.messages[..<index].last(where: { $0.kind == .user }) else { return nil }
        return (question.text, answer.text)
    }
}

// MARK: - Agents tab

private struct AgentsTab: View {
    @ObservedObject var agents: AgentManager
    @ObservedObject var controller: CompanionController
    @State private var draft = ""
    @State private var error: String?
    @State private var selected: UUID?

    var body: some View {
        if let id = selected, let run = agents.runs.first(where: { $0.id == id }) {
            AgentDetail(run: run, agents: agents) { selected = nil }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(DS.Colors.accent)
                TextField("Give an agent a job — e.g. research the best 4K monitors under $500", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(start)
                Button("Start", action: start)
                    .buttonStyle(DSButtonStyle(kind: .primary, compact: true))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Colors.surface1))
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(DS.Colors.warning) }

            ForEach(agents.approvals) { approval in AgentApprovalView(approval: approval, agents: agents) }

            if agents.runs.isEmpty {
                Text("Agents work in the background while you keep going — research, comparisons, reports, file chores. Results land here and in ~/Documents/ZOOBIE.")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(agents.runs) { run in
                            AgentRow(run: run, agents: agents).onTapGesture { selected = run.id }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear finished", action: agents.clearFinished).buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                }
            }
        }
    }

    private func start() {
        let task = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        let title = String(task.split(separator: " ").prefix(6).joined(separator: " "))
        error = agents.start(title: title, task: task, config: controller.config)
        if error == nil { draft = "" }
    }
}

private struct AgentRow: View {
    let run: AgentRun
    @ObservedObject var agents: AgentManager

    var body: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.textPrimary).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
            }
            Spacer()
            Text(run.createdAt, style: .relative).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
            if run.status.isActive {
                Button { agents.cancel(run.id) } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(DSButtonStyle(kind: .ghost, compact: true)).help("Stop")
            } else {
                Button { agents.remove(run.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(DSButtonStyle(kind: .ghost, compact: true)).help("Remove")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Colors.surface1))
        .contentShape(Rectangle())
        .dsPointerOnHover()
    }

    private var subtitle: String {
        switch run.status {
        case .running: return run.steps.last ?? "Getting started…"
        case .waiting: return "Waiting for your OK"
        case .done: return run.summary ?? "Done"
        case .failed: return run.error ?? "Failed"
        case .cancelled: return run.error ?? "Stopped"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch run.status {
        case .running: NotchSpinner(size: 11)
        case .waiting: Image(systemName: "hand.raised.fill").foregroundStyle(DS.Colors.warning)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.success)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.danger)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(DS.Colors.textTertiary)
        }
    }
}

private struct AgentDetail: View {
    let run: AgentRun
    @ObservedObject var agents: AgentManager
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: back) { Label("Agents", systemImage: "chevron.left") }.buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                Spacer()
                if let path = run.reportPath {
                    Button("Open report") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                }
                if let report = run.report {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                }
                if run.status.isActive {
                    Button("Stop") { agents.cancel(run.id) }.buttonStyle(DSButtonStyle(kind: .destructive, compact: true))
                }
            }
            Text(run.title).font(.system(size: 15, weight: .bold)).foregroundStyle(DS.Colors.textPrimary)
            Text(run.task).font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let report = run.report, !report.isEmpty {
                        MarkdownView(text: report)
                    } else {
                        ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                            Label(step, systemImage: "arrow.turn.down.right")
                                .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary).lineLimit(2)
                        }
                        if let error = run.error { Text(error).font(.system(size: 12)).foregroundStyle(DS.Colors.danger) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AgentApprovalView: View {
    let approval: AgentManager.Approval
    @ObservedObject var agents: AgentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(DS.Colors.warning)
                Text("\(approval.title) wants to: \(approval.action.title)").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.textPrimary).lineLimit(1)
                if approval.action.isDestructive {
                    Text("CAUTION").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.danger))
                }
            }
            Text(approval.action.detail)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Colors.textSecondary).lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.Colors.surface2))
            HStack {
                Spacer()
                Button("Stop agent") { agents.decide(approval.id, .stop) }.buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                Button("Skip") { agents.decide(approval.id, .skip) }.buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                Button("Allow") { agents.decide(approval.id, .run) }
                    .buttonStyle(DSButtonStyle(kind: approval.action.isDestructive ? .destructive : .primary, compact: true))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Colors.surface1))
    }
}

// MARK: - Activity indicators

private struct NotchWaveform: View {
    let levels: [CGFloat]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.suffix(5).indices, id: \.self) { i in
                Capsule().fill(DS.accentGradient).frame(width: 2.5, height: 3 + levels.suffix(5)[i] * 13)
            }
        }
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

private struct NotchSpinner: View {
    var size: CGFloat = 13
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(DS.accentGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spin = true } }
    }
}

private struct NotchSpeakingBars: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { i in
                Capsule().fill(DS.accentGradient)
                    .frame(width: 2.5, height: phase ? CGFloat([12, 6, 14, 8][i]) : CGFloat([5, 12, 6, 11][i]))
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) { phase = true } }
    }
}
