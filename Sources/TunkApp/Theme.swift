import SwiftUI

/// Layout constants. The radii are concentric by construction: a card's corner
/// is its inner control's corner plus its own padding, so nothing nests wrong.
enum Metrics {
    static let controlRadius: CGFloat = 8
    static let cardPadding: CGFloat = 14
    static var cardRadius: CGFloat { controlRadius + cardPadding }      // 22
    static let panelPadding: CGFloat = 16
    static var panelRadius: CGFloat { cardRadius + panelPadding }       // 38
    /// The standard's floor for anything clickable.
    static let hitTarget: CGFloat = 40
    static let stagger: Double = 0.1
}

extension Animation {
    /// `.snappy` where the OS has it, its spring equivalent below that. Always
    /// interruptible — no keyframes anywhere in this panel.
    static var tunkSnappy: Animation {
        if #available(macOS 14.0, *) { return .snappy(duration: 0.28, extraBounce: 0.02) }
        return .spring(response: 0.28, dampingFraction: 0.86)
    }

    static var tunkQuick: Animation {
        if #available(macOS 14.0, *) { return .snappy(duration: 0.16) }
        return .spring(response: 0.16, dampingFraction: 0.9)
    }
}

extension View {
    /// Cross-fade instead of movement when the user asked for less motion.
    func tunkAnimation<V: Equatable>(_ animation: Animation, value: V,
                                     reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? .easeInOut(duration: 0.18) : animation, value: value)
    }
}

/// A section. Depth comes from three stacked low-alpha shadows; there is not a
/// single hairline divider in this panel.
struct Card<Content: View>: View {
    var title: String
    var caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(0.07), radius: 6, y: 3)
        .shadow(color: .black.opacity(0.05), radius: 18, y: 10)
    }
}

/// Press scale is 0.96, never lower. The visible control stays small; the hit
/// region is padded out to 40 pt so it clears the standard without the button
/// looking like a touch target.
struct TunkButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, prominent: prominent)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .fill(prominent
                              ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(Color.primary.opacity(0.07)))
                )
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .tunkAnimation(.tunkQuick, value: configuration.isPressed,
                               reduceMotion: reduceMotion)
                .frame(minWidth: Metrics.hitTarget, minHeight: Metrics.hitTarget)
                .contentShape(Rectangle())
        }
    }
}

/// A number that changes while you watch it. Always tabular.
struct Readout: View {
    var label: String
    var value: String
    var accent: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accent)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
