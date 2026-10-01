import AppKit
import SwiftUI

/// ZOOBIE's design tokens: a blue accent on dark surfaces, shared by the buddy, cards, panel and onboarding.
enum DS {
    enum Colors {
        static let background = Color(hex: 0x0E1011)
        static let surface1 = Color(hex: 0x15181A)
        static let surface2 = Color(hex: 0x1D2023)
        static let surface3 = Color(hex: 0x262A2E)
        static let borderSubtle = Color.white.opacity(0.08)
        static let borderStrong = Color.white.opacity(0.16)

        static let textPrimary = Color(hex: 0xECEEF0)
        static let textSecondary = Color(hex: 0xA9B0B6)
        static let textTertiary = Color(hex: 0x6B737A)

        static let accent = Color(hex: 0x3B82F6)
        static let accentBright = Color(hex: 0x60A5FA)
        static let accentDeep = Color(hex: 0x2563EB)
        static let success = Color(hex: 0x22C55E)
        static let warning = Color(hex: 0xF59E0B)
        static let danger = Color(hex: 0xEF4444)
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    static let accentGradient = LinearGradient(colors: [Colors.accentBright, Colors.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
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

// MARK: - Surfaces

/// The standard ZOOBIE surface: near-black, hairline border, soft shadow.
struct DSSurface: ViewModifier {
    var radius: CGFloat = DS.Radius.large

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.Colors.surface1.opacity(0.97)))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.Colors.borderSubtle))
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
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(background(pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).strokeBorder(kind == .secondary ? DS.Colors.borderStrong : .clear))
            .contentShape(Rectangle())
            .dsPointerOnHover()
    }

    private var foreground: Color {
        switch kind {
        case .primary, .destructive: return .white
        case .secondary: return DS.Colors.textPrimary
        case .ghost: return DS.Colors.textSecondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? DS.Colors.accentDeep : DS.Colors.accent
        case .destructive: return DS.Colors.danger.opacity(pressed ? 0.75 : 0.9)
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
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == value ? Color.white : DS.Colors.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selection == value ? DS.Colors.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dsPointerOnHover()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.surface2))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// A small uppercase section label.
struct DSSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(DS.Colors.textTertiary)
    }
}

// MARK: - Brand

/// The ZOOBIE pointer: a rounded cursor-like triangle whose tip is the rect's top-left corner.
struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.74))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.7))
        path.closeSubpath()
        return path
    }
}

/// The glowing pointer as a standalone mark (onboarding, panel header).
struct ZoobieMark: View {
    var size: CGFloat = 22
    var body: some View {
        PointerShape()
            .fill(DS.accentGradient)
            .frame(width: size * 0.8, height: size)
            .shadow(color: DS.glow.opacity(0.8), radius: size * 0.35)
    }
}

enum MenuBarIcon {
    /// The pointer glyph as a template image, so macOS tints it for light and dark menu bars.
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let glyph = CGRect(x: 4, y: 2, width: 11, height: 14)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: glyph.minX, y: glyph.minY))
            path.line(to: CGPoint(x: glyph.minX, y: glyph.maxY))
            path.line(to: CGPoint(x: glyph.minX + glyph.width * 0.34, y: glyph.minY + glyph.height * 0.74))
            path.line(to: CGPoint(x: glyph.maxX, y: glyph.minY + glyph.height * 0.7))
            path.close()
            path.lineJoinStyle = .round
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ZOOBIE"
        return image
    }
}
