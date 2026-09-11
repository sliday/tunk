// Draw the DMG window background: a left-to-right arrow between the two icon
// slots and one line that says what to do. Run by build-dmg.sh as
//
//   swift dist/dmg-background.swift <out.tiff> <width> <height> <iconY> <leftX> <rightX>
//
// AppKit only, so it needs no dependency beyond the toolchain. The output is a
// TIFF with a 1x and a 2x representation, which is how Finder gets a sharp
// background on Retina displays without a separate file.
//
// Window points, origin top-left, matching the Finder positions build-dmg.sh
// sets: the arrow is centred vertically on iconY and runs from the right edge
// of the Tunk.app icon to the left edge of the Applications icon.

import AppKit

let args = CommandLine.arguments
guard args.count == 7,
      let width = Double(args[2]), let height = Double(args[3]),
      let iconY = Double(args[4]), let leftX = Double(args[5]), let rightX = Double(args[6])
else {
    FileHandle.standardError.write("usage: dmg-background.swift <out.tiff> <w> <h> <iconY> <leftX> <rightX>\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let iconSize = 128.0

// Palette matches design/IDENTITY.md: aluminium neutrals, one amber accent.
let paper   = NSColor(calibratedRed: 0.945, green: 0.945, blue: 0.953, alpha: 1)
let paperLo = NSColor(calibratedRed: 0.905, green: 0.905, blue: 0.915, alpha: 1)
let ink     = NSColor(calibratedRed: 0.227, green: 0.227, blue: 0.235, alpha: 1)
let inkSoft = NSColor(calibratedRed: 0.42,  green: 0.42,  blue: 0.44,  alpha: 1)
let amber   = NSColor(calibratedRed: 0.961, green: 0.651, blue: 0.137, alpha: 1)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let pw = Int(width * scale), ph = Int(height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)   // points; pixels/points = scale

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)
    // Flip so y grows downward, like the Finder window coordinates we were given.
    ctx.cgContext.translateBy(x: 0, y: height)
    ctx.cgContext.scaleBy(x: 1, y: -1)

    let full = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(starting: paper, ending: paperLo)!.draw(in: full, angle: -90)

    // The arrow. Shaft from the right edge of the app icon to the left edge of
    // the Applications icon, with breathing room, head pointing right.
    let gap = 28.0
    let x0 = leftX + iconSize / 2 + gap
    let x1 = rightX - iconSize / 2 - gap
    let y = iconY
    let shaft = NSBezierPath()
    shaft.lineWidth = 6
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: x0, y: y))
    shaft.line(to: NSPoint(x: x1 - 18, y: y))
    amber.setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: x1 - 30, y: y - 20))
    head.line(to: NSPoint(x: x1, y: y))
    head.line(to: NSPoint(x: x1 - 30, y: y + 20))
    head.close()
    amber.setFill()
    head.fill()

    // Text is drawn unflipped, so flip back for the string calls.
    ctx.cgContext.saveGState()
    ctx.cgContext.translateBy(x: 0, y: height)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    let para = NSMutableParagraphStyle()
    para.alignment = .center

    func centred(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, topY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let h = s.size().height
        s.draw(in: NSRect(x: 0, y: height - topY - h, width: width, height: h))
    }

    centred("Drag Tunk into Applications", size: 22, weight: .semibold, color: ink, topY: 44)
    centred("Then open it from Applications. It will ask for two permissions and walk you through them.",
            size: 13, weight: .regular, color: inkSoft, topY: 78)
    centred("Tunk reads only the accelerometer. Nothing leaves the machine.",
            size: 11, weight: .regular, color: inkSoft, topY: height - 34)
    ctx.cgContext.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let reps = [draw(scale: 1), draw(scale: 2)]
let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue]
guard let tiff = NSBitmapImageRep.representationOfImageReps(in: reps, using: .tiff, properties: props) else {
    FileHandle.standardError.write("could not encode TIFF\n".data(using: .utf8)!)
    exit(1)
}
do {
    try tiff.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
