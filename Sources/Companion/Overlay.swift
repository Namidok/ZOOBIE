import AppKit
import Combine
import CompanionCore
import SwiftUI

// MARK: - On-screen highlights

@MainActor
final class HighlightModel: ObservableObject {
    struct Box: Identifiable, Equatable {
        let id = UUID()
        var rect: CGRect
    }

    @Published var boxes: [Box] = []
}

/// Draws glowing outlines around on-screen elements, one click-through window per display.
/// The windows are only ordered in while something is highlighted.
@MainActor
final class HighlightOverlay {
    private let model = HighlightModel()
    private var windows: [(frame: CGRect, window: NSWindow)] = []
    private var hideWork: DispatchWorkItem?

    /// `rects` are in AppKit global coordinates (e.g. OCR element frames).
    func show(_ rects: [CGRect]) {
        hideWork?.cancel()
        ensureWindows()
        model.boxes = rects.map { HighlightModel.Box(rect: $0) }
        for (frame, window) in windows where rects.contains(where: { $0.intersects(frame) }) {
            window.orderFrontRegardless()
        }
    }

    func clear() {
        guard !model.boxes.isEmpty else { return }
        model.boxes = []
        let work = DispatchWorkItem { [weak self] in self?.windows.forEach { $0.window.orderOut(nil) } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work) // let the fade finish
    }

    private func ensureWindows() {
        let frames = NSScreen.screens.map(\.frame)
        guard frames != windows.map(\.frame) else { return }
        windows.forEach { $0.window.orderOut(nil) }
        windows = frames.map { frame in
            let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) - 1) // just under the buddy
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: HighlightView(model: model, screenFrame: frame))
            window.setFrame(frame, display: false)
            return (frame, window)
        }
    }
}

private struct HighlightView: View {
    @ObservedObject var model: HighlightModel
    let screenFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.boxes.filter { $0.rect.intersects(screenFrame) }) { box in
                let rect = box.rect.insetBy(dx: -6, dy: -4)
                HighlightBox()
                    .frame(width: rect.width, height: rect.height)
                    // AppKit is bottom-left origin; SwiftUI is top-left within this screen's window.
                    .position(x: rect.midX - screenFrame.minX, y: screenFrame.maxY - rect.midY)
                    .transition(.asymmetric(insertion: .scale(scale: 1.3).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.boxes)
    }
}

private struct HighlightBox: View {
    @State private var glow = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(BuddyStyle.glow.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(BuddyStyle.gradient, lineWidth: 2.5))
            .shadow(color: BuddyStyle.glow.opacity(glow ? 0.9 : 0.45), radius: glow ? 12 : 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { glow = true }
            }
    }
}

// MARK: - Cursor card

@MainActor
final class CardModel: ObservableObject {
    enum Content: Equatable {
        case input
        case code([CodeSnippet])
        case approval(AgentAction)
        case notice(String)
        case setup([Permissions.Kind])
    }

    @Published var content: Content?
    @Published var focusToken = 0
}

private struct OptionalSurface: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.dsSurface() } else { content }
    }
}

struct CardView: View {
    @ObservedObject var model: CardModel
    @ObservedObject var controller: CompanionController
    /// Inside the notch: no surface of its own.
    var embedded = false
    @FocusState private var inputFocused: Bool

    init(model: CardModel, controller: CompanionController, embedded: Bool = false) {
        self.model = model
        self.controller = controller
        self.embedded = embedded
    }

    var body: some View {
        Group {
            switch model.content {
            case .input?: inputView
            case .code(let snippets)?: codeView(snippets)
            case .approval(let action)?: approvalView(action)
            case .notice(let text)?: noticeView(text)
            case .setup(let missing)?: setupView(missing)
            case nil: EmptyView()
            }
        }
        .modifier(OptionalSurface(enabled: !embedded))
        .onExitCommand { controller.escape() }
        .onChange(of: model.focusToken) { inputFocused = true }
    }

    // MARK: Input

    private var inputView: some View {
        let isAgent = controller.input.lowercased().hasPrefix(Prompts.agentPrefix)
        return HStack(spacing: 10) {
            Image(systemName: isAgent ? "terminal.fill" : "sparkle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isAgent ? AnyShapeStyle(Color.orange) : AnyShapeStyle(BuddyStyle.gradient))
            TextField("Ask about your screen · “agent:” runs tasks", text: $controller.input)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($inputFocused)
                .onSubmit { controller.submitInput() }
            Button { controller.includeScreen.toggle() } label: {
                Image(systemName: controller.includeScreen ? "eye" : "eye.slash")
            }
            .help(controller.includeScreen ? "Screen is included (\(controller.screenSummary ?? "reading…"))" : "Screen is not included")
            Button(action: controller.showHistory) { Image(systemName: "clock.arrow.circlepath") }
                .help("History")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(width: 420, height: 46)
    }

    // MARK: Code

    private func codeView(_ snippets: [CodeSnippet]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(snippets.count > 1 ? "\(snippets.count) snippets" : "Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: controller.dismissCard) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
            }
            ForEach(Array(snippets.enumerated()), id: \.offset) { _, snippet in
                let lines = snippet.code.split(separator: "\n", omittingEmptySubsequences: false).count
                if lines > 14 {
                    ScrollView(.vertical) { CodeBlock(language: snippet.language, code: snippet.code) }
                        .frame(height: 250)
                } else {
                    CodeBlock(language: snippet.language, code: snippet.code)
                }
            }
        }
        .padding(10)
        .frame(width: 460)
    }

    // MARK: Approval

    private func approvalView(_ action: AgentAction) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(DS.Colors.warning)
                Text("\(action.title)?").font(.system(size: 13, weight: .semibold))
                if action.isDestructive {
                    Text("CAUTION")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.danger))
                }
                Spacer()
            }
            Text(action.detail)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            HStack(spacing: 8) {
                Text("↩ run · ⌘S skip · esc stop").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { controller.decide(.stop) }.buttonStyle(DSButtonStyle(kind: .ghost, compact: true))
                Button("Skip") { controller.decide(.skip) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                Button("Run") { controller.decide(.run) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DSButtonStyle(kind: action.isDestructive ? .destructive : .primary, compact: true))
            }
        }
        .padding(12)
        .frame(width: 420)
    }

    // MARK: Setup

    private func setupView(_ missing: [Permissions.Kind]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundStyle(DS.Colors.accent)
                Text("ZOOBIE needs permission to act").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: controller.dismissCard) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            ForEach(missing, id: \.self) { kind in
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed").foregroundStyle(DS.Colors.warning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.rawValue).font(.system(size: 12, weight: .semibold))
                        Text(kind.purpose).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") { NSWorkspace.shared.open(kind.settingsURL) }
                        .buttonStyle(DSButtonStyle(kind: .primary, compact: true))
                }
            }
            Text("Turn ZOOBIE on in each list (remove any old “Companion” entry first), then reopen Settings from the notch. Screen Recording needs a relaunch.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 400)
    }

    // MARK: Notice

    private func noticeView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DS.Colors.warning)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: controller.dismissCard) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 360)
    }
}
