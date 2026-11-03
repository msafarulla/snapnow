import AppKit
import ScreenCaptureKit

/// Scrolling capture: pick an area over something that scrolls (a web page, a document, a long chat) and
/// SnapNow scrolls it for you, shooting as it goes, and stitches the shots into one tall image.
/// Moving the mouse stops it early (what was captured so far is kept). The scrolling is done with
/// continuous (trackpad-style) pixel scroll events sent to the window under the area, which browsers apply
/// straight away instead of animating. Each shot is taken only once the picture has stopped changing,
/// and consecutive shots are aligned by finding where a textured strip of the previous one reappears, so
/// a page that scrolls less than asked (its end, or a sluggish page) is still stitched correctly. A header
/// and footer that stay put while the rest scrolls (sticky bars, scrollbars) are kept out of the middle
/// and appear once, at the top and the bottom.
enum ScrollCapture {
    private static var running = false

    /// Appends a line to ~/Library/Caches/SnapLite/scroll-capture.log (the last run only), for support.
    static func note(_ line: String) {
        let url = Capture.cacheFolder.appendingPathComponent("scroll-capture.log")
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let text = "\(f.string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    private static let maxFrames = 120
    private static let maxHeight = 40_000                  // pixels, the tallest stitched image
    private static let settleTries = 6                     // shots compared until two in a row are equal
    private static let cancelDistance: CGFloat = 24        // points the mouse has to move to stop

    /// `area` (global Cocoa points) skips the picker: scripted captures and tests.
    static func start(area: CGRect? = nil, sound: Bool, completion: @escaping (URL?) -> Void) {
        guard !running else { note("already running"); completion(nil); return }
        if let area {
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) }
            guard let screen, area.width >= 40, area.height >= 60 else { note("scripted area rejected: \(NSStringFromRect(area))"); completion(nil); return }
            running = true
            Task { @MainActor in
                let url = await run(area, on: screen, sound: sound)
                running = false
                completion(url)
            }
            return
        }
        RegionCapture.pick(completion: { rect, screen in
            guard let rect, let screen, rect.width >= 40, rect.height >= 60 else { completion(nil); return }
            running = true
            Task { @MainActor in
                let url = await run(rect, on: screen, sound: sound)
                running = false
                completion(url)
            }
        }, fallback: {
            Toast.show("Scrolling capture needs Screen Recording access", symbol: "exclamationmark.triangle.fill")
            completion(nil)
        })
    }

    // MARK: The loop

    @MainActor static func run(_ area: CGRect, on screen: NSScreen, sound: Bool) async -> URL? {
        try? FileManager.default.removeItem(at: Capture.cacheFolder.appendingPathComponent("scroll-capture.log"))
        note("start: area \(NSStringFromRect(area)) screen \(NSStringFromRect(screen.frame))")
        // Shots come from ScreenCaptureKit when it offers the display; otherwise from /usr/sbin/screencapture
        // (-R, the same route the region picker falls back to), which is slower per shot but works wherever
        // the app's Screen Recording permission does.
        let scale = screen.backingScaleFactor
        var kit: (SCContentFilter, SCStreamConfiguration)?
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let display = content.displays.first(where: { $0.displayID == id }) {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY, width: area.width, height: area.height)
            config.width = Int(area.width * scale)
            config.height = Int(area.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            kit = (filter, config)
        }
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let cliRect = CGRect(x: area.minX, y: mainHeight - area.maxY, width: area.width, height: area.height)   // main display, top-left origin
        note("grabber: \(kit == nil ? "screencapture -R" : "ScreenCaptureKit"), scale \(scale)")

        // The cursor goes to the middle of the area (scroll events land on the window under it) and comes back after
        let mouseBefore = NSEvent.mouseLocation
        let centre = CGPoint(x: area.midX, y: area.midY)
        CGWarpMouseCursorPosition(cg(centre))
        CGAssociateMouseAndMouseCursorPosition(1)
        let outline = RegionCapture.showOutline(area)
        let hud = HUD(above: area)
        defer {
            outline.orderOut(nil)
            hud.close()
            CGWarpMouseCursorPosition(cg(mouseBefore))
        }
        try? await Task.sleep(nanoseconds: 350_000_000)   // the picker's overlay is gone and the page is still
        let placed = NSEvent.mouseLocation

        var shotError: String?
        func shoot() async -> Frame? {
            do {
                let image: CGImage
                if let (filter, config) = kit {
                    image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } else {
                    image = try await screencapture(cliRect)
                }
                guard let frame = Frame(image) else { shotError = "could not read the shot"; return nil }
                guard !frame.blank else { shotError = "the shot came back blank (Screen Recording permission?)"; return nil }
                return frame
            } catch {
                shotError = error.localizedDescription
                note("shot failed: \(error.localizedDescription)")
                return nil
            }
        }
        /// A shot taken once two in a row are the same (bounded: a page with an animation is shot as it is).
        func settled() async -> Frame? {
            var last = await shoot()
            for _ in 0..<settleTries {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let next = await shoot() else { return last }
                if let l = last, l.same(as: next) { return next }
                last = next
            }
            return last
        }
        func moved() -> Bool { hypot(NSEvent.mouseLocation.x - placed.x, NSEvent.mouseLocation.y - placed.y) > cancelDistance }

        guard let first = await settled() else {
            note("no first shot: \(shotError ?? "?")")
            outline.orderOut(nil)
            hud.close()
            PermissionGuide.shared.show()   // the only known cause: SnapNow's Screen Recording permission is off or stale
            return nil
        }
        let stepPoints = max(40, Int(area.height * 0.6))     // 60% of the area per scroll: plenty of overlap to match
        let result = await stitch(first: first, scale: scale, step: Int(CGFloat(stepPoints) * scale),
                                  next: { await settled() }, scroll: { scroll(by: stepPoints, at: centre) },
                                  cancelled: moved, progress: { hud.text = "Scrolling… \($0) shots · move the mouse to stop" })
        let stitcher = result.stitcher, frames = result.frames, reason = result.reason
        let w = first.w
        note("done: \(frames) shots, \(stitcher.height) px tall \(reason)")
        guard let image = stitcher.image(width: w) else { return nil }
        let url = Capture.newCaptureURL(prefix: "SnapNow Scroll")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        if sound {
            NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play()
        }
        if !reason.isEmpty && reason != "stopped" {
            Toast.show("Scrolling capture \(reason)", symbol: "exclamationmark.triangle.fill",
                       detail: "Kept what was captured: \(frames) shots, \(Int(CGFloat(stitcher.height) / scale)) points tall")
        }
        return url
    }


    /// The scroll-shoot-align loop, apart from the screen: `next` gives the shot after a `scroll`, so it can be
    /// driven by synthetic frames in tests. Returns what was stitched, the number of shots, and why it stopped
    /// ("" = the end of the page, "stopped" = the user, otherwise a problem to tell the user about).
    @MainActor static func stitch(first: Frame, scale: CGFloat, step: Int, next: @MainActor () async -> Frame?, scroll: @MainActor () -> Void,
                                  cancelled: @MainActor () -> Bool, progress: @MainActor (Int) -> Void = { _ in }) async -> (stitcher: Stitcher, frames: Int, reason: String) {
        let h = first.h
        var stitcher = Stitcher(first: first)
        var header = 0, footer = 0                            // rows that stay put (sticky bars), from the first scroll
        var previous = first
        var stalls = 0, frames = 1, reason = ""
        var assumedRuns = 0

        loop: while frames < maxFrames, stitcher.height < maxHeight {
            if cancelled() { reason = "stopped"; break }
            progress(frames)
            scroll()
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let next = await next() else { reason = "lost a shot"; break }
            frames += 1
            if next.same(as: previous) {                     // nothing moved at all: the end, or not scrollable
                stalls += 1
                if stalls >= 2 { break }
                continue
            }
            if frames == 2 {
                header = Frame.commonRows(previous, next, fromTop: true, limit: h * 2 / 5)
                footer = Frame.commonRows(previous, next, fromTop: false, limit: h * 2 / 5)
                if footer > 0 { stitcher.trimFirst(bottom: footer) }   // the sticky footer goes at the very end instead
            }
            let content = h - footer
            let shift = Frame.displacement(from: previous, to: next, header: header, content: content, scale: scale, expected: step)
            note("shot \(frames): header \(header), footer \(footer), shift \(shift)")
            switch shift {
            case .moved(let d):
                stalls = 0
                assumedRuns = 0
                stitcher.append(next, rows: (content - d)..<content)
            case .still:                                      // the content stayed; only something else changed
                stalls += 1
                if stalls >= 2 { break loop }
                continue
            case .flat:                                       // nothing to align on (a blank stretch): take the scroll as sent
                assumedRuns += 1
                if assumedRuns > 3 { break loop }
                let d = min(step, content - header)
                stitcher.append(next, rows: (content - d)..<content)
            case .unsure:
                reason = "could not align a shot"
                break loop
            }
            previous = next
        }
        if frames >= maxFrames || stitcher.height >= maxHeight { reason = "reached the size limit" }
        if footer > 0 { stitcher.append(previous, rows: (h - footer)..<h) }   // the sticky footer, once
        return (stitcher, frames, reason)
    }

    struct ShotError: LocalizedError {
        let errorDescription: String?
    }

    /// One shot of `rect` (main-display top-left points) by /usr/sbin/screencapture, as BMP for speed.
    private static func screencapture(_ rect: CGRect) async throws -> CGImage {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snapnow-scroll-\(UUID().uuidString).bmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-t", "bmp", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", tmp.path]
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in p.terminationHandler = { _ in c.resume() } }
        guard let source = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
            throw ShotError(errorDescription: "screencapture gave no image")
        }
        return image
    }

    /// Cocoa global point → CoreGraphics global point (top-left origin of the main display).
    private static func cg(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    /// One continuous (trackpad-style) scroll of `points` down, delivered to whatever is under `at`.
    private static func scroll(by points: Int, at: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-points), wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.location = cg(at)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Frames and matching

    /// A shot as RGBA bytes (row 0 at the top), for comparing and cropping.
    struct Frame {
        let image: CGImage
        let w: Int, h: Int
        let px: [UInt8]   // RGBA8, w*4 bytes a row

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok, w > 0, h > 0 else { return nil }
            self.image = image
            self.w = w
            self.h = h
            px = buf
        }

        /// Every sampled pixel black or clear: no permission, or a failed shot.
        var blank: Bool {
            var any = false
            px.withUnsafeBufferPointer { a in
                for y in stride(from: 0, to: h, by: max(1, h / 24)) {
                    for x in stride(from: 0, to: w, by: max(1, w / 24)) {
                        let i = (y * w + x) * 4
                        if a[i] | a[i + 1] | a[i + 2] != 0 { any = true; return }
                    }
                }
            }
            return !any
        }

        /// Columns compared: every third pixel, keeping clear of the right edge where a scrollbar may sit.
        func columns(scale: CGFloat) -> StrideTo<Int> { stride(from: 2, to: max(3, w - Int(20 * scale)), by: 3) }

        /// Mean absolute RGB difference (0…255) between row `ya` here and row `yb` of `other`.
        func rowDiff(_ ya: Int, _ other: Frame, _ yb: Int, cols: StrideTo<Int>) -> Int {
            var sum = 0, n = 0
            px.withUnsafeBufferPointer { a in
                other.px.withUnsafeBufferPointer { b in
                    let ra = ya * w * 4, rb = yb * w * 4
                    for x in cols {
                        let i = ra + x * 4, j = rb + x * 4
                        sum += abs(Int(a[i]) - Int(b[j])) + abs(Int(a[i + 1]) - Int(b[j + 1])) + abs(Int(a[i + 2]) - Int(b[j + 2]))
                        n += 3
                    }
                }
            }
            return n == 0 ? 0 : sum / n
        }

        /// Whether rows `ys` have enough variation to be found again (a blank stretch matches everywhere).
        func textured(_ ys: Range<Int>, cols: StrideTo<Int>) -> Bool {
            var sum = 0, n = 0
            px.withUnsafeBufferPointer { a in
                for y in ys {
                    let r = y * w * 4
                    for x in cols { sum += Int(a[r + x * 4]) + Int(a[r + x * 4 + 1]) + Int(a[r + x * 4 + 2]); n += 3 }
                }
            }
            guard n > 0 else { return false }
            let mean = sum / n
            var dev = 0
            px.withUnsafeBufferPointer { a in
                for y in ys {
                    let r = y * w * 4
                    for x in cols { dev += abs(Int(a[r + x * 4]) - mean) + abs(Int(a[r + x * 4 + 1]) - mean) + abs(Int(a[r + x * 4 + 2]) - mean) }
                }
            }
            return dev / n > 6
        }

        /// The same picture (sampled rows), i.e. nothing changed between two shots.
        func same(as other: Frame) -> Bool {
            guard w == other.w, h == other.h else { return false }
            let cols = columns(scale: 1)
            for y in stride(from: 0, to: h, by: 7) where rowDiff(y, other, y, cols: cols) > 2 { return false }
            return true
        }

        /// How many rows from the top (or bottom) are the same in both shots: a bar that stayed put while
        /// the rest scrolled.
        static func commonRows(_ a: Frame, _ b: Frame, fromTop: Bool, limit: Int) -> Int {
            let cols = a.columns(scale: 1)
            var n = 0
            while n < limit {
                let y = fromTop ? n : a.h - 1 - n
                guard a.rowDiff(y, b, y, cols: cols) <= 3 else { break }
                n += 1
            }
            return n
        }

        enum Shift { case moved(Int), still, flat, unsure }

        /// By how many rows the content moved up between `prev` and `next` (`expected`: the scroll that was asked
        /// for, in rows). Two textured strips of `prev` (the lowest one above the footer and one higher up) are
        /// scored together against every candidate position in `next` from `header` down; near-ties (rows that
        /// look like their neighbours) go to the candidate closest to `expected`. `.flat` when `prev` has nothing
        /// to align on, `.unsure` when nothing matches well or the match is ambiguous.
        static func displacement(from prev: Frame, to next: Frame, header: Int, content: Int, scale: CGFloat, expected: Int) -> Shift {
            let cols = prev.columns(scale: scale)
            let th = max(16, Int(24 * scale))
            // The lowest textured strip of the content, looking up from the footer
            var top = content - th
            while top > header + th, !prev.textured(top..<(top + th), cols: cols) { top -= th / 2 }
            guard top > header, prev.textured(top..<(top + th), cols: cols) else { return .flat }
            // A second strip well above it, when there is one
            var check = top - th * 3
            while check > header, !prev.textured(check..<(check + th), cols: cols) { check -= th }
            let second: Int? = check > header ? check : nil

            func score(_ y: Int) -> Int {   // mean diff of prev's strips vs next at the shift y implies, or nil when out of range
                let d = top - y
                var total = 0, rows = 0
                for r in 0..<th {
                    total += prev.rowDiff(top + r, next, y + r, cols: cols)
                    rows += 1
                }
                if let second, second - d >= header {
                    for r in 0..<th {
                        total += prev.rowDiff(second + r, next, second - d + r, cols: cols)
                        rows += 1
                    }
                }
                return total / max(1, rows)
            }
            var scores: [(y: Int, s: Int)] = []
            for y in stride(from: header, through: top, by: 1) { scores.append((y, score(y))) }
            guard let bestScore = scores.map(\.s).min(), bestScore <= 12 else {
                // No match: if the scroll that was asked for carries the lowest textured strip off the top, what
                // scrolled in below it was blank, so the shot is treated as flat (the scroll as sent is assumed)
                return top - expected < header ? .flat : .unsure
            }
            // Near-ties: the one nearest the scroll that was asked for
            let ties = scores.filter { $0.s <= bestScore + 1 }
            let best = ties.min { abs(top - $0.y - expected) < abs(top - $1.y - expected) }!
            let d = top - best.y
            // Ambiguous (a repeating pattern): another good match far from this one, and no second strip to settle it
            if second == nil, scores.contains(where: { $0.s <= bestScore + 3 && abs($0.y - best.y) > 3 }) { return .unsure }
            return d <= 1 ? .still : .moved(d)
        }
    }

    /// The rows kept so far, drawn into one tall image at the end.
    struct Stitcher {
        private var parts: [(CGImage, Int)] = []   // a slice and its height
        private(set) var height = 0

        init(first: Frame) { parts = [(first.image, first.h)]; height = first.h }

        /// Drops the bottom `rows` of the first shot (a sticky footer, appended once at the end instead).
        mutating func trimFirst(bottom rows: Int) {
            guard let (image, height) = parts.first, rows > 0, rows < height,
                  let slice = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: height - rows)) else { return }
            parts[0] = (slice, height - rows)
            self.height -= rows
        }

        mutating func append(_ frame: Frame, rows: Range<Int>) {
            guard !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= frame.h,
                  let slice = frame.image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: frame.w, height: rows.count)) else { return }
            parts.append((slice, rows.count))
            height += rows.count
        }

        func image(width w: Int) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: w, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            var y = 0
            for (slice, rows) in parts {
                ctx.draw(slice, in: CGRect(x: 0, y: height - y - rows, width: w, height: rows))   // CG draws bottom-up
                y += rows
            }
            return ctx.makeImage()
        }
    }

    // MARK: HUD

    /// A small click-through label above (or below) the area: never captured, never focused.
    private final class HUD {
        private let panel: NSPanel
        private let label: NSTextField

        var text: String { get { label.stringValue } set { label.stringValue = newValue } }

        init(above area: CGRect) {
            label = NSTextField(labelWithString: "Scrolling… move the mouse to stop")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            label.alignment = .center
            label.sizeToFit()
            let size = CGSize(width: label.frame.width + 28, height: 30)
            var origin = CGPoint(x: area.midX - size.width / 2, y: area.maxY + 10)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) }),
               origin.y + size.height > screen.visibleFrame.maxY { origin.y = area.minY - size.height - 10 }
            panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.ignoresMouseEvents = true
            panel.sharingType = .none            // never in the shots
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = NSView(frame: CGRect(origin: .zero, size: size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.88).cgColor
            view.layer?.cornerRadius = 8
            label.frame = CGRect(x: 14, y: (size.height - label.frame.height) / 2, width: size.width - 28, height: label.frame.height)
            view.addSubview(label)
            panel.contentView = view
            panel.orderFrontRegardless()
        }

        func close() { panel.orderOut(nil) }
    }
}
