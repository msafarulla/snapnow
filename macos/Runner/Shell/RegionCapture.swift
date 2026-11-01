import Cocoa
import ScreenCaptureKit

/// Region capture in the style of Snagit: the screen freezes and dims, dashed crosshair lines follow the
/// cursor, the window under it is outlined, and a magnifier shows the pixels and the size. Drag for an
/// area, click for the outlined window (or the whole screen), Esc cancels. Drags stay on the screen they
/// start on. The capture is cut from the frozen image, so it matches what was on screen when it began; with a
/// delay, the area is picked first, then a countdown runs over the live screen and the area is captured after it.
final class RegionCapture {
    private static var current: RegionCapture?

    struct Frozen {
        let screen: NSScreen
        let image: CGImage
        var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
    }

    private var frozen: [Frozen] = []
    private var windows: [CGRect] = []        // Cocoa global coordinates, front to back
    private var overlays: [NSWindow] = []
    private var views: [RegionView] = []
    private var completion: ((URL?) -> Void)?
    private var url: URL!
    private var sound = false
    private var previousApp: NSRunningApplication?   // where Esc returns to
    private var delay = 0                              // seconds between picking the area and capturing it
    private var countdownTimer: Timer?
    private var outline: NSWindow?

    var mouse = NSEvent.mouseLocation
    var antsPhase: CGFloat = 0
    private var antsTimer: Timer?
    var dragStart: CGPoint?
    var dragScreen: NSScreen?

    /// `fallback` runs instead when the screen can't be frozen (no image, or a blank one).
    static func start(to url: URL, sound: Bool, delay: Int = 0, completion: @escaping (URL?) -> Void, fallback: @escaping () -> Void) {
        current?.finish(nil)
        let capture = RegionCapture()
        capture.url = url
        capture.sound = sound
        capture.delay = delay
        capture.completion = completion
        let front = NSWorkspace.shared.frontmostApplication
        capture.previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        current = capture
        Task { @MainActor in
            // ScreenCaptureKit runs in SnapNow itself, so it has SnapNow's Screen Recording permission (a
            // screencapture child process came back empty on macOS 27); screencapture is the backup.
            let ok = await capture.freezeWithScreenCaptureKit() || capture.freeze()
            guard ok, current === capture else { if current === capture { current = nil }; fallback(); return }
            capture.snapshotWindows()
            capture.show()
        }
    }

    /// Each screen's display by ID, at its full pixel size.
    @MainActor private func freezeWithScreenCaptureKit() async -> Bool {
        frozen = []
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return false }
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { return false }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config),
                  !Self.isBlank(image) else { frozen = []; return false }
            frozen.append(Frozen(screen: screen, image: image))
        }
        return !frozen.isEmpty
    }

    /// An image with nothing in it (no permission, or a failed capture): every sampled pixel is black or clear.
    private static func isBlank(_ image: CGImage) -> Bool {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return stride(from: 0, to: px.count, by: 4).allSatisfy { px[$0] == 0 && px[$0 + 1] == 0 && px[$0 + 2] == 0 }
    }

    // MARK: Freezing

    /// Each screen by its exact frame (screencapture -R takes points from the main display's top-left), so
    /// every image belongs to a known screen; BMP because it's written in ~0.1 s.
    private func freeze() -> Bool {
        frozen = []
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let f = screen.frame
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snapnow-freeze-\(UUID().uuidString).bmp")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-t", "bmp", "-R\(Int(f.minX)),\(Int(mainHeight - f.maxY)),\(Int(f.width)),\(Int(f.height))", tmp.path]
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            guard let source = CGImageSourceCreateWithURL(tmp as CFURL, nil),
                  let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
                  let image = Self.opaque(raw),
                  abs(CGFloat(image.width) / f.width - CGFloat(image.height) / f.height) < 0.05 else { return false }
            guard !Self.isBlank(image) else { frozen = []; return false }
            frozen.append(Frozen(screen: screen, image: image))
        }
        return !frozen.isEmpty
    }

    /// The windows on screen now, front to back, for click-to-capture-a-window.
    private func snapshotWindows() {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        windows = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.width > 40, r.height > 40 else { return nil }
            return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
        }
    }

    /// The same pixels with the alpha channel ignored: screencapture's BMP can come with alpha 0 everywhere,
    /// which drew as a white (empty) screen and saved blank captures. No copy; only the format changes.
    private static func opaque(_ image: CGImage) -> CGImage? {
        let skip: CGImageAlphaInfo
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        case .premultipliedFirst, .first: skip = .noneSkipFirst
        default: skip = .noneSkipLast
        }
        let info = (image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | skip.rawValue
        guard let space = image.colorSpace, let provider = image.dataProvider else { return image }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
                       bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Overlays

    private func show() {
        for f in frozen {
            let window = KeyPanel(contentRect: f.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black   // never a white flash if the frozen screen were missing
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // The frozen screen is a layer (drawn by the GPU, once); the view above it draws only the overlay
            let size = CGRect(origin: .zero, size: f.screen.frame.size)
            let still = NSView(frame: size)
            still.wantsLayer = true
            still.layer?.contents = f.image
            still.layer?.contentsGravity = .resize
            let view = RegionView(frame: size, capture: self, frozen: f)
            still.addSubview(view)
            window.contentView = still
            window.setFrame(f.screen.frame, display: false)
            window.orderFrontRegardless()
            overlays.append(window)
            views.append(view)
        }
        // No NSApp.activate: the panels take the keys (Esc) without activating SnapNow, so an open editor stays
        // where it is and Esc leaves you in the app you were using
        let screen = screenUnderMouse()
        if let i = frozen.firstIndex(where: { $0.screen == screen }) {
            overlays[i].makeKey()
            overlays[i].makeFirstResponder(views[i])
        }
        NSCursor.crosshair.push()
        redraw()
        // Marching ants on the last area's outline: only that thin frame is redrawn, while the overlay is up
        if offered != nil {
            antsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                guard let self, let last = self.offered, !self.isDragging else { return }
                self.antsPhase = (self.antsPhase + 1) .truncatingRemainder(dividingBy: 10)
                for v in self.views { v.redrawOutline(last) }
            }
        }
    }

    func screenUnderMouse() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    func redraw() { views.forEach { $0.needsDisplay = true } }

    /// The drag rectangle (global), clamped to the screen it started on.
    var selection: CGRect? {
        guard let a = dragStart, let screen = dragScreen else { return nil }
        let r = CGRect(x: min(a.x, mouse.x), y: min(a.y, mouse.y), width: abs(a.x - mouse.x), height: abs(a.y - mouse.y))
        return r.intersection(screen.frame)
    }

    var isDragging: Bool {
        guard let r = selection else { return false }
        return r.width >= 4 || r.height >= 4
    }

    /// The front window under the cursor, cut to its screen.
    var hoveredWindow: CGRect? {
        guard let screen = screenUnderMouse() else { return nil }
        return windows.first { $0.contains(mouse) }.map { $0.intersection(screen.frame) }
    }

    /// What a click would capture right now (or the selection while dragging).
    /// The last area, offered again: shown outlined, and Enter or a click inside it captures it — unless the
    /// "Remember the last capture area" setting is off.
    lazy var offered: CGRect? = Prefs.onByDefault(Prefs.rememberArea) ? Self.lastArea : nil

    /// The cursor is over the offered last area (so a click takes it, not the window under it).
    var overOffered: Bool { offered.map { $0.contains(mouse) } ?? false }

    var focus: CGRect? { isDragging ? selection : overOffered ? offered : hoveredWindow }

    // MARK: Finishing

    func mouseUp() {
        guard let screen = dragScreen else { return }
        let rect = isDragging ? selection : overOffered ? offered.map { $0.intersection(screen.frame) } : (hoveredWindow ?? screen.frame)
        dragStart = nil
        guard let r = rect, r.width >= 1, r.height >= 1, let f = frozen.first(where: { $0.screen == screen }) else { finish(nil); return }
        take(r, from: f)
    }

    /// Captures the picked area: straight from the frozen screen, or after the countdown from the live one.
    private func take(_ r: CGRect, from f: Frozen) {
        guard delay > 0 else { finish(save(r, from: f) ? remember(r) : nil); return }
        closeOverlays()
        outline = Self.showOutline(r)
        var remaining = delay
        CountdownHUD.show(remaining, centeredOn: r)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            remaining -= 1
            if remaining > 0 { CountdownHUD.show(remaining); return }
            timer.invalidate()
            self.countdownTimer = nil
            CountdownHUD.hide()
            self.outline?.orderOut(nil)
            self.outline = nil
            // A moment for the countdown and outline to leave the screen, then the screen as it is now
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task { @MainActor in
                    guard RegionCapture.current === self, self.completion != nil else { return } // replaced or cancelled
                    let ok = await self.freezeWithScreenCaptureKit() || self.freeze()
                    guard RegionCapture.current === self, self.completion != nil else { return }
                    guard ok, let live = self.frozen.first(where: { $0.screen == f.screen }) else { self.finish(nil); return }
                    self.finish(self.save(r, from: live) ? self.remember(r) : nil)
                }
            }
        }
    }

    /// The picked area outlined on the live screen during the countdown: click-through, never captured.
    private static func showOutline(_ r: CGRect) -> NSWindow {
        let pad: CGFloat = 3
        let w = NSPanel(contentRect: r.insetBy(dx: -pad, dy: -pad), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .popUpMenu
        w.ignoresMouseEvents = true
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemBlue.cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = min(min(r.width, r.height) * 0.025, 28)   // match the rounded capture
        w.contentView = v
        w.orderFrontRegardless()
        return w
    }

    // MARK: The last area (Enter captures it again)

    private static let lastKey = "regionCapture.lastArea"

    /// The last captured area (global), if it's still on a screen.
    static var lastArea: CGRect? {
        guard let s = UserDefaults.standard.string(forKey: lastKey) else { return nil }
        let r = NSRectFromString(s)
        return r.width >= 1 && NSScreen.screens.contains(where: { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }) ? r : nil
    }

    private func remember(_ r: CGRect) -> URL {
        UserDefaults.standard.set(NSStringFromRect(r), forKey: Self.lastKey)
        return url
    }

    /// Enter: the same area as last time, cut to the screen it's on (only while the setting offers it).
    func captureLastArea() {
        guard let last = offered,
              let f = frozen.first(where: { $0.screen.frame.contains(CGPoint(x: last.midX, y: last.midY)) }) else { NSSound.beep(); return }
        let r = last.intersection(f.screen.frame)
        take(r, from: f)
    }

    /// Esc: closes the overlay and goes back to the app you were in (starting from the menu bar panel
    /// had made SnapNow active).
    func cancel() {
        let back = previousApp
        finish(nil)
        if NSApp.isActive { back?.activate() }
    }

    private func save(_ r: CGRect, from f: Frozen) -> Bool {
        let s = f.scale, sf = f.screen.frame
        let pixels = CGRect(x: (r.minX - sf.minX) * s, y: (sf.maxY - r.maxY) * s, width: r.width * s, height: r.height * s).integral
        guard let crop = f.image.cropping(to: pixels),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        // Retina captures carry their density, as screencapture's files do
        CGImageDestinationAddImage(dest, crop, [kCGImagePropertyDPIWidth: 72 * s, kCGImagePropertyDPIHeight: 72 * s] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Takes the frozen screen and crosshair away (once).
    private func closeOverlays() {
        guard !overlays.isEmpty else { return }
        antsTimer?.invalidate()
        antsTimer = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        views = []
        NSCursor.pop()
    }

    private func finish(_ result: URL?) {
        guard completion != nil else { return }
        closeOverlays()
        countdownTimer?.invalidate()
        countdownTimer = nil
        if outline != nil { CountdownHUD.hide() }
        outline?.orderOut(nil)
        outline = nil
        if result != nil && sound {
            NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play()
        }
        let done = completion
        completion = nil
        RegionCapture.current = nil
        done?(result)
    }
}

/// A non-activating panel that can still become key: it gets Esc while the app you were in stays active.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class RegionView: NSView {
    private unowned let capture: RegionCapture
    private let frozen: RegionCapture.Frozen
    private static let orange = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.13, alpha: 1)
    private static let loupe: CGFloat = 150, cells: CGFloat = 19   // magnifier size; pixels across it

    init(frame: CGRect, capture: RegionCapture, frozen: RegionCapture.Frozen) {
        self.capture = capture
        self.frozen = frozen
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    private var origin: CGPoint { frozen.screen.frame.origin }

    /// Just the outline's frame (global rect), for the marching ants.
    func redrawOutline(_ r: CGRect) {
        let l = local(r)
        guard l.insetBy(dx: -4, dy: -4).intersects(bounds) else { return }
        for edge in [CGRect(x: l.minX - 4, y: l.minY - 4, width: l.width + 8, height: 8),
                     CGRect(x: l.minX - 4, y: l.maxY - 4, width: l.width + 8, height: 8),
                     CGRect(x: l.minX - 4, y: l.minY - 4, width: 8, height: l.height + 8),
                     CGRect(x: l.maxX - 4, y: l.minY - 4, width: 8, height: l.height + 8)] {
            setNeedsDisplay(edge)
        }
    }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let focus = capture.focus.flatMap { r -> CGRect? in
            let l = local(r)
            return l.intersects(bounds) ? l : nil
        }

        // Rounded corners, matching the rounded capture, so the selection previews the final shape.
        func rad(_ r: CGRect) -> CGFloat { min(min(r.width, r.height) * 0.025, 28) }

        // Dim all but the focus and the offered last area (cleared out of the dim, so overlaps stay bright)
        let lit = [focus, capture.isDragging ? nil : capture.offered.map(local)].compactMap { $0 }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.fill(bounds)
        ctx.setBlendMode(.clear)
        for r in lit {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad(r), cornerHeight: rad(r), transform: nil))
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // A thin rounded outline around the active selection, showing the rounded shape while dragging
        if capture.isDragging, let f = focus {
            let sel = NSBezierPath(roundedRect: f, xRadius: rad(f), yRadius: rad(f))
            sel.lineWidth = 1.5
            Self.orange.setStroke()
            sel.stroke()
        }

        // The last area stays outlined (until a new drag), ready for Enter or a click
        if !capture.isDragging, let last = capture.offered.map(local), last.intersects(bounds) {
            let r = rad(last)
            let border = NSBezierPath(roundedRect: last.insetBy(dx: -1, dy: -1), xRadius: r, yRadius: r)
            border.lineWidth = 2
            NSColor.black.withAlphaComponent(0.55).setStroke()   // the gaps, so the ants read on any background
            border.stroke()
            border.setLineDash([6, 4], count: 2, phase: -capture.antsPhase)
            Self.orange.setStroke()
            border.stroke()
        }

        let m = CGPoint(x: capture.mouse.x - origin.x, y: capture.mouse.y - origin.y)
        guard bounds.contains(m) else { return }

        if !capture.isDragging {
            let lines = NSBezierPath()
            lines.move(to: CGPoint(x: bounds.minX, y: m.y)); lines.line(to: CGPoint(x: bounds.maxX, y: m.y))
            lines.move(to: CGPoint(x: m.x, y: bounds.minY)); lines.line(to: CGPoint(x: m.x, y: bounds.maxY))
            lines.lineWidth = 1
            lines.setLineDash([8, 6], count: 2, phase: 0)
            Self.orange.withAlphaComponent(0.9).setStroke()
            lines.stroke()
        }

        // The selection's size while dragging, otherwise where the cursor is (points from the screen's top-left)
        let size = capture.isDragging
            ? focus.map { "\(Int($0.width.rounded())) x \(Int($0.height.rounded()))" } ?? ""
            : "x = \(Int(m.x))   y = \(Int(bounds.height - m.y))"
        let loupeRect = drawLoupe(at: m, ctx: ctx, label: size)
        if capture.dragStart == nil {
            let last = capture.offered.map { "\nEnter or click inside the outline: last area (\(Int($0.width.rounded())) x \(Int($0.height.rounded())))" } ?? ""
            hint("Click, hold, and drag to select region" + last, beside: loupeRect)
        }
    }

    /// The magnifier below the cursor (above it near the bottom edge), with the size under it.
    private func drawLoupe(at m: CGPoint, ctx: CGContext, label: String) -> CGRect {
        let d = Self.loupe, gap: CGFloat = 36, labelH: CGFloat = 26
        var y = m.y - gap - d
        if y - labelH < 8 { y = m.y + gap }
        let x = min(max(m.x - d / 2, 8), bounds.maxX - d - 8)
        let circle = CGRect(x: x, y: y, width: d, height: d)

        // Card behind the circle and label, as in Snagit
        // As wide as the label needs (row/column can be wider than the circle)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let text = label as NSString
        let ts = text.size(withAttributes: attributes)
        let cardW = max(d + 12, ts.width + 24)
        let card = CGRect(x: circle.midX - cardW / 2, y: circle.minY - labelH, width: cardW, height: d + labelH + 6)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowColor = NSColor.black.withAlphaComponent(0.4); shadow.set()
        NSColor(white: 0.12, alpha: 0.92).setFill()
        cardPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Pixels around the cursor, magnified without smoothing
        let s = frozen.scale, cells = Self.cells
        let px = CGRect(x: (m.x * s).rounded(.down) - (cells - 1) / 2, y: ((bounds.height - m.y) * s).rounded(.down) - (cells - 1) / 2,
                        width: cells, height: cells)
        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        NSColor.white.setFill()
        circle.fill()
        if let crop = frozen.image.cropping(to: px.intersection(CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))) {
            ctx.interpolationQuality = .none
            let cell = d / cells
            // A crop clipped at the screen's edge keeps its place in the grid
            let dx = (max(px.minX, 0) - px.minX) * cell, dyTop = (max(px.minY, 0) - px.minY) * cell
            let w = CGFloat(crop.width) * cell, h = CGFloat(crop.height) * cell
            ctx.draw(crop, in: CGRect(x: circle.minX + dx, y: circle.maxY - dyTop - h, width: w, height: h))
        }
        // Pixel grid and the centre cross
        let cell = d / cells
        let grid = NSBezierPath()
        for i in 0...Int(cells) {
            let o = CGFloat(i) * cell
            grid.move(to: CGPoint(x: circle.minX + o, y: circle.minY)); grid.line(to: CGPoint(x: circle.minX + o, y: circle.maxY))
            grid.move(to: CGPoint(x: circle.minX, y: circle.minY + o)); grid.line(to: CGPoint(x: circle.maxX, y: circle.minY + o))
        }
        grid.lineWidth = 0.5
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        grid.stroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: circle.minX, y: circle.midY)); cross.line(to: CGPoint(x: circle.maxX, y: circle.midY))
        cross.move(to: CGPoint(x: circle.midX, y: circle.minY)); cross.line(to: CGPoint(x: circle.midX, y: circle.maxY))
        cross.lineWidth = 2
        Self.orange.setStroke()
        cross.stroke()
        ctx.restoreGState()

        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 3
        NSColor.white.setStroke()
        ring.stroke()

        text.draw(at: CGPoint(x: circle.midX - ts.width / 2, y: card.minY + (labelH - ts.height) / 2 + 1), withAttributes: attributes)
        return card
    }

    private func hint(_ text: String, beside card: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white]
        let ts = (text as NSString).size(withAttributes: attributes)
        var box = CGRect(x: card.minX - ts.width - 40, y: card.maxY - ts.height - 30, width: ts.width + 28, height: ts.height + 14)
        if box.minX < 8 { box.origin.x = card.maxX + 12 }
        let pill = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor(white: 0.12, alpha: 0.88).setFill()
        pill.fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attributes)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseMoved(with event: NSEvent) {
        capture.mouse = NSEvent.mouseLocation
        capture.redraw()
    }

    override func mouseDown(with event: NSEvent) {
        capture.mouse = NSEvent.mouseLocation
        capture.dragStart = capture.mouse
        capture.dragScreen = capture.screenUnderMouse()
        capture.redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        capture.mouse = NSEvent.mouseLocation
        capture.redraw()
    }

    override func mouseUp(with event: NSEvent) {
        capture.mouse = NSEvent.mouseLocation
        capture.mouseUp()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: capture.cancel()                       // Esc
        case 36, 76: capture.captureLastArea()          // Return, keypad Enter
        default: super.keyDown(with: event)
        }
    }
}

/// Burns the capture's date & time into the bottom-right corner of the saved PNG (toggle: Prefs.stampTime).
/// Format: yyyy-MM-dd HH:mm, local time; a translucent pill keeps it legible on any background.
enum CaptureStamp {
    static func apply(to url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72   // Retina captures carry 144
        let scale = max(1, dpi / 72)
        guard let stamped = draw(on: image, scale: scale),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, stamped, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        CGImageDestinationFinalize(dest)
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
        let fontSize = max(11 * scale, CGFloat(h) * 0.013)
        // Monospaced digits read cleanly as a timestamp and keep an even width.
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let ts = text.size(withAttributes: [.font: font])
        let margin = min(CGFloat(w), CGFloat(h)) * 0.02   // nestle into the (rounded) bottom-right corner
        let region = CGRect(x: CGFloat(w) - ts.width - margin, y: CGFloat(h) - ts.height - margin, width: ts.width, height: ts.height)
        let onLight = averageLuminance(of: image, in: region) > 0.6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (onLight ? NSColor.black : NSColor.white).withAlphaComponent(0.6),
        ]
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        text.draw(at: CGPoint(x: CGFloat(w) - ts.width - margin, y: margin), withAttributes: attrs)
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
    static func apply(to url: URL) {
        let d = UserDefaults.standard
        let text = (d.string(forKey: Prefs.wmText) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let imgPath = d.string(forKey: Prefs.wmImage) ?? ""
        let wm = imgPath.isEmpty ? nil : NSImage(contentsOfFile: imgPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard !text.isEmpty || wm != nil else { return }
        let placement = d.string(forKey: Prefs.wmPlacement) ?? "bottomRight"
        let opacity = max(0.05, min(1, CGFloat(Prefs.wmOpacityValue) / 100))
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let scale = max(1, dpi / 72)
        guard let out = render(base, scale: scale, text: text, wm: wm, placement: placement, opacity: opacity) else { return }
        // Atomic: write a temp file, then replace — a failed render/encode never loses the capture.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".wm-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
    static func apply(to url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let w = base.width, h = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let radius = min(CGFloat(w), CGFloat(h)) * 0.025
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".rc-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
