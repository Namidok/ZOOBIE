import AppKit
import CompanionCore
import SwiftUI

// Message building blocks shared by the chat window: typing dots, step cards, Markdown and code.

struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Rectangle() // square pixel dots
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

struct StepCard: View {
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
                    .background(PixelRect(step: DS.Radius.small).fill(Color.black.opacity(0.3)))
                if lines.count > 8 {
                    Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.accent)
                }
            }
        }
        .padding(8)
        .background(PixelRect(step: DS.Radius.medium).fill(DS.Colors.surface2))
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
        .background(PixelRect(step: DS.Radius.medium).fill(DS.Colors.codeBackground))
        .overlay(PixelRect(step: DS.Radius.medium).strokeBorder(hovering ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle))
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
