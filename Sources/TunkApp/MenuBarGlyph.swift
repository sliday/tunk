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
        /// Detection works, but a bound action cannot run as configured — a
        /// Shortcut that has been renamed or deleted. Passive on purpose: this
        /// glyph is how the user finds out, because the alternative is a modal
        /// dialog on every stray knock.
        case actionBroken
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
        case .actionBroken: return "Tunk, listening, but a bound Shortcut is missing"
        case .firing: return "Tunk, tap detected"
        }
    }

    /// Two beats over a surface, with the shock spreading out of the second one.
    ///
    /// The baseline matters: a dot under bare arcs is Wi-Fi, and a dot inside
    /// arcs is AirDrop. Grounding the marks on a line says "something struck a
    /// surface", and two of them say the gesture is a double.
    /// A knock, with the shock spreading downward into the machine.
    ///
    /// Arcs above a dot are Wi-Fi. Arcs around a dot are AirDrop. Arcs below a
    /// dot are neither, and they say the right thing: something hit the top of
    /// the case and the energy went into it.
    private static func draw(_ state: State) {
        let cx: CGFloat = size.width / 2
        let cy: CGFloat = 12.6 + opticalBaseline
        let alpha: CGFloat = (state == .idle) ? 0.45 : 1.0

        let grow: CGFloat = state == .firing ? 1.14 : 1.0
        dot(x: cx, y: cy, radius: 2.2 * grow, filled: state != .idle, alpha: alpha)
        arc(cx: cx, cy: cy, radius: 5.0 * grow,
            width: state == .firing ? 1.75 : 1.55, alpha: alpha)
        arc(cx: cx, cy: cy, radius: 8.0 * grow,
            width: state == .firing ? 1.5 : 1.3,
            alpha: alpha * (state == .firing ? 1.0 : 0.7))

        if state == .lost || state == .blocked { strikeThrough() }
        // Not a strike: detection is working, so the glyph must not read as
        // "off". A mark beside it says "attention", which is the truth.
        if state == .actionBroken { attentionMark() }
    }

    /// A small filled square at the lower right. Deliberately not a strike and
    /// not a second ripple: it has to be legible at 18 pt as a template image,
    /// in a menu bar the user is not looking at.
    private static func attentionMark() {
        guard let context = NSGraphicsContext.current else { return }
        let mark = CGRect(x: 12.4, y: 1.6, width: 3.8, height: 3.8)
        // Clear a gutter first so the mark reads against the outer arc rather
        // than merging with it, same trick as the strike.
        context.saveGraphicsState()
        context.compositingOperation = .clear
        NSColor.black.set()
        NSBezierPath(ovalIn: mark.insetBy(dx: -1.4, dy: -1.4)).fill()
        context.restoreGraphicsState()

        NSColor.black.set()
        NSBezierPath(ovalIn: mark).fill()
    }

    private static func dot(x: CGFloat, y: CGFloat, radius: CGFloat,
                            filled: Bool, alpha: CGFloat) {
        let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        NSColor.black.withAlphaComponent(alpha).set()
        if filled {
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    private static func arc(cx: CGFloat, cy: CGFloat, radius: CGFloat,
                            width: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        // The lower half: the shock going down into the case, not a signal
        // going up into the air.
        path.appendArc(withCenter: CGPoint(x: cx, y: cy), radius: radius,
                       startAngle: 218, endAngle: 322)
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
