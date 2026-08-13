import AppKit

/// The menubar glyph: a tap ripple. A dot where the knuckle lands, two arcs
/// spreading out of it.
///
/// Drawn rather than taken from SF Symbols so the optical nudge is under our
/// control. The visual mass sits low (the dot is heavier than the thin arcs), so
/// geometric centring reads as too high; `opticalBaseline` pushes it back down.
enum MenuBarGlyph {
    enum State: Equatable {
        case armed
        case idle
        /// Sensor gone, or never opened.
        case lost
        /// macOS has not granted what Tunk needs.
        case blocked
        case firing
    }

    static let size = NSSize(width: 18, height: 18)
    /// Nudge, in points. Positive moves the drawing up.
    private static let opticalBaseline: CGFloat = -0.5

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = describe(state)
        return image
    }

    private static func describe(_ state: State) -> String {
        switch state {
        case .armed: return "Tunk, listening for a double-tap"
        case .idle: return "Tunk, detection off"
        case .lost: return "Tunk, accelerometer unavailable"
        case .blocked: return "Tunk, blocked until permissions are granted"
        case .firing: return "Tunk, double-tap detected"
        }
    }

    private static func draw(_ state: State) {
        let cx: CGFloat = size.width / 2
        let cy: CGFloat = 6.4 + opticalBaseline
        let alpha: CGFloat = (state == .idle) ? 0.42 : 1.0

        NSColor.black.withAlphaComponent(alpha).setFill()
        NSColor.black.withAlphaComponent(alpha).setStroke()

        let dotRadius: CGFloat = state == .firing ? 3.3 : 2.5
        let dot = NSBezierPath(ovalIn: CGRect(x: cx - dotRadius, y: cy - dotRadius,
                                              width: dotRadius * 2, height: dotRadius * 2))
        if state == .idle {
            dot.lineWidth = 1.5
            NSBezierPath(ovalIn: CGRect(x: cx - dotRadius + 0.75, y: cy - dotRadius + 0.75,
                                        width: (dotRadius - 0.75) * 2,
                                        height: (dotRadius - 0.75) * 2)).stroke()
        } else {
            dot.fill()
        }

        arc(cx: cx, cy: cy, radius: 5.4, width: state == .firing ? 1.9 : 1.6, alpha: alpha)
        arc(cx: cx, cy: cy, radius: 8.2, width: state == .firing ? 1.7 : 1.35,
            alpha: alpha * (state == .firing ? 1.0 : 0.75))

        if state == .lost || state == .blocked { strikeThrough() }
    }

    private static func arc(cx: CGFloat, cy: CGFloat, radius: CGFloat,
                            width: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(withCenter: CGPoint(x: cx, y: cy), radius: radius,
                       startAngle: 38, endAngle: 142)
        path.lineWidth = width
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    /// Cut a clear gutter first so the slash reads against the arcs instead of
    /// merging with them.
    private static func strikeThrough() {
        guard let context = NSGraphicsContext.current else { return }
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 3.4, y: 3.0))
        line.line(to: CGPoint(x: 14.6, y: 14.2))
        line.lineCapStyle = .round

        context.saveGraphicsState()
        context.compositingOperation = .clear
        line.lineWidth = 3.6
        NSColor.black.setStroke()
        line.stroke()
        context.restoreGraphicsState()

        line.lineWidth = 1.7
        NSColor.black.setStroke()
        line.stroke()
    }
}
