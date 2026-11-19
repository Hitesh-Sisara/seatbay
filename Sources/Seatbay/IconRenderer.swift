import AppKit
import CoreText

/// How an instance's icon differs from the stock Claude icon.
enum IconStyle: String, Codable, CaseIterable, Identifiable {
    case colorAndNumber, numberOnly, colorOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .colorAndNumber: return "Colour + number"
        case .numberOnly: return "Number badge"
        case .colorOnly: return "Colour only"
        }
    }
    var recolors: Bool { self != .numberOnly }
    var showsNumber: Bool { self != .colorOnly }
}

/// Draws per-instance icons: Claude's own icon re-hued to the instance colour, plus a numbered badge
/// and an optional text label. Everything is drawn on a 1024×1024 canvas (the macOS icon grid).
enum IconRenderer {
    static let canvas = 1024
    /// The icon body (squircle) inside the 1024 canvas, per Apple's macOS icon grid.
    static let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let bodyCornerRadius: CGFloat = 185

    // Claude's terracotta, measured from the installed icon (HSB saturation/brightness).
    private static let referenceSaturation: CGFloat = 0.72
    private static let referenceBrightness: CGFloat = 0.89

    // MARK: Public API

    /// The installed Claude icon (whatever version is installed, including Liquid Glass icons).
    static func claudeIcon(appURL: URL) -> CGImage? {
        image(from: NSWorkspace.shared.icon(forFile: appURL.path))
    }

    /// - Parameter api: adds an "API" tag in the bottom-left corner (instances on an API key or a gateway).
    static func render(base: CGImage, color: NSColor, number: Int, style: IconStyle, label: String, api: Bool = false) -> CGImage {
        let ctx = makeContext()
        let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)
        ctx.interpolationQuality = .high
        ctx.draw(style.recolors ? recolor(base, to: color) : base, in: full)

        withNSContext(ctx) {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { drawLabel(trimmed.uppercased(), in: ctx) }
            if style.showsNumber { drawBadge(number: number, color: color, filled: style == .numberOnly, in: ctx) }
            if api { drawAPITag(color: color, filled: style == .numberOnly, in: ctx) }
        }
        return ctx.makeImage()!
    }

    /// "API" tag in the bottom-left corner, styled like the number badge, inside the squircle.
    private static func drawAPITag(color: NSColor, filled: Bool, in ctx: CGContext) {
        let size = CGSize(width: 330, height: 172)
        let center = CGPoint(x: 318, y: CGFloat(canvas) - 752)
        let pill = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        let path = CGPath(roundedRect: pill, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor((filled ? color : NSColor.white).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        if filled {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(16)
            let inner = pill.insetBy(dx: 8, dy: 8)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: inner.height / 2, cornerHeight: inner.height / 2, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        }
        drawCentered("API", font: roundedFont(size: 132, weight: .heavy), color: filled ? .white : readableInk(for: color),
                     center: center, in: ctx)
    }

    /// Seatbay's own icon, drawn from assets/seatbay-icon.svg (macOS renders SVG natively).
    /// It's original artwork: no part of Claude's icon is used for the app itself.
    static func appIcon(svg: URL) throws -> CGImage {
        guard let image = NSImage(contentsOf: svg) else {
            throw NSError(domain: "Seatbay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read \(svg.path)"])
        }
        let ctx = makeContext()
        withNSContext(ctx) { image.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas)) }
        return ctx.makeImage()!
    }

    /// Writes a multi-resolution .icns using the system `iconutil`.
    static func writeICNS(_ image: CGImage, to destination: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mc-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = work.appendingPathComponent("icon.iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        for base in [16, 32, 128, 256, 512] {
            try writePNG(scaled(image, to: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            try writePNG(scaled(image, to: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        let tmpICNS = work.appendingPathComponent("icon.icns")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        proc.arguments = ["-c", "icns", "-o", tmpICNS.path, iconset.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "Seatbay", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "iconutil failed to build the icon"])
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmpICNS, to: destination)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Seatbay", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try data.write(to: url)
    }

    // MARK: Drawing helpers

    private static func makeContext(size: Int = canvas) -> CGContext {
        CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func image(from nsImage: NSImage) -> CGImage? {
        let ctx = makeContext()
        withNSContext(ctx) {
            nsImage.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), from: .zero, operation: .copy, fraction: 1)
        }
        return ctx.makeImage()
    }

    private static func scaled(_ image: CGImage, to size: Int) -> CGImage {
        let ctx = makeContext(size: size)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    /// Moves every coloured pixel to the target hue, scaling saturation/brightness relative to Claude's
    /// terracotta. White and grey pixels (the Claude glyph, highlights) are left alone.
    static func recolor(_ image: CGImage, to color: NSColor) -> CGImage {
        let size = canvas
        let ctx = makeContext()
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let raw = ctx.data else { return image }
        let px = raw.bindMemory(to: UInt8.self, capacity: size * size * 4)

        let target = color.usingColorSpace(.sRGB) ?? color
        var th: CGFloat = 0, ts: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        target.getHue(&th, saturation: &ts, brightness: &tb, alpha: &ta)
        let satScale = ts / referenceSaturation
        let briScale = tb / referenceBrightness

        for i in 0..<(size * size) {
            let o = i * 4
            let a = px[o + 3]
            if a == 0 { continue }
            let af = CGFloat(a) / 255
            let r = min(1, CGFloat(px[o]) / 255 / af)
            let g = min(1, CGFloat(px[o + 1]) / 255 / af)
            let b = min(1, CGFloat(px[o + 2]) / 255 / af)
            let mx = max(r, g, b), mn = min(r, g, b)
            let s = mx == 0 ? 0 : (mx - mn) / mx
            if s < 0.12 { continue }
            let weight = min(1, (s - 0.12) / 0.18)    // soft edge between glyph and background
            let (nr, ng, nb) = hsbToRGB(h: th, s: min(1, s * satScale), b: min(1, mx * briScale))
            let fr = r + (nr - r) * weight, fg = g + (ng - g) * weight, fb = b + (nb - b) * weight
            px[o] = UInt8(max(0, min(255, fr * af * 255)))
            px[o + 1] = UInt8(max(0, min(255, fg * af * 255)))
            px[o + 2] = UInt8(max(0, min(255, fb * af * 255)))
        }
        return ctx.makeImage() ?? image
    }

    private static func hsbToRGB(h: CGFloat, s: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        if s <= 0 { return (b, b, b) }
        let hh = (h.truncatingRemainder(dividingBy: 1)) * 6
        let i = Int(hh) % 6
        let f = hh - CGFloat(Int(hh))
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        switch i {
        case 0: return (b, t, p)
        case 1: return (q, b, p)
        case 2: return (p, b, t)
        case 3: return (p, q, b)
        case 4: return (t, p, b)
        default: return (b, p, q)
        }
    }

    /// Round number badge in the bottom-right corner, kept inside the squircle so macOS doesn't
    /// put the icon in a grey "legacy" frame.
    private static func drawBadge(number: Int, color: NSColor, filled: Bool, in ctx: CGContext) {
        let radius: CGFloat = 148
        let center = CGPoint(x: 752, y: CGFloat(canvas) - 752)
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor((filled ? color : NSColor.white).cgColor)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()

        if filled {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(16)
            ctx.strokeEllipse(in: circle.insetBy(dx: 8, dy: 8))
        }

        let text = "\(number)"
        let fontSize: CGFloat = text.count == 1 ? 200 : (text.count == 2 ? 154 : 116)
        let textColor = filled ? NSColor.white : readableInk(for: color)
        drawCentered(text, font: roundedFont(size: fontSize, weight: .heavy), color: textColor, center: center, in: ctx)
    }

    /// A text strip across the top of the icon (e.g. "WORK"), clipped to the icon shape.
    private static func drawLabel(_ text: String, in ctx: CGContext) {
        let stripHeight: CGFloat = 150
        let strip = CGRect(x: bodyRect.minX, y: bodyRect.maxY - stripHeight, width: bodyRect.width, height: stripHeight)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bodyRect.insetBy(dx: 2, dy: 2), cornerWidth: bodyCornerRadius,
                           cornerHeight: bodyCornerRadius, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        ctx.fill(strip)
        ctx.restoreGState()

        var size: CGFloat = 96
        let maxWidth = bodyRect.width - 2 * bodyCornerRadius * 0.55
        var font = roundedFont(size: size, weight: .bold)
        while size > 40, textWidth(text, font: font) > maxWidth {
            size -= 4
            font = roundedFont(size: size, weight: .bold)
        }
        drawCentered(text, font: font, color: .white, center: CGPoint(x: strip.midX, y: strip.midY - 4), in: ctx)
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetImageBounds(line, nil).width
    }

    /// Draws text so its visible glyphs are centred on `center` (not the font's line box).
    private static func drawCentered(_ text: String, font: NSFont, color: NSColor, center: CGPoint, in ctx: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        // The text matrix/position are not part of the saved graphics state and CTLineDraw advances
        // the position, so reset them before measuring, or the second string drawn lands off-centre.
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: center.x - bounds.width / 2 - bounds.minX,
                                   y: center.y - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// A darker shade of the instance colour for text on a white badge (light colours get darkened more).
    private static func readableInk(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.05), brightness: min(b, 0.78), alpha: 1)
    }
}
