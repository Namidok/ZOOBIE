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
        PixelRect(step: DS.Radius.medium)
            .fill(BuddyStyle.glow.opacity(0.08))
            .overlay(PixelRect(step: DS.Radius.medium).strokeBorder(BuddyStyle.gradient, lineWidth: 2.5))
            .shadow(color: BuddyStyle.glow.opacity(glow ? 0.9 : 0.45), radius: glow ? 12 : 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { glow = true }
            }
    }
}
