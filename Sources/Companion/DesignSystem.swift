import AppKit
import CoreText
import SwiftUI

/// ZOOBIE's design tokens — "pixel": the specialists' pixel-art avatars as a UI. Deep navy and slate
/// surfaces, hologram-cyan glow, LED green, dithered checker textures, notched pixel frames and a pixel
/// font (Jersey 10) for titles. Colours are sampled from img/*.png; the values mirror replica/design/tokens.json
/// (check changes with the contrast script there: 0 AA failures).
enum DS {
    enum Colors {
        static let background = Color(hex: 0x060D24)
        static let surface1 = Color(hex: 0x0C1733)
        static let surface2 = Color(hex: 0x13234A)
        static let surface3 = Color(hex: 0x1B2F5C)
        static let borderSubtle = Color(hex: 0x24375C)
        static let borderStrong = Color(hex: 0x5E7E96)
        /// The avatars' frame and backdrop blue, for textures.
        static let slate = Color(hex: 0x7595AA)

        static let textPrimary = Color(hex: 0xE6F4F8)
        static let textSecondary = Color(hex: 0xA7C0CF)
        static let textTertiary = Color(hex: 0x86A3B8)

        /// Hologram cyan: the glowing data text in the avatars.
        static let accent = Color(hex: 0x8FE6F2)
        static let accentBright = Color(hex: 0xC9F6FB)
        static let accentDeep = Color(hex: 0x3E8FA6)
        /// Text and icons on an accent fill.
        static let onAccent = Color(hex: 0x04122A)
        /// LED green, like Scrapeman's headset light.
        static let success = Color(hex: 0xA4F9BB)
        static let warning = Color(hex: 0xF2C66D)
        static let danger = Color(hex: 0xFF7A7A)
        /// Code blocks: the deepest navy with crisp off-white text.
        static let codeBackground = Color(hex: 0x030817)
        static let codeText = Color(hex: 0xE6F4F8)
    }

    /// Pixel frames have notched corners instead of round ones; these are the step sizes.
    enum Radius {
        static let small: CGFloat = 2
        static let medium: CGFloat = 3
        static let large: CGFloat = 4
    }

    enum Fonts {
        /// Jersey 10 (SIL OFL, bundled in Resources/fonts) for titles, names and labels: chunky 16-bit
        /// letters with a clear Z for ZOOBIE. It's condensed, so it's drawn a fifth larger than `size`.
        /// One weight only — `weight` is ignored rather than faked. Body text stays in the system font.
        static func pixel(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom("Jersey 10", size: size * 1.2)
        }

        /// Registers the bundled pixel font for this process. Call once at launch.
        static func register() {
            var url = Bundle.main.url(forResource: "Jersey10-Regular", withExtension: "ttf", subdirectory: "fonts")
            #if DEBUG
            if url == nil { url = URL(fileURLWithPath: "Resources/fonts/Jersey10-Regular.ttf") } // `swift run` has no bundle
            #endif
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }

    static let accentGradient = LinearGradient(colors: [Colors.accentBright, Colors.accent], startPoint: .top, endPoint: .bottom)
    static let glow = Colors.accent
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Pixel shapes and textures

/// A rectangle whose corners are cut in a two-step staircase, like a sprite frame. `step` is the size of
/// one stair (DS.Radius values); insettable, so `strokeBorder` draws crisp pixel borders.
struct PixelRect: InsettableShape {
    var step: CGFloat = DS.Radius.medium
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let s = min(step, r.width / 4, r.height / 4)
        guard s > 0 else { return Path(r) }
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 2 * s, y: r.minY))
        p.addLines([
            CGPoint(x: r.maxX - 2 * s, y: r.minY), CGPoint(x: r.maxX - 2 * s, y: r.minY + s), CGPoint(x: r.maxX - s, y: r.minY + s),
            CGPoint(x: r.maxX - s, y: r.minY + 2 * s), CGPoint(x: r.maxX, y: r.minY + 2 * s),
            CGPoint(x: r.maxX, y: r.maxY - 2 * s), CGPoint(x: r.maxX - s, y: r.maxY - 2 * s), CGPoint(x: r.maxX - s, y: r.maxY - s),
            CGPoint(x: r.maxX - 2 * s, y: r.maxY - s), CGPoint(x: r.maxX - 2 * s, y: r.maxY),
            CGPoint(x: r.minX + 2 * s, y: r.maxY), CGPoint(x: r.minX + 2 * s, y: r.maxY - s), CGPoint(x: r.minX + s, y: r.maxY - s),
            CGPoint(x: r.minX + s, y: r.maxY - 2 * s), CGPoint(x: r.minX, y: r.maxY - 2 * s),
            CGPoint(x: r.minX, y: r.minY + 2 * s), CGPoint(x: r.minX + s, y: r.minY + 2 * s), CGPoint(x: r.minX + s, y: r.minY + s),
            CGPoint(x: r.minX + 2 * s, y: r.minY + s),
        ])
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> PixelRect {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// The avatars' dithered checkerboard: alternating cells of two colours, as a background texture.
struct DitherPattern: View {
    var cell: CGFloat = 2
    var color: Color = DS.Colors.slate
    var opacity: Double = 0.07

    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
            var path = Path()
            for row in 0..<rows {
                for column in stride(from: row % 2, to: columns, by: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(color.opacity(opacity)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Surfaces

/// The standard ZOOBIE surface: navy panel with a notched slate pixel frame.
struct DSSurface: ViewModifier {
    var radius: CGFloat = DS.Radius.large

    func body(content: Content) -> some View {
        content
            .background(PixelRect(step: radius).fill(DS.Colors.surface1.opacity(0.97)))
            .clipShape(PixelRect(step: radius))
            .overlay(PixelRect(step: radius).strokeBorder(DS.Colors.borderSubtle, lineWidth: 2))
    }
}

extension View {
    func dsSurface(radius: CGFloat = DS.Radius.large) -> some View { modifier(DSSurface(radius: radius)) }

    /// Pointing-hand cursor on hover, for anything clickable.
    func dsPointerOnHover() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Buttons

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.pixel(compact ? 12 : 13))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(PixelRect(step: DS.Radius.small).fill(background(pressed: configuration.isPressed)))
            .overlay(PixelRect(step: DS.Radius.small).strokeBorder(border, lineWidth: 2))
            .offset(y: configuration.isPressed ? 1 : 0) // pressed buttons sink a pixel
            .contentShape(Rectangle())
            .dsPointerOnHover()
    }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.Colors.onAccent
        case .destructive: return DS.Colors.danger
        case .secondary: return DS.Colors.textPrimary
        case .ghost: return DS.Colors.textSecondary
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return DS.Colors.accentBright
        case .secondary: return DS.Colors.borderStrong
        case .destructive: return DS.Colors.danger.opacity(0.75)
        case .ghost: return .clear
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? DS.Colors.accentDeep : DS.Colors.accent
        case .destructive: return DS.Colors.danger.opacity(pressed ? 0.22 : 0.1)
        case .secondary: return pressed ? DS.Colors.surface3 : DS.Colors.surface2
        case .ghost: return pressed ? DS.Colors.surface2 : .clear
        }
    }
}

/// A compact segmented control in the ZOOBIE style.
struct DSSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(DS.Fonts.pixel(12))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == value ? DS.Colors.onAccent : DS.Colors.textSecondary)
                        .background(PixelRect(step: DS.Radius.small).fill(selection == value ? DS.Colors.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dsPointerOnHover()
            }
        }
        .padding(2)
        .background(PixelRect(step: DS.Radius.small).fill(DS.Colors.surface2))
        .overlay(PixelRect(step: DS.Radius.small).strokeBorder(DS.Colors.borderSubtle, lineWidth: 2))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

/// A small uppercase section label in the pixel font.
struct DSSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DS.Fonts.pixel(11))
            .tracking(1)
            .foregroundStyle(DS.Colors.textTertiary)
    }
}

// MARK: - Brand

/// The ZOOBIE pointer: an 8-bit arrow cursor drawn from a pixel mask. Its tip is the rect's top-left
/// corner, so the tip lands exactly where it points.
struct PointerShape: Shape {
    /// One string per row; "#" is a filled pixel.
    static let mask = [
        "#.........",
        "##........",
        "###.......",
        "####......",
        "#####.....",
        "######....",
        "#######...",
        "########..",
        "#########.",
        "##########",
        "######....",
        "###.###...",
        "##..###...",
        "#....###..",
        ".....###..",
        "......##..",
    ]

    func path(in rect: CGRect) -> Path {
        let rows = Self.mask.count, columns = Self.mask[0].count
        let pixel = min(rect.width / CGFloat(columns), rect.height / CGFloat(rows))
        var path = Path()
        for (row, line) in Self.mask.enumerated() {
            // One rect per run of filled pixels, so each row is a single solid bar.
            var start: Int?
            for (column, character) in (line + ".").enumerated() {
                if character == "#" { if start == nil { start = column } } else if let begin = start {
                    path.addRect(CGRect(x: rect.minX + CGFloat(begin) * pixel, y: rect.minY + CGFloat(row) * pixel,
                                        width: CGFloat(column - begin) * pixel, height: pixel))
                    start = nil
                }
            }
        }
        return path
    }
}

/// The glowing pointer as a standalone mark (sidebar, onboarding).
struct ZoobieMark: View {
    var size: CGFloat = 22
    var body: some View {
        PointerShape()
            .fill(DS.accentGradient)
            .frame(width: size * 0.63, height: size)
            .shadow(color: DS.Colors.onAccent, radius: 0, x: 1, y: 1) // a dark pixel edge, like a sprite outline
            .shadow(color: DS.glow.opacity(0.75), radius: size * 0.3)
    }
}

enum MenuBarIcon {
    /// The pixel pointer as a template image, so macOS tints it for light and dark menu bars.
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let pixel: CGFloat = 1
            let origin = CGPoint(x: 4, y: 1)
            NSColor.black.setFill()
            for (row, line) in PointerShape.mask.enumerated() {
                for (column, character) in line.enumerated() where character == "#" {
                    NSRect(x: origin.x + CGFloat(column) * pixel, y: origin.y + CGFloat(row) * pixel, width: pixel, height: pixel).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ZOOBIE"
        return image
    }
}
