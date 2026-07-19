import SwiftUI

// MARK: - Liquid Glass helpers (macOS 26+) with material fallbacks

enum BrainstormChrome {
    static let nodeCorner: CGFloat = 12
    static let rootCorner: CGFloat = 16
    static let inspectorWidth: CGFloat = 280
    static let statusBarHeight: CGFloat = 36
}

struct GlassCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var cornerRadius: CGFloat = 12
    var interactive: Bool = false
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.16))
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                )
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    glassStyle,
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.12))
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }

    @available(macOS 26.0, *)
    private var glassStyle: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

struct GlassCapsuleModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var interactive: Bool = true
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                        if let tint {
                            Capsule(style: .continuous)
                                .fill(tint.opacity(0.24))
                        }
                    }
                }
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            tint?.opacity(0.55) ?? Color.primary.opacity(0.18),
                            lineWidth: 1
                        )
                )
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glassStyle, in: .capsule)
        } else if let tint {
            content
                .background(tint.opacity(0.18), in: Capsule(style: .continuous))
                .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    @available(macOS 26.0, *)
    private var glassStyle: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.45)) }
        if interactive { g = g.interactive() }
        return g
    }
}

struct GlassButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var prominent = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        } else if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func brainstormGlassCard(
        cornerRadius: CGFloat = BrainstormChrome.nodeCorner,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, interactive: interactive, tint: tint))
    }

    func brainstormGlassCapsule(interactive: Bool = true, tint: Color? = nil) -> some View {
        modifier(GlassCapsuleModifier(interactive: interactive, tint: tint))
    }

    func brainstormGlassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonModifier(prominent: prominent))
    }

}

// MARK: - Shared chrome bits

/// Deliberately scoped grouping for a small family of related glass controls.
///
/// This is a container rather than a `View` extension so it cannot silently
/// discard a receiver. Reduce Transparency bypasses the glass compositor and
/// lets each child use its opaque fallback.
struct BrainstormGlassGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let spacing: CGFloat
    private let content: Content

    init(
        spacing: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if !reduceTransparency, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .brainstormGlassCapsule(interactive: false)
    }
}

struct StatusHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            KeyCap(text: key)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct ColorSwatchButton: View {
    let hex: String
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if hex.isEmpty {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: 28, height: 28)
                    Image(systemName: "circle.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}
