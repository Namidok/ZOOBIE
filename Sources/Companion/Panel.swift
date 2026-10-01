import AppKit
import CompanionCore
import SwiftUI

/// Borderless floating panel that can take keyboard focus without activating the app,
/// so the user's IDE or terminal stays frontmost.
final class FloatingPanel: NSPanel {
    static let width: CGFloat = 480
    static let compactHeight: CGFloat = 124
    static let expandedHeight: CGFloat = 540

    private weak var controller: CompanionController?

    @MainActor
    init(controller: CompanionController) {
        self.controller = controller
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.compactHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: PanelView(controller: controller))
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { controller?.escape() }
    }

    /// Opens beside the cursor, flipping sides to stay on the visible screen.
    func place(near point: CGPoint, expanded: Bool) {
        let height = expanded ? Self.expandedHeight : Self.compactHeight
        let visible = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = CGPoint(x: point.x + 28, y: point.y - 16 - height)
        if origin.x + Self.width > visible.maxX { origin.x = point.x - 28 - Self.width }
        if origin.y < visible.minY { origin.y = point.y + 28 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        setFrame(CGRect(origin: origin, size: CGSize(width: Self.width, height: height)), display: true)
    }

    /// Grows or shrinks while keeping the top edge fixed.
    func setExpanded(_ expanded: Bool) {
        let height = expanded ? Self.expandedHeight : Self.compactHeight
        guard abs(frame.height - height) > 1 else { return }
        var next = frame
        next.origin.y += next.height - height
        next.size.height = height
        if let visible = screen?.visibleFrame, next.minY < visible.minY { next.origin.y = visible.minY + 8 }
        setFrame(next, display: true, animate: isVisible)
    }
}

// MARK: - Root view

struct PanelView: View {
    @ObservedObject var controller: CompanionController
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if controller.messages.isEmpty {
                hints.frame(maxHeight: .infinity)
            } else {
                transcript
            }
            if let action = controller.pendingAction {
                ConfirmCard(action: action, decide: controller.decide)
            }
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Colors.borderSubtle))
        .onExitCommand { controller.escape() }
        .onChange(of: controller.focusToken) { inputFocused = true }
        .onChange(of: controller.pendingAction) { if controller.pendingAction != nil { inputFocused = false } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isBusy ? DS.Colors.accent : DS.Colors.success)
                .frame(width: 7, height: 7)
            Text("ZOOBIE").font(.system(size: 12, weight: .semibold))
            Text(controller.activeModel ?? controller.config.chatModel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { controller.includeScreen.toggle() } label: {
                Label(controller.includeScreen ? (controller.screenSummary ?? "Screen") : "Screen off",
                      systemImage: controller.includeScreen ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(controller.includeScreen ? DS.Colors.surface3 : DS.Colors.surface2))
            }
            .help("Include what's on screen with your question")
            iconButton("arrow.clockwise", help: "Re-read the screen", action: controller.recapture)
            iconButton("trash", help: "Clear conversation", action: controller.clear)
            iconButton("xmark", help: "Close (Esc)", action: controller.hidePanel)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .help(help)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("⌃⌥", "hold to talk")
            hint("⌃⌥Space", "type")
            hint("agent:", "run tasks")
            hint("esc", "close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(DS.Colors.surface3))
            Text(label)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: controller.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: controller.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: controller.pendingAction) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var inputBar: some View {
        let isAgent = controller.input.lowercased().hasPrefix(Prompts.agentPrefix)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isAgent ? "terminal" : "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isAgent ? DS.Colors.accentBright : DS.Colors.accent)
            TextField(controller.pendingAction != nil ? "Waiting for your approval…" : "Ask about your screen — \"agent:\" runs tasks",
                      text: $controller.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { controller.submitInput() }
                .disabled(controller.pendingAction != nil)
            if controller.isBusy {
                Button(action: controller.cancelWork) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop (Esc)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.black.opacity(0.15))
    }
}

// MARK: - Messages

private struct MessageRow: View {
    let message: DisplayMessage

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.accent.opacity(0.28)))
            }
        case .assistant:
            if message.text.isEmpty {
                TypingIndicator()
            } else {
                MarkdownView(text: message.text)
            }
        case .step:
            if let action = message.action { StepCard(action: action, state: message.stepState ?? .awaiting) }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.danger)
                .textSelection(.enabled)
        case .note:
            Text(message.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

private struct StepCard: View {
    let action: AgentAction
    let state: DisplayMessage.StepState
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusIcon
                Text(action.title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(statusLabel).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(action.detail.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            if case .done(let output) = state {
                let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                Text(expanded ? output : lines.prefix(8).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.3)))
                if lines.count > 8 {
                    Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.accent)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2))
    }

    @ViewBuilder private var statusIcon: some View {
        switch state {
        case .awaiting: Image(systemName: "hand.raised.fill").foregroundStyle(DS.Colors.warning)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.success)
        case .skipped: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var statusLabel: String {
        switch state {
        case .awaiting: return "needs approval"
        case .running: return "running…"
        case .done: return "done"
        case .skipped: return "skipped"
        case .stopped: return "stopped"
        }
    }
}

private struct ConfirmCard: View {
    let action: AgentAction
    let decide: (AgentDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(DS.Colors.warning)
                Text("Approve step: \(action.title)").font(.system(size: 12, weight: .semibold))
                if action.isDestructive {
                    Text("CAUTION")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.danger))
                }
                Spacer()
            }
            ScrollView {
                Text(action.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            HStack(spacing: 8) {
                Text("↩ run · ⌘S skip · esc stop").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { decide(.stop) }
                Button("Skip") { decide(.skip) }.keyboardShortcut("s", modifiers: .command)
                Button("Run") { decide(.run) }
                    .keyboardShortcut(.defaultAction)
                    .tint(action.isDestructive ? .red : .accentColor)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(DS.Colors.accent.opacity(0.08))
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }
}

// MARK: - Markdown

/// Lightweight renderer: fenced code blocks become copyable monospaced blocks; the rest uses
/// SwiftUI's inline markdown with headings and bullets normalised.
struct MarkdownView: View {
    let text: String

    private enum Block {
        case prose(String)
        case code(language: String, code: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    CodeBlock(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer: [String] = []
        var inCode = false
        var language = ""
        func flushProse() {
            let prose = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty { blocks.append(.prose(prose)) }
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, code: buffer.joined(separator: "\n")))
                    buffer = []
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                inCode.toggle()
                continue
            }
            buffer.append(line)
        }
        if inCode {
            blocks.append(.code(language: language, code: buffer.joined(separator: "\n"))) // still streaming
        } else {
            flushProse()
        }
        return blocks
    }

    private static func attributed(_ prose: String) -> AttributedString {
        let normalised = prose.components(separatedBy: "\n").map { line -> String in
            var line = line
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line = "**" + line[range.upperBound...] + "**"
            }
            line = line.replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
            return line
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: normalised, options: options)) ?? AttributedString(prose)
    }
}

/// High-contrast monospaced code. Click anywhere on it to copy.
struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Colors.textTertiary)
                Spacer()
                Label(copied ? "Copied" : "Click to copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copied ? DS.Colors.success : (hovering ? DS.Colors.accent : DS.Colors.textTertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(DS.Colors.codeText)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hovering ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .dsPointerOnHover()
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
