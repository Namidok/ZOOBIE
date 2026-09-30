import AppKit
import SwiftUI

@MainActor
final class BuddyModel: ObservableObject {
    enum Mode: Equatable { case idle, listening, thinking, speaking }
    enum CaptionStyle { case spoken, user, status }

    @Published var mode: Mode = .idle
    @Published var caption: String?
    @Published var captionStyle: CaptionStyle = .spoken
    @Published var isPointing = false
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 7)
    /// Captions flip left/up near the right/bottom screen edges so they stay visible.
    @Published var flipX = false
    @Published var flipY = false

    func push(level: CGFloat) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// The companion itself: a glowing pointer that trails the cursor, shows a waveform while listening,
/// captions what it says, and flies to on-screen elements. It lives in a click-through window that is
/// excluded from screen captures (it belongs to this app).
@MainActor
final class BuddyOverlay {
    let model = BuddyModel()
    var showWhenIdle = true { didSet { updateVisibility() } }

    /// The window is centred on the glyph's tip so captions have room on every side.
    static let size = CGSize(width: 760, height: 360)
    static let anchor = CGPoint(x: 380, y: 180)
    private static let cursorOffset = CGPoint(x: 14, y: -20)

    private let window: NSPanel
    private var timer: Timer?
    private var position = NSEvent.mouseLocation
    private var flight: Flight?

    private struct Flight {
        var from: CGPoint
        var to: CGPoint
        var start = Date()
        var duration: TimeInterval = 0.6
    }

    init() {
        window = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: BuddyView(model: model))
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateVisibility()
    }

    func setMode(_ mode: BuddyModel.Mode) {
        model.mode = mode
        if mode != .listening { model.levels = Array(repeating: 0, count: model.levels.count) }
        updateVisibility()
    }

    func setCaption(_ text: String?, style: BuddyModel.CaptionStyle = .spoken) {
        model.caption = text
        model.captionStyle = style
        updateVisibility()
    }

    /// Flies to `rect` (AppKit global coordinates) and stays there until `release()`.
    func point(at rect: CGRect) {
        point(to: CGPoint(x: rect.minX + min(18, rect.width / 3), y: rect.midY))
    }

    /// Flies so the pointer's tip lands on `target` (AppKit global coordinates).
    func point(to target: CGPoint) {
        if let flight, hypot(flight.to.x - target.x, flight.to.y - target.y) < 1 { return }
        flight = Flight(from: position, to: target)
        model.isPointing = true
        updateVisibility()
    }

    /// Goes back to following the cursor (with the usual easing, so it glides home).
    func release() {
        flight = nil
        model.isPointing = false
        updateVisibility()
    }

    private func tick() {
        if let flight {
            let t = Date().timeIntervalSince(flight.start) / flight.duration
            position = t < 1 ? Self.arc(from: flight.from, to: flight.to, progress: Self.easeInOut(t)) : flight.to
        } else {
            let mouse = NSEvent.mouseLocation
            let follow = CGPoint(x: mouse.x + Self.cursorOffset.x, y: mouse.y + Self.cursorOffset.y)
            let dx = follow.x - position.x
            let dy = follow.y - position.y
            if abs(dx) < 0.2 && abs(dy) < 0.2 { return }
            position.x += dx * 0.28
            position.y += dy * 0.28
        }
        updateFlips()
        window.setFrameOrigin(CGPoint(x: position.x - Self.anchor.x, y: position.y - Self.anchor.y))
    }

    private func updateFlips() {
        guard let visible = (NSScreen.screens.first { NSMouseInRect(position, $0.frame, false) } ?? NSScreen.main)?.visibleFrame else { return }
        let flipX = position.x + 360 > visible.maxX
        let flipY = position.y - 190 < visible.minY
        if flipX != model.flipX { model.flipX = flipX }
        if flipY != model.flipY { model.flipY = flipY }
    }

    private func updateVisibility() {
        let active = model.mode != .idle || model.caption != nil || model.isPointing
        if showWhenIdle || active {
            if !window.isVisible { window.orderFrontRegardless() }
        } else if window.isVisible {
            window.orderOut(nil)
        }
    }

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// Quadratic Bézier with the control point lifted above the midpoint, for a natural swoop.
    private static func arc(from a: CGPoint, to b: CGPoint, progress t: Double) -> CGPoint {
        let lift = min(160, hypot(b.x - a.x, b.y - a.y) * 0.3)
        let c = CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + lift)
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

// MARK: - Views

enum BuddyStyle {
    static let gradient = LinearGradient(
        colors: [Color(red: 0.38, green: 0.62, blue: 1.0), Color(red: 0.55, green: 0.36, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let glow = Color(red: 0.45, green: 0.5, blue: 1)
}

private struct BuddyView: View {
    @ObservedObject var model: BuddyModel

    private let captionWidth: CGFloat = 330
    private let captionHeight: CGFloat = 150

    var body: some View {
        let anchor = BuddyOverlay.anchor
        ZStack(alignment: .topLeading) {
            Color.clear
            BuddyGlyph(mode: model.mode, pointing: model.isPointing)
                .frame(width: 22, height: 24, alignment: .topLeading)
                .offset(x: anchor.x, y: anchor.y)
            if model.mode == .listening {
                Waveform(levels: model.levels)
                    .offset(x: model.flipX ? anchor.x - 62 : anchor.x + 22, y: anchor.y + 2)
                    .transition(.opacity)
            }
            if let caption = model.caption, !caption.isEmpty {
                CaptionBubble(text: caption, style: model.captionStyle)
                    .frame(width: captionWidth, height: captionHeight,
                           alignment: Alignment(horizontal: model.flipX ? .trailing : .leading, vertical: model.flipY ? .bottom : .top))
                    .offset(x: model.flipX ? anchor.x - captionWidth + 8 : anchor.x + 14,
                            y: model.flipY ? anchor.y - captionHeight - 6 : anchor.y + 28)
                    .transition(.opacity)
                    .id(caption) // cross-fade between sentences
            }
        }
        .frame(width: BuddyOverlay.size.width, height: BuddyOverlay.size.height)
        .animation(.easeOut(duration: 0.18), value: model.caption)
        .animation(.easeOut(duration: 0.18), value: model.mode)
    }
}

private struct CaptionBubble: View {
    let text: String
    let style: BuddyModel.CaptionStyle

    var body: some View {
        Text(style == .user ? "“\(text)”" : text)
            .font(.system(size: style == .status ? 12 : 13, weight: style == .spoken ? .medium : .regular))
            .italic(style == .user)
            .foregroundStyle(Color.white.opacity(style == .spoken ? 0.95 : 0.7))
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(white: 0.08).opacity(0.86))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            )
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}

private struct Waveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(BuddyStyle.gradient)
                    .frame(width: 3, height: 4 + levels[i] * 16)
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(white: 0.08).opacity(0.8)))
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

private struct BuddyGlyph: View {
    var mode: BuddyModel.Mode
    var pointing: Bool
    @State private var spin = false
    @State private var breathe = false

    var body: some View {
        let active = mode != .idle || pointing
        ZStack(alignment: .topLeading) {
            if mode == .thinking {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(BuddyStyle.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .offset(x: -6, y: -4)
                    .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spin = true } }
                    .onDisappear { spin = false }
            }
            PointerShape()
                .fill(BuddyStyle.gradient)
                .frame(width: 15, height: 19)
                .shadow(color: BuddyStyle.glow.opacity(active ? 0.95 : 0.4), radius: active ? 8 : 3)
                .scaleEffect(breathe ? 1.14 : 1, anchor: .topLeading)
                .opacity(active ? 1 : 0.65)
        }
        .onChange(of: mode, initial: true) { _, newMode in
            if newMode == .speaking {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { breathe = true }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { breathe = false }
            }
        }
    }
}

/// A rounded cursor-like triangle whose tip is the view's top-left corner.
private struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY * 0.74))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.7))
        path.closeSubpath()
        return path
    }
}
