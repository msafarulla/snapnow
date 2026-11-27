import AppKit
import ImageIO

// Checks CapturePostProcess (macos/Runner/Shell/CapturePostProcess.swift), the chain a fresh capture goes through (watermark, date
// and time stamp, rounded corners):
//  - one pass over the file (read once, written once) gives exactly the picture the old way gave, one step at a time with
//    the file read and written in between (pixels and density equal);
//  - it works off the main thread, leaves no temp file, and leaves the file alone when no step has anything to do;
//  - how long that takes against the one-pass-per-step way, on screenshot-sized pictures.
//   tools/capture_post_test/run.sh

// Stand-ins for the settings the steps read (the real ones live in Settings.swift).
enum Prefs {
    static let wmEnabled = "watermark.enabled", stampTime = "capture.stampTime", roundCorners = "capture.roundCorners"
    static let wmText = "watermark.text", wmImage = "watermark.imagePath", wmPlacement = "watermark.placement", wmOpacity = "watermark.opacity"
    static var wmOpacityValue: Int { UserDefaults.standard.object(forKey: wmOpacity) == nil ? 8 : UserDefaults.standard.integer(forKey: wmOpacity) }
    static func onByDefault(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key) }
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("ok:   \(what)") } else { failures += 1; print("FAIL: \(what)") }
}

let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capture_post_test-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

/// A screenshot-like picture: window chrome, a sidebar, lines of text, photos (noise) and flat areas.
func screenshot(_ w: Int, _ h: Int, alpha: CGImageAlphaInfo) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)!
    ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: h - 56, width: w, height: 56))
    ctx.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w / 5, height: h - 56))
    var seed: UInt64 = 7
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    let font = NSFont.systemFont(ofSize: 26)
    for row in 0..<(h / 44) {
        ("Line \(row): the quick brown fox jumps over the lazy dog 0123456789" as NSString).draw(
            at: CGPoint(x: CGFloat(w / 5 + 40), y: CGFloat(h - 120 - row * 44)), withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
    }
    NSGraphicsContext.restoreGraphicsState()
    for _ in 0..<40 {                                      // coloured panels with a gradient look
        let r = CGRect(x: rnd() * CGFloat(w) * 0.8, y: rnd() * CGFloat(h) * 0.8, width: 80 + rnd() * 500, height: 60 + rnd() * 300)
        ctx.setFillColor(NSColor(hue: rnd(), saturation: 0.5, brightness: 0.9, alpha: 1).cgColor); ctx.fill(r)
    }
    // a photograph: noise in two patches
    if let data = ctx.data {
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        for y in stride(from: h / 3, to: h / 3 + h / 4, by: 1) {
            for x in 0..<(w / 4) { let i = y * ctx.bytesPerRow + (x + w / 2) * 4; px[i] = UInt8(rnd() * 255); px[i + 1] = UInt8(rnd() * 255); px[i + 2] = UInt8(rnd() * 255); px[i + 3] = 255 }
        }
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL, dpi: CGFloat = 144) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

/// The decoded pixels as premultiplied sRGB RGBA, and the density.
func pixels(_ url: URL) -> (w: Int, h: Int, dpi: CGFloat, bytes: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72, bytes)
}

func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    guard a.count == b.count else { return 255 }
    var worst = 0
    for i in 0..<a.count { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
    return worst
}

/// The old way: every step on its own, the file read and written in between.
func oneStepAtATime(_ steps: [CapturePostProcess.Step], on url: URL) { for step in steps { CapturePostProcess.run([step], on: url) } }

func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
func time(_ body: () -> Void) -> Double { let t = Date(); body(); return Date().timeIntervalSince(t) * 1000 }

UserDefaults.standard.set("Sample watermark", forKey: Prefs.wmText)
UserDefaults.standard.set(40, forKey: Prefs.wmOpacity)
let allSteps: [CapturePostProcess.Step] = [.watermark, .stamp, .roundCorners]

// 1. the settings choose the steps, in order
do {
    let d = UserDefaults.standard
    check(CapturePostProcess.steps() == [.stamp, .roundCorners], "default settings: stamp, then rounded corners")
    d.set(true, forKey: Prefs.wmEnabled)
    check(CapturePostProcess.steps() == [.watermark, .stamp, .roundCorners], "watermark first when it is on")
    d.set(false, forKey: Prefs.stampTime)
    check(CapturePostProcess.steps() == [.watermark, .roundCorners], "no stamp when it is off")
    d.set(false, forKey: Prefs.roundCorners); d.set(false, forKey: Prefs.wmEnabled)
    check(CapturePostProcess.steps().isEmpty, "nothing on: no steps")
    d.removeObject(forKey: Prefs.stampTime); d.removeObject(forKey: Prefs.roundCorners); d.removeObject(forKey: Prefs.wmEnabled)
}

// 2. one pass gives the same picture as one step at a time (opaque screenshots, both pixel layouts)
for (name, alpha) in [("RGBA", CGImageAlphaInfo.premultipliedLast), ("RGB, no alpha", CGImageAlphaInfo.noneSkipLast)] {
    let image = screenshot(1440, 900, alpha: alpha)
    for steps in [[CapturePostProcess.Step.stamp], [.roundCorners], [.stamp, .roundCorners], allSteps] {
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
        write(image, to: a); write(image, to: b)
        oneStepAtATime(steps, on: a)
        check(CapturePostProcess.run(steps, on: b), "\(name), \(steps): one pass changed the file")
        if let pa = pixels(a), let pb = pixels(b) {
            check(pa.w == pb.w && pa.h == pb.h && pa.dpi == pb.dpi && pa.dpi == 144, "\(name), \(steps): same size and density (\(pb.w)x\(pb.h) at \(pb.dpi))")
            let diff = maxDifference(pa.bytes, pb.bytes)
            check(diff == 0, "\(name), \(steps): identical pixels (largest difference \(diff))")
        } else { check(false, "\(name), \(steps): both files readable") }
    }
}

// 3. translucent corners fed into a later step (not an order the app uses): within one level
do {
    let image = screenshot(1000, 700, alpha: .premultipliedLast)
    let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
    write(image, to: a); write(image, to: b)
    let steps: [CapturePostProcess.Step] = [.roundCorners, .stamp]
    oneStepAtATime(steps, on: a); CapturePostProcess.run(steps, on: b)
    if let pa = pixels(a), let pb = pixels(b) { let d = maxDifference(pa.bytes, pb.bytes); check(d <= 1, "rounded corners then stamp: within one level (\(d))") }
}

// 4. nothing to do: the file is not touched; no temp file is left; a missing file is not a crash
do {
    let image = screenshot(600, 400, alpha: .noneSkipLast)
    let a = folder.appendingPathComponent("n.png")
    write(image, to: a)
    let before = try! Data(contentsOf: a)
    UserDefaults.standard.set("", forKey: Prefs.wmText)
    check(!CapturePostProcess.run([.watermark], on: a) && (try! Data(contentsOf: a)) == before, "a watermark with no text or image leaves the file as it was")
    check(!CapturePostProcess.run([], on: a) && (try! Data(contentsOf: a)) == before, "no steps leaves the file as it was")
    check(!CapturePostProcess.run([.stamp], on: folder.appendingPathComponent("missing.png")), "a missing file is skipped")
    UserDefaults.standard.set("Sample watermark", forKey: Prefs.wmText)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix(".post-") } ?? []
    check(left.isEmpty, "no temp file left in the folder")
}

// 5. off the main thread, as the app runs it
do {
    let a = folder.appendingPathComponent("t.png")
    write(screenshot(1200, 800, alpha: .premultipliedLast), to: a)
    let b = folder.appendingPathComponent("t2.png")
    write(screenshot(1200, 800, alpha: .premultipliedLast), to: b)
    oneStepAtATime(allSteps, on: b)
    let gate = DispatchSemaphore(value: 0)
    var ok = false
    DispatchQueue.global(qos: .userInitiated).async { ok = CapturePostProcess.run(allSteps, on: a); gate.signal() }
    gate.wait()
    check(ok, "runs on a background queue")
    if let pa = pixels(a), let pb = pixels(b) { check(maxDifference(pa.bytes, pb.bytes) == 0, "and gives the same picture as on this thread") }
}

// 6. how long: one pass against one step at a time (the default settings' two steps, and all three), Retina-sized pictures
for (label, w, h) in [("2880x1800 (14-inch MacBook Pro, full screen)", 2880, 1800), ("5120x2880 (27-inch 5K display, full screen)", 5120, 2880), ("1600x1000 (a region)", 1600, 1000)] {
    let image = screenshot(w, h, alpha: .noneSkipLast)
    for steps in [[CapturePostProcess.Step.stamp, .roundCorners], allSteps] {
        var old = [Double](), new = [Double]()
        for _ in 0..<5 {
            let a = folder.appendingPathComponent("o.png"), b = folder.appendingPathComponent("p.png")
            write(image, to: a); write(image, to: b)
            old.append(time { oneStepAtATime(steps, on: a) })
            new.append(time { CapturePostProcess.run(steps, on: b) })
        }
        print(String(format: "time  %@, %d steps: one at a time %.0f ms, one pass %.0f ms (%.0f%% less)", label, steps.count, median(old), median(new),
                     100 * (1 - median(new) / median(old))))
    }
}

try? FileManager.default.removeItem(at: folder)
print(failures == 0 ? "capture_post_test: all passed" : "capture_post_test: \(failures) failed")
exit(failures == 0 ? 0 : 1)
