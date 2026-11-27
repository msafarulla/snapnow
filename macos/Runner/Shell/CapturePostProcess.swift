import AppKit
import ImageIO

/// What a fresh capture goes through before the rest of the app sees it: the watermark, the date and time stamp and the
/// rounded corners, each a setting (Settings › Capture), in that order. Each step takes a picture and gives one back, so the
/// whole chain is one read of the file and one write (before, every step read the PNG, redrew it and wrote it again: with the
/// stamp and the rounded corners, which are on by default, that was two decodes and two PNG encodes of a Retina screenshot).
/// A step that has nothing to do or fails leaves the picture as it was.
enum CapturePostProcess {
    enum Step { case watermark, stamp, roundCorners }

    /// The steps the settings ask for, in order.
    static func steps() -> [Step] {
        var steps: [Step] = []
        if UserDefaults.standard.bool(forKey: Prefs.wmEnabled) { steps.append(.watermark) }   // user's text/image watermark
        if Prefs.onByDefault(Prefs.stampTime) { steps.append(.stamp) }                         // date & time, bottom-right (on top)
        if Prefs.onByDefault(Prefs.roundCorners) { steps.append(.roundCorners) }               // rounded corners, last so it clips all
        return steps
    }

    static func apply(_ step: Step, to image: CGImage, dpi: CGFloat) -> CGImage? {
        switch step {
        case .watermark: return Watermark.process(image, dpi: dpi)
        case .stamp: return CaptureStamp.process(image, dpi: dpi)
        case .roundCorners: return RoundCorners.process(image, dpi: dpi)
        }
    }

    /// Runs `steps` on the PNG at `url`: read once, written once (a temp file, then a replace, so a failed encode never loses the
    /// capture). Nothing is written when no step changed anything. Safe off the main thread.
    @discardableResult
    static func run(_ steps: [Step], on url: URL) -> Bool {
        guard !steps.isEmpty, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72   // Retina captures carry 144
        var current = image, changed = false
        for step in steps {
            if let out = apply(step, to: current, dpi: dpi) { current = out; changed = true }
        }
        guard changed else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".post-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, current, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return false }
        return (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil
    }
}

/// Burns the capture's date & time into the bottom-right corner of the saved PNG (toggle: Prefs.stampTime).
/// Format: yyyy-MM-dd HH:mm, local time; a translucent pill keeps it legible on any background.
enum CaptureStamp {
    /// The picture with the stamp on it (`dpi`: Retina captures carry 144).
    static func process(_ image: CGImage, dpi: CGFloat) -> CGImage? {
        draw(on: image, scale: max(1, dpi / 72))
    }

    private static func draw(on image: CGImage, scale: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let text = df.string(from: Date()) as NSString
        // Light and subtle (no pill, no shadow); the colour adapts to the pixels under it so it stays legible
        // on a white capture as well as a dark one.
        // Hug the bottom-right corner very tightly (user, 2026-11-09): a couple of points from the right edge, and the digits'
        // baseline almost on the bottom edge (the text box's descender space is pulled back below).
        let margin = 3 * scale
        // Monospaced digits read cleanly as a timestamp and keep an even width.
        func measure(_ s: CGFloat) -> CGSize { text.size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: s, weight: .medium)]) }
        var fontSize = max(11 * scale, CGFloat(h) * 0.013)
        var ts = measure(fontSize)
        // Shrink the stamp so it always fits inside the capture instead of overflowing a small image (its left
        // end getting clipped) or swamping it. On an image too small to carry it legibly, drop it entirely.
        let avail = CGFloat(w) - margin * 2
        if ts.width > avail, ts.width > 0 { fontSize *= avail / ts.width; ts = measure(fontSize) }
        guard fontSize >= 7 * scale, ts.height <= CGFloat(h) * 0.5 else { return ctx.makeImage() }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let bottomGap = 1.5 * scale
        let baselineY = bottomGap + font.descender    // descender is negative: digits sit ~1.5pt above the bottom edge
        let region = CGRect(x: CGFloat(w) - ts.width - margin, y: CGFloat(h) - ts.height - bottomGap, width: ts.width, height: ts.height)
        let onLight = averageLuminance(of: image, in: region) > 0.6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (onLight ? NSColor.black : NSColor.white).withAlphaComponent(0.6),
        ]
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        text.draw(at: CGPoint(x: CGFloat(w) - ts.width - margin, y: baselineY), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Average brightness (0…1) of a region, by shrinking it to one pixel; picks the stamp's contrast colour.
    private static func averageLuminance(of image: CGImage, in rect: CGRect) -> CGFloat {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 1, r.height >= 1, let crop = image.cropping(to: r) else { return 1 }
        var px = [UInt8](repeating: 0, count: 4)
        guard let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        c.interpolationQuality = .medium
        c.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / 255
    }
}

/// A user-configured watermark (their own text and/or image) stamped on captures per the Watermark settings:
/// placement (bottom-right / centred / tiled) and opacity. Gated by Prefs.wmEnabled; written atomically.
enum Watermark {
    /// The picture with the watermark on it; nil when no text or image is set (or it could not be drawn).
    static func process(_ base: CGImage, dpi: CGFloat) -> CGImage? {
        let d = UserDefaults.standard
        let text = (d.string(forKey: Prefs.wmText) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let imgPath = d.string(forKey: Prefs.wmImage) ?? ""
        let wm = imgPath.isEmpty ? nil : NSImage(contentsOfFile: imgPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard !text.isEmpty || wm != nil else { return nil }
        let placement = d.string(forKey: Prefs.wmPlacement) ?? "bottomRight"
        let opacity = max(0.05, min(1, CGFloat(Prefs.wmOpacityValue) / 100))
        return render(base, scale: max(1, dpi / 72), text: text, wm: wm, placement: placement, opacity: opacity)
    }

    private static func render(_ base: CGImage, scale: CGFloat, text: String, wm: CGImage?, placement: String, opacity: CGFloat) -> CGImage? {
        let W = CGFloat(base.width), H = CGFloat(base.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        // Soft-light blend: the watermark melts into the image (gently lightening/darkening it) instead of
        // floating on top, so it reads as a subtle mark rather than pulling the eye.
        ctx.saveGState()
        ctx.setBlendMode(.softLight)

        // One watermark block centred at (cx, cy): the image fitted to imgW, with the text under it.
        func block(cx: CGFloat, cy: CGFloat, imgW: CGFloat, fontSize: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),  // light enough to recede
                .foregroundColor: NSColor.white.withAlphaComponent(opacity),
            ]
            let ts = text.isEmpty ? CGSize.zero : (text as NSString).size(withAttributes: attrs)
            let imgH = wm != nil ? imgW * CGFloat(wm!.height) / CGFloat(wm!.width) : 0
            let gap: CGFloat = (wm != nil && !text.isEmpty) ? fontSize * 0.3 : 0
            var top = cy + (imgH + gap + ts.height) / 2
            if let wm = wm {
                ctx.saveGState()
                ctx.setAlpha(opacity)
                ctx.draw(wm, in: CGRect(x: cx - imgW / 2, y: top - imgH, width: imgW, height: imgH))
                ctx.restoreGState()
                top -= imgH + gap
            }
            if !text.isEmpty {
                (text as NSString).draw(at: CGPoint(x: cx - ts.width / 2, y: top - ts.height), withAttributes: attrs)
            }
        }

        switch placement {
        case "center":
            block(cx: W / 2, cy: H / 2, imgW: min(W, H) * 0.4, fontSize: max(24 * scale, H * 0.05))
        case "tiled":
            let imgW = W * 0.11, fontSize = max(11 * scale, H * 0.015)
            let stepX = max(W / 3.2, imgW * 2), stepY = max(H / 3.2, fontSize * 8)
            var y = stepY * 0.5
            while y < H {
                var x = stepX * 0.5
                while x < W { block(cx: x, cy: y, imgW: imgW, fontSize: fontSize); x += stepX }
                y += stepY
            }
        default: // bottomRight, tucked above the timestamp corner
            let imgW = min(W * 0.18, 220 * scale), fontSize = max(10 * scale, H * 0.014)
            let imgH = wm != nil ? imgW * CGFloat(wm!.height) / CGFloat(wm!.width) : 0
            let probe: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .regular)]
            let ts = text.isEmpty ? CGSize.zero : (text as NSString).size(withAttributes: probe)
            let gap: CGFloat = (wm != nil && !text.isEmpty) ? fontSize * 0.3 : 0
            let blockW = max(wm != nil ? imgW : 0, ts.width), blockH = imgH + gap + ts.height
            let margin = fontSize * 1.4
            block(cx: W - margin - blockW / 2, cy: margin + blockH / 2, imgW: imgW, fontSize: fontSize)
        }
        ctx.restoreGState()   // end the soft-light blend
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Rounds the capture's corners (transparent outside a rounded rectangle), as the final step so overlays are
/// clipped with the image. Gated by Prefs.roundCorners; written atomically.
enum RoundCorners {
    static func process(_ base: CGImage, dpi: CGFloat) -> CGImage? {
        let w = base.width, h = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let radius = min(CGFloat(w), CGFloat(h)) * 0.025
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
