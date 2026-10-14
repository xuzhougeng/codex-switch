import SwiftUI
import AppKit

// Shared colors adapt to the window appearance without changing layout or adding effects.
enum SwitchPalette {
    static let accent = adaptive(0x2E6B56, 0xA7D6BB)
    static let canvas = adaptive(0xF5F6F3, 0x151B18)
    static let surface = adaptive(0xFFFFFF, 0x202823)
    static let inset = adaptive(0xF3F5F1, 0x19201C)
    static let border = adaptive(0xE2E7DF, 0x344139)
    static let muted = adaptive(0x728075, 0xA2B0A7)
    static let selected = adaptive(0xEDF5EE, 0x2A3D31)
    static let forest = Color(red: 0.075, green: 0.19, blue: 0.15)
    static let mint = Color(red: 0.76, green: 0.91, blue: 0.80)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

struct SwitchButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, hero, onDark }
    var kind: Kind = .secondary
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        ButtonSurface(configuration: configuration, kind: kind, compact: compact)
    }
    private struct ButtonSurface: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        private var foreground: Color {
            switch kind {
            case .primary: return SwitchPalette.surface
            case .hero: return SwitchPalette.forest
            case .onDark: return .white
            default: return SwitchPalette.accent
            }
        }
        private var background: Color {
            switch kind {
            case .primary: return SwitchPalette.accent
            case .hero: return SwitchPalette.mint
            case .onDark: return .white.opacity(hovered ? 0.16 : 0.09)
            case .quiet: return hovered ? SwitchPalette.selected : .clear
            case .secondary: return hovered ? SwitchPalette.selected : SwitchPalette.surface
            }
        }
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .padding(.horizontal, compact ? 9 : 13).padding(.vertical, compact ? 6 : 9)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(kind == .secondary ? SwitchPalette.border : .clear) }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
                .onHover { hovered = $0 }
        }
    }
}

struct SwitchFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SwitchPalette.border.opacity(0.7)) }
    }
}

struct SwitchEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var compact = false
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 24, weight: .light))
                .foregroundStyle(SwitchPalette.accent)
                .frame(width: compact ? 48 : 60, height: compact ? 48 : 60)
                .background(SwitchPalette.selected, in: RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(SwitchPalette.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, compact ? 24 : 34).padding(.horizontal, 24)
    }
}
