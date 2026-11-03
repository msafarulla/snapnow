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
        func moved() -> Bool { hud.stopRequested || hypot(NSEvent.mouseLocation.x - placed.x, NSEvent.mouseLocation.y - placed.y) > cancelDistance }

        guard let first = await settled() else {
            note("no first shot: \(shotError ?? "?")")
            outline.orderOut(nil)
            hud.close()
            PermissionGuide.shared.show()   // the only known cause: SnapNow's Screen Recording permission is off or stale
            return nil
        }
        // 40% of the area per scroll: enough overlap to match even when the lowest part of each view was still
        // loading (feeds show placeholders below the fold that fill in once scrolled up)
        let stepPoints = max(40, Int(area.height * 0.4))
        let result = await stitch(first: first, scale: scale, step: Int(CGFloat(stepPoints) * scale),
                                  next: { await settled() }, scroll: { kind in
                                      switch kind {
                                      case .pixels: scroll(by: stepPoints, at: centre)
                                      case .tick: tick(at: centre)
                                      }
                                  },
                                  cancelled: moved, progress: { hud.text = "Scrolling… \($0) shots · Enter stops and keeps it" })
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
        if reason.hasPrefix("found nothing") {
            Toast.show("Nothing scrolled under the cursor", symbol: "exclamationmark.triangle.fill",
                       detail: "Kept a single shot. A video player or a paged view (Shorts, Reels) doesn't scroll; try the page around it, or drag just the part that scrolls.")
        } else if !reason.isEmpty && reason != "stopped" {
            Toast.show("Scrolling capture \(reason)", symbol: "exclamationmark.triangle.fill",
                       detail: "Kept what was captured: \(frames) shots, \(Int(CGFloat(stitcher.height) / scale)) points tall")
        }
        return url
    }


    /// The scroll-shoot-align loop, apart from the screen: `next` gives the shot after a `scroll`, so it can be
    /// driven by synthetic frames in tests. Returns what was stitched, the number of shots, and why it stopped
    /// ("" = the end of the page, "stopped" = the user, otherwise a problem to tell the user about).
    /// How the engine asks for movement: smooth pixels (pages), or a wheel tick (paged views like Shorts).
    enum ScrollKind { case pixels, tick }

    @MainActor static func stitch(first: Frame, scale: CGFloat, step: Int, next: @MainActor () async -> Frame?, scroll: @MainActor (ScrollKind) -> Void,
                                  cancelled: @MainActor () -> Bool, progress: @MainActor (Int) -> Void = { _ in }) async -> (stitcher: Stitcher, frames: Int, reason: String) {
        let h = first.h
        var stitcher = Stitcher(first: first)
        var header = 0, footer = 0                            // rows that stay put (sticky bars), from the first scroll
        var previous = first
        var stalls = 0, frames = 1, reason = ""
        var assumedRuns = 0
        // The newest rows of a view are the least trustworthy (feeds fill them in after they scroll into view),
        // so each view's new bottom rows are kept pending and taken from the following view instead, where they
        // sit higher up and have had time to load; whatever is still pending at the end comes from the last view.
        var pending: (frame: Frame, rows: Range<Int>)?
        var cropDecided = false
        var ticked = false        // the last movement was a wheel tick (pixel scrolling had done nothing)
        var paged = false         // a paged view (Shorts, Reels): each tick is a new page, stacked whole
        var retried = false       // one more shot after an alignment that failed (content may have been mid-load)
        func advance(_ next: Frame, by d: Int, content: Int) {
            if let p = pending {
                let inNext = (content - d - p.rows.count)..<(content - d)
                if inNext.lowerBound >= header { stitcher.append(next, rows: inNext) } else { stitcher.append(p.frame, rows: p.rows) }
            }
            pending = (next, (content - d)..<content)
        }

        loop: while frames < maxFrames, stitcher.height < maxHeight {
            if cancelled() { reason = "stopped"; break }
            progress(frames)
            // A wheel tick after a stall: a paged view ignores smooth scrolling but turns a page per tick
            ticked = paged || stalls > 0
            scroll(ticked ? .tick : .pixels)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let next = await next() else { reason = "lost a shot"; break }
            frames += 1
            if next.same(as: previous) {                     // nothing moved at all: the end, or not scrollable
                stalls += 1
                if stalls >= 2 { break }
                continue
            }
            if frames == 2 || (header == 0 && footer == 0) {
                header = Frame.commonRows(previous, next, fromTop: true, limit: h * 2 / 5)
                footer = Frame.commonRows(previous, next, fromTop: false, limit: h * 2 / 5)
            }
            let content = h - footer
            if paged {                                        // every tick is the next page, kept whole
                let moving = previous.movingColumns(to: next, rows: header..<content, scale: scale)
                if moving.count < previous.columns(scale: scale).count / 4 { stalls += 1; if stalls >= 2 { break }; continue }
                stalls = 0
                stitcher.append(next, rows: header..<content)
                note("shot \(frames): page \(stitcher.height / max(1, content - header))")
                previous = next
                continue
            }
            let shift = Frame.displacement(from: previous, to: next, header: header, content: content, scale: scale,
                                           expected: ticked ? max(8, step / 6) : step)
            note("shot \(frames): header \(header), footer \(footer), shift \(shift)\(ticked ? " (after a wheel tick)" : "")")
            var d: Int
            switch shift {
            case .moved(let moved):
                stalls = 0
                assumedRuns = 0
                d = moved
                if !cropDecided {
                    // Only part of the width scrolls (a feed between sidebars): keep just that part, when what stays
                    // put on the sides is real content (a blank margin is left alone, so the page keeps its shape)
                    cropDecided = true
                    let moving = previous.movingColumns(to: next, rows: header..<content, scale: scale)
                    if moving.count >= 8, let l = moving.first, let r = moving.last {
                        let pad = Int(8 * scale)
                        let left = max(0, l - pad), right = min(previous.w, r + pad + 3)
                        let all = previous.columns(scale: scale)
                        let sides = all.filter { $0 < left || $0 >= right }
                        if sides.count > all.count / 6, previous.textured(columns: sides, rows: header..<content) {
                            stitcher.crop = left..<right
                            note("sidebars stay put: keeping columns \(left)..<\(right) of \(previous.w)")
                        }
                    }
                }
            case .still:                                      // the content stayed; only something else changed
                stalls += 1
                if stalls >= 2 { break loop }
                continue
            case .flat:                                       // nothing to align on (a blank stretch): take the scroll as sent
                assumedRuns += 1
                if assumedRuns > 3 { break loop }
                d = min(step, content - header)
            case .unsure:
                if ticked {
                    // Pixel scrolling did nothing and a wheel tick changed most of the view: a paged view. The
                    // first view stays whole; this and every further tick add a page.
                    let moving = previous.movingColumns(to: next, rows: header..<content, scale: scale)
                    if moving.count * 10 >= previous.columns(scale: scale).count * 6 {
                        paged = true
                        stalls = 0
                        stitcher.append(next, rows: header..<content)
                        note("paged view: stacking pages")
                        previous = next
                        continue
                    }
                }
                if !retried {                                 // once more: the page may have been mid-load
                    retried = true
                    note("shot \(frames): retrying")
                    continue
                }
                reason = "could not align a shot"
                dump(previous, "scroll-unsure-prev"); dump(next, "scroll-unsure-next")   // for diagnosis
                break loop
            }
            retried = false
            if pending == nil {
                // The first view's bottom rows wait for the next view too (same reason), and its sticky footer
                // rows go at the very end instead
                let tail = min(d, content - header - 1)
                stitcher.trimFirst(bottom: footer + tail)
                pending = (previous, (content - tail)..<content)
            }
            advance(next, by: d, content: content)
            previous = next
        }
        if frames >= maxFrames || stitcher.height >= maxHeight { reason = "reached the size limit" }
        if reason.isEmpty, pending == nil, !paged, frames >= 2 { reason = "found nothing that scrolls under the cursor" }
        if let p = pending { stitcher.append(p.frame, rows: p.rows) }       // the last view's bottom, as it is
        if footer > 0, pending != nil || paged { stitcher.append(previous, rows: (h - footer)..<h) }   // the sticky footer, once
        return (stitcher, frames, reason)
    }

    /// Writes a shot next to the log (~/Library/Caches/SnapLite/<name>.png) when a run has to give up.
    private static func dump(_ frame: Frame, _ name: String) {
        let url = Capture.cacheFolder.appendingPathComponent("\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, frame.image, nil)
        CGImageDestinationFinalize(dest)
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
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in c.resume() }   // set before run: a fast exit would otherwise never resume
            do { try p.run() } catch { c.resume() }
        }
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

    /// One mouse-wheel notch down (three lines), as a paged view (Shorts, Reels) expects, under `at`.
    private static func tick(at: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0) else { return }
        event.location = cg(at)
        event.post(tap: .cghidEventTap)
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
        func columns(scale: CGFloat) -> [Int] { Array(stride(from: 2, to: max(3, w - Int(20 * scale)), by: 3)) }

        /// The compared columns that change between `self` and `next` somewhere in rows `rows`: what scrolls.
        /// Columns that stay the same (a sidebar, a margin, a chat panel) would otherwise drown the match.
        func movingColumns(to next: Frame, rows: Range<Int>, scale: CGFloat) -> [Int] {
            let all = columns(scale: scale)
            var moving: [Int] = []
            px.withUnsafeBufferPointer { a in
                next.px.withUnsafeBufferPointer { b in
                    for x in all {
                        var changed = false
                        var y = rows.lowerBound
                        while y < rows.upperBound {
                            let i = (y * w + x) * 4
                            if abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) > 48 { changed = true; break }
                            y += 4
                        }
                        if changed { moving.append(x) }
                    }
                }
            }
            return moving
        }

        /// Whether columns `xs` hold anything but flat colour in rows `rows` (a sidebar with content, not a margin).
        func textured(columns xs: [Int], rows: Range<Int>) -> Bool {
            guard !xs.isEmpty else { return false }
            var sum = 0, n = 0
            px.withUnsafeBufferPointer { a in
                for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 6) {
                    for x in xs { let i = (y * w + x) * 4; sum += Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2]); n += 3 }
                }
            }
            guard n > 0 else { return false }
            let mean = sum / n
            var dev = 0
            px.withUnsafeBufferPointer { a in
                for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 6) {
                    for x in xs { let i = (y * w + x) * 4; dev += abs(Int(a[i]) - mean) + abs(Int(a[i + 1]) - mean) + abs(Int(a[i + 2]) - mean) }
                }
            }
            return dev / n > 6
        }

        /// Mean absolute RGB difference (0…255) between row `ya` here and row `yb` of `other`.
        func rowDiff(_ ya: Int, _ other: Frame, _ yb: Int, cols: [Int]) -> Int {
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
        func textured(_ ys: Range<Int>, cols: [Int]) -> Bool {
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
        /// for, in rows). Up to six textured strips spread through `prev` are each looked for in `next`; the shift
        /// most of them agree on wins, so a strip that changed meanwhile (an image that loaded, a playing video, a
        /// timestamp) can't spoil the match. Near-ties within a strip (rows that look like their neighbours) go to
        /// the candidate closest to `expected`. `.flat` when `prev` has nothing to align on, `.unsure` when the
        /// strips can't agree.
        static func displacement(from prev: Frame, to next: Frame, header: Int, content: Int, scale: CGFloat, expected: Int) -> Shift {
            // Only the columns that scroll take part: a sidebar or chat panel that stays put never lines up with any shift
            let all = prev.columns(scale: scale)
            var cols = prev.movingColumns(to: next, rows: header..<content, scale: scale)
            let th = max(16, Int(24 * scale))
            // When the moving columns can't be aligned: most of the width unchanged, with content, means the page
            // stayed put and something inside it (a video, an animation) is what changed
            func stayedPut() -> Bool {
                guard cols.count < all.count / 2 else { return false }
                let still = all.filter { !cols.contains($0) }
                guard prev.textured(columns: still, rows: header..<content) else { return false }
                var total = 0, n = 0
                for y in stride(from: header, to: content, by: 5) { total += prev.rowDiff(y, next, y, cols: still); n += 1 }
                return n > 0 && total / n <= 4
            }
            if cols.count < 8 { cols = all }
            let span = content - header
            guard span > th * 2 else { return stayedPut() ? .still : .flat }
            // Textured strips, from the bottom up, spread through the content
            var strips: [Int] = []
            var t = content - th
            let gap = max(th, (span - th) / 8)
            while t >= header, strips.count < 8 {
                var probe = t
                while probe > t - gap + th, probe >= header, !prev.textured(probe..<(probe + th), cols: cols) { probe -= th / 2 }
                if probe >= header, prev.textured(probe..<(probe + th), cols: cols) { strips.append(probe) }
                t -= gap
            }
            guard !strips.isEmpty else { return stayedPut() ? .still : .flat }

            func score(strip: Int, at y: Int) -> Int {   // mean diff of prev's strip vs next at row y
                var total = 0, rows = 0
                for r in stride(from: 0, to: th, by: 2) {
                    total += prev.rowDiff(strip + r, next, y + r, cols: cols)
                    rows += 1
                }
                return total / max(1, rows)
            }
            // Pages usually scroll exactly as asked: when the strips that are still in view agree on that (jointly
            // and most of them individually), take it, refined by a row or two
            func joint(_ cand: Int, only: [Int]? = nil) -> (mean: Int, good: Int, n: Int, goodStrips: [Int]) {
                var total = 0, good = 0, n = 0
                var goodStrips: [Int] = []
                for strip in only ?? strips where strip - cand >= header {
                    let sc = score(strip: strip, at: strip - cand)
                    total += sc; n += 1
                    if sc <= 12 { good += 1; goodStrips.append(strip) }
                }
                return (n == 0 ? Int.max : total / n, good, n, goodStrips)
            }
            if expected > 1 {
                var best = (d: expected, mean: Int.max, good: 0, n: 0, goodStrips: [Int]())
                for cand in [expected, expected - 1, expected + 1, expected - 2, expected + 2, expected - 3, expected + 3] where cand > 1 {   // nearest first: ties keep the ask
                    let j = joint(cand)
                    if j.mean < best.mean { best = (cand, j.mean, j.good, j.n, j.goodStrips) }
                }
                // Most strips match there (a strip that changed meanwhile, like a photo that re-rendered or a
                // tooltip, can pull the mean up without meaning anything), or all of them nearly do…
                let plausible = best.n > 0 && ((best.n >= 2 && best.good * 2 > best.n) || best.mean <= 16)
                // …and it must beat the shifts a few rows away clearly: sparse content (a terminal, code, blank
                // lines) scores "well enough" at a slightly wrong shift, which would put every seam off by a few rows
                var distinct = false
                if plausible {
                    // Judged on the strips that match there (a changed strip is noise at every shift)
                    let here = joint(best.d, only: best.goodStrips).mean
                    let around = [best.d - 5, best.d + 5, best.d - 9, best.d + 9].filter { $0 > 1 }.map { joint($0, only: best.goodStrips).mean }
                    // Clearly worse nearby: by 8, or by 40% (low-contrast content such as a photo of paper scores
                    // low everywhere), and never on the strength of a near-blank strip
                    distinct = !best.goodStrips.isEmpty && around.allSatisfy { $0 >= 4 && ($0 >= here + 8 || $0 * 10 >= here * 14) }
                    note("  good strips \(best.goodStrips): here \(here), around ±5/±9 \(around)")
                }
                note("  strips \(strips) · at the ask \(expected): mean \(best.mean), \(best.good)/\(best.n) strips good, distinct \(distinct)")
                if plausible && distinct { return .moved(best.d) }
            }
            // Otherwise each strip votes for its best shift (0…1.5× the ask); a strip whose match is ambiguous
            // (nearly as good somewhere else, as on a plain photo or blank paper) doesn't vote
            var votes: [(d: Int, s: Int)] = []
            let maxShift = max(expected * 3 / 2, th)
            for strip in strips {
                var scores: [(y: Int, s: Int)] = []
                for y in stride(from: max(header, strip - maxShift), through: strip, by: 1) { scores.append((y, score(strip: strip, at: y))) }
                guard let best = scores.map(\.s).min(), best <= 12 else { continue }
                let ties = scores.filter { $0.s <= best + 1 }
                let pick = ties.min { abs(strip - $0.y - expected) < abs(strip - $1.y - expected) }!
                if scores.contains(where: { $0.s <= best + 3 && abs($0.y - pick.y) > 3 }) { continue }   // ambiguous
                votes.append((strip - pick.y, best))
            }
            note("  votes \(votes.map { "\($0.d)@\($0.s)" })")
            if votes.isEmpty {
                if stayedPut() { return .still }
                // Nothing found: if the ask carries the lowest strip off the top, what scrolled in below was blank
                return strips[0] - expected < header ? .flat : .unsure
            }
            // The shift most strips agree on (within 2 rows)
            var bestD = votes[0].d, bestCount = 0
            for v in votes {
                let n = votes.filter { abs($0.d - v.d) <= 2 }.count
                if n > bestCount || (n == bestCount && abs(v.d - expected) < abs(bestD - expected)) { bestD = v.d; bestCount = n }
            }
            let agreed = votes.filter { abs($0.d - bestD) <= 2 }
            // Alone against others, with no agreement: too risky to append on
            if agreed.count < 2, votes.count >= 2 { return stayedPut() ? .still : .unsure }
            // The exact row: the agreeing strips scored together over the few candidates around their shift
            var d = bestD, bestJoint = Int.max
            for cand in (bestD - 2)...(bestD + 2) where cand >= 0 {
                var total = 0, n = 0
                for strip in strips where strip - cand >= header { total += score(strip: strip, at: strip - cand); n += 1 }
                guard n > 0 else { continue }
                let joint = total / n
                if joint < bestJoint || (joint == bestJoint && abs(cand - expected) < abs(d - expected)) { bestJoint = joint; d = cand }
            }
            return d <= 1 ? .still : .moved(d)
        }
    }

    /// The rows kept so far, drawn into one tall image at the end.
    struct Stitcher {
        private var parts: [(CGImage, Int)] = []   // a slice and its height
        private(set) var height = 0
        var crop: Range<Int>?                      // columns kept, when only part of the width scrolls

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

        func image(width full: Int) -> CGImage? {
            let x0 = crop?.lowerBound ?? 0
            let w = crop?.count ?? full
            guard let ctx = CGContext(data: nil, width: w, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            var y = 0
            for (slice, rows) in parts {
                let part = crop == nil ? slice : slice.cropping(to: CGRect(x: x0, y: 0, width: w, height: rows)) ?? slice
                ctx.draw(part, in: CGRect(x: 0, y: height - y - rows, width: w, height: rows))   // CG draws bottom-up
                y += rows
            }
            return ctx.makeImage()
        }
    }

    // MARK: HUD

    /// A non-activating panel that can still become key: Enter and Esc reach it while the page's app stays active
    /// (the same trick as the area picker), and its view turns them into a stop request.
    private final class KeyHUDPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
    private final class KeyView: NSView {
        var onStop: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76, 53: onStop?()                      // Return, keypad Enter, Esc
            default: super.keyDown(with: event)
            }
        }
    }

    /// A small label above (or below) the area: never captured; key, so Enter/Esc stop the capture.
    private final class HUD {
        private let panel: NSPanel
        private let label: NSTextField
        private(set) var stopRequested = false

        var text: String { get { label.stringValue } set { label.stringValue = newValue } }

        init(above area: CGRect) {
            label = NSTextField(labelWithString: "Scrolling… Enter stops and keeps it")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            label.alignment = .center
            label.sizeToFit()
            let size = CGSize(width: label.frame.width + 28, height: 30)
            var origin = CGPoint(x: area.midX - size.width / 2, y: area.maxY + 10)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) }),
               origin.y + size.height > screen.visibleFrame.maxY { origin.y = area.minY - size.height - 10 }
            panel = KeyHUDPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.ignoresMouseEvents = true
            panel.sharingType = .none            // never in the shots
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = KeyView(frame: CGRect(origin: .zero, size: size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.88).cgColor
            view.layer?.cornerRadius = 8
            label.frame = CGRect(x: 14, y: (size.height - label.frame.height) / 2, width: size.width - 28, height: label.frame.height)
            view.addSubview(label)
            view.onStop = { [weak self] in self?.stopRequested = true }
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            if !panel.isKeyWindow {
                // Some setups won't hand a background app a key window: come to the front, then take it. Scroll
                // events still reach the page (they go to the window under the cursor, active or not).
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
            }
            // Belt and braces: any Enter/Esc that reaches SnapNow at all
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if [36, 76, 53].contains(Int(e.keyCode)) { self?.stopRequested = true; return nil }
                return e
            }
            note("hud: key \(panel.isKeyWindow), app active \(NSApp.isActive)")
        }
        private var keyMonitor: Any?

        func close() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            panel.orderOut(nil)
        }
    }
}
