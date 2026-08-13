import AppKit

/// `tunk --dump-glyphs <dir>` writes every menubar state to a PNG at 3× on both
/// a light and a dark plate. The glyph is a template image, so this is the only
/// way to see what it looks like tinted, without a menu bar screenshot.
enum GlyphDump {
    static func run(into directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let states: [(String, MenuBarGlyph.State)] = [
            ("armed", .armed), ("idle", .idle), ("lost", .lost),
            ("blocked", .blocked), ("firing", .firing),
        ]
        for (name, state) in states {
            for dark in [false, true] {
                let file = url.appendingPathComponent("glyph-\(name)-\(dark ? "dark" : "light").png")
                guard let data = plate(state: state, dark: dark) else { continue }
                try? data.write(to: file)
                FileHandle.standardOutput.write(Data("wrote \(file.path)\n".utf8))
            }
        }
    }

    /// One glyph, 3×, on the menu bar's own background so the contrast is real.
    private static func plate(state: MenuBarGlyph.State, dark: Bool) -> Data? {
        let scale: CGFloat = 3
        let size = MenuBarGlyph.size
        let pixels = NSSize(width: size.width * scale, height: size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor.black : NSColor.white).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

        let glyph = MenuBarGlyph.image(for: state)
        let tinted = NSImage(size: size, flipped: false) { rect in
            (dark ? NSColor.white : NSColor.black).set()
            glyph.draw(in: rect)
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
