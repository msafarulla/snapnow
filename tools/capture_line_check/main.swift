import AppKit

// Checks the capture line's look against the app's CaptureLine.swift: where the pegs and cards hang, the tilts, the swing,
// and renders the line with four sample captures over a dark and a light desktop at 1x and 2x.
//   tools/capture_line_check/run.sh [output folder]       (pictures only when a folder is given)

// Stand-ins for the parts of the app the line calls.
enum Prefs {
    static func onByDefault(_ key: String) -> Bool { true }
    static func offByDefault(_ key: String) -> Bool { false }
}
enum Capture { static let folder = URL(fileURLWithPath: NSTemporaryDirectory()) }
enum Theme { static func font(_ size: CGFloat, bold: Bool = false) -> NSFont { .systemFont(ofSize: size, weight: bold ? .bold : .regular) } }
enum Toast { static func show(_ message: String, detail: String? = nil) {} }
final class LiveDraw { static let shared = LiveDraw(); var busy = false }
final class Shell { static let shared = Shell(); func openEditor(_ url: URL) {} }
final class SnapLiteNative { static var shared: SnapLiteNative?; func invoke(_ method: String, _ arguments: Any? = nil) {} }

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

/// A made-up capture: a window with a title bar, a sidebar and some content, in its own colours.
func sample(_ size: NSSize, _ hue: CGFloat, dark: Bool) -> NSImage {
    NSImage(size: size, flipped: true) { r in
        NSColor(hue: hue, saturation: 0.35, brightness: dark ? 0.22 : 0.96, alpha: 1).setFill()
        r.fill()
        NSColor(white: dark ? 0.32 : 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: r.width, height: r.height * 0.09).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(i) * 16, y: r.height * 0.02, width: 10, height: 10)).fill()
        }
        NSColor(hue: hue, saturation: 0.5, brightness: dark ? 0.32 : 0.85, alpha: 1).setFill()
        NSRect(x: 0, y: r.height * 0.09, width: r.width * 0.24, height: r.height).fill()
        NSColor(hue: hue, saturation: 0.8, brightness: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.width * 0.3, y: r.height * 0.18, width: r.width * 0.62, height: r.height * 0.34), xRadius: 8, yRadius: 8).fill()
        NSColor(white: dark ? 0.75 : 0.35, alpha: 1).setFill()
        for i in 0..<4 { NSRect(x: r.width * 0.3, y: r.height * (0.6 + CGFloat(i) * 0.08), width: r.width * (0.55 - CGFloat(i) * 0.08), height: r.height * 0.035).fill() }
        return true
    }
}

/// A desktop picture behind the line: a dark or a light wash with a soft glow.
final class Desktop: NSView {
    let dark: Bool
    init(frame: NSRect, dark: Bool) { self.dark = dark; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let colours = dark ? [NSColor(red: 0.08, green: 0.07, blue: 0.16, alpha: 1), NSColor(red: 0.2, green: 0.1, blue: 0.3, alpha: 1)]
                           : [NSColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1), NSColor(red: 0.8, green: 0.87, blue: 0.95, alpha: 1)]
        NSGradient(colors: colours)?.draw(in: bounds, angle: -20)
    }
}

@main
struct CaptureLineCheck {
    static func main() {
        let out = CommandLine.arguments.dropFirst().first
        let names = ["Screenshot 2026-11-15 at 09.12.04.png", "Screenshot 2026-11-15 at 09.40.31.png",
                     "Screenshot 2026-11-15 at 10.02.57.png", "Recording 2026-11-15 at 10.15.10.mov"]
        let urls = names.map { URL(fileURLWithPath: "/nonexistent/\($0)") }
        let sizes = [NSSize(width: 1440, height: 900), NSSize(width: 800, height: 600), NSSize(width: 600, height: 860), NSSize(width: 1680, height: 720)]
        let width: CGFloat = 1000, height: CGFloat = 150

        // tilts: within -3...3, never straight, the same for the same name, not all alike
        let tilts = names.map { CaptureCardView.tilt(for: $0) }
        for (n, t) in zip(names, tilts) {
            check(abs(t) >= 0.6 && abs(t) <= 3, "tilt \(t) for \(n) in 0.6...3 either way")
            check(CaptureCardView.tilt(for: n) == t, "tilt for \(n) stable")
        }
        check(Set(tilts).count == tilts.count, "four different tilts")
        check(tilts.contains { $0 < 0 } && tilts.contains { $0 > 0 }, "tilts both ways")
        let many = (0..<400).map { CaptureCardView.tilt(for: "Screenshot \($0).png") }
        check(many.allSatisfy { abs($0) >= 0.6 && abs($0) <= 3 }, "400 tilts in range")
        check(many.filter { $0 < 0 }.count > 150 && many.filter { $0 > 0 }.count > 150, "tilts spread both ways")

        // the swing: 7 degrees at once, dies out, still by 1.5 s
        check(abs(CaptureCardView.swingAngle(at: 0) - 7) < 1e-6, "swing starts at 7 degrees")
        check(CaptureCardView.swingAngle(at: 1.5) == 0, "swing over at 1.5 s")
        check(stride(from: 0.6, through: 1.5, by: 0.05).allSatisfy { abs(CaptureCardView.swingAngle(at: CGFloat($0))) < 1.2 }, "swing small after 0.6 s")
        check(stride(from: 0.0, through: 0.6, by: 0.02).contains { CaptureCardView.swingAngle(at: CGFloat($0)) < -1 }, "swing goes back the other way")

        func line(dark: Bool) -> (NSView, CaptureLineView, [CaptureCardView]) {
            let root = Desktop(frame: NSRect(x: 0, y: 0, width: width, height: height + 40), dark: dark)
            let lineView = CaptureLineView(owner: CaptureLine.shared)
            lineView.frame = NSRect(x: 0, y: 40, width: width, height: height)     // the strip at the top of the desktop
            root.addSubview(lineView)
            lineView.setFiles(urls, width: width)
            let cards = lineView.subviews.compactMap { $0 as? CaptureCardView }
            for (i, card) in cards.enumerated() { card.show(sample(sizes[i], [0.6, 0.08, 0.35, 0.8][i], dark: i % 2 == 1)) }
            return (root, lineView, cards)
        }

        // where they hang: each peg on the cord, evenly spaced, the same distance below it, the whole card inside the strip
        let (_, lineView, cards) = line(dark: true)
        check(cards.count == 4, "four cards")
        let pegs = cards.map { lineView.convert($0.pegPoint, from: $0) }
        for (i, p) in pegs.enumerated() {
            check(abs(p.y - lineView.cordY(at: p.x, width: width)) < 0.5, "card \(i): peg on the cord (\(p))")
            check(abs(cards[i].frameCenterRotation - tilts[i]) < 1e-6, "card \(i): turned by its tilt")
            // the card's top centre sits the same way under every peg (same hang height below the line)
            let top = lineView.convert(NSPoint(x: cards[i].cardRect.midX, y: cards[i].cardRect.minY), from: cards[i])
            check(abs(hypot(top.x - p.x, top.y - p.y) - (cards[i].cardRect.minY - cards[i].pegPoint.y)) < 0.5, "card \(i): card top under its peg")
            let r = cards[i].cardRect
            for c in [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)] {
                let q = lineView.convert(c, from: cards[i])
                check(q.y + 6 < height - 4, "card \(i): bottom corner \(q) inside the strip, also lowered under the pointer")
            }
        }
        for i in 1..<pegs.count { check(abs(pegs[i].x - pegs[i - 1].x - CaptureLineView.slot) < 0.5, "even gaps \(i)") }
        check(abs((pegs[0].x + pegs[3].x) / 2 - width / 2) < 0.5, "centred when they fit")
        let gap = CaptureLineView.slot - CaptureCardView.cardSize.width
        check(gap >= 0.3 * CaptureCardView.cardSize.width, "generous gaps (\(gap) pt)")

        // the same file hangs the same way after a reload
        lineView.setFiles(Array(urls.dropFirst()), width: width)
        let again = lineView.subviews.compactMap { $0 as? CaptureCardView }
        check(again.first?.url == urls[1] && again.first.map { abs($0.frameCenterRotation - tilts[1]) < 1e-6 } == true, "tilt kept after a reload")

        if let out {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            for dark in [true, false] {
                let (root, _, _) = line(dark: dark)
                for scale in [1, 2] {
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width) * scale, pixelsHigh: Int(root.bounds.height) * scale,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = root.bounds.size
                    root.cacheDisplay(in: root.bounds, to: rep)
                    let path = "\(out)/line-\(dark ? "dark" : "light")-\(scale)x.png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)")
                }
            }
        }
        print(failures == 0 ? "capture line check: all passed" : "capture line check: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
