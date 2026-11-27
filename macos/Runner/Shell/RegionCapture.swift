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
    private var windowApps: [String] = []     // the owning app's bundle id (or name) per window, same order

    /// Apps whose windows get the scrolling-capture button: browsers and terminals ("for now just browsers and
    /// terminals are fine for scroll feature", 2026-11-04). Matched on the bundle id, else the owner name.
    private static let scrollApps: [String] = [
        "com.google.chrome", "com.apple.safari", "org.mozilla.firefox", "company.thebrowser.browser", "com.microsoft.edgemac",
        "com.brave.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi", "org.chromium.chromium",
        "com.mitchellh.ghostty", "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "net.kovidgoyal.kitty",
        "org.alacritty", "co.zeit.hyper",
    ]
    private static let scrollAppWords = ["chrome", "safari", "firefox", "arc", "edge", "brave", "opera", "vivaldi", "chromium",
                                         "ghostty", "terminal", "iterm", "warp", "kitty", "alacritty", "hyper"]
    static func isScrollApp(_ id: String) -> Bool {
        let lower = id.lowercased()
        return scrollApps.contains(lower) || scrollAppWords.contains { lower == $0 || lower.hasSuffix(".\($0)") || lower.contains($0) }
    }

    /// The app owning the window under the cursor, when it is a browser or a terminal.
    var hoveredScrollApp: String? {
        guard let i = windows.firstIndex(where: { $0.contains(mouse) }), i < windowApps.count, Self.isScrollApp(windowApps[i]) else { return nil }
        return windowApps[i]
    }
    private var overlays: [NSWindow] = []
    private var views: [RegionView] = []
    private var completion: ((URL?) -> Void)?
    private var onPicked: ((CGRect, NSScreen) -> Void)?   // pick mode: hand back the area instead of saving it
    /// Set by the shell: runs a scrolling capture of the area when the user presses S in the picker.
    static var scrollHandler: ((CGRect, NSScreen) -> Void)?
    /// Whether what's under the cursor scrolls (an AXScrollArea up the accessibility tree), by window, so the
    /// picker can offer the scrolling capture. Needs Accessibility; without it nothing is detected.
    private var scrollableCache: [String: Bool] = [:]
    private var probedCells: Set<String> = []
    var scrollsUnderCursor: Bool {
        guard onPicked == nil, Self.scrollHandler != nil, !isDragging, let w = focus else { return false }
        let key = NSStringFromRect(w)
        if scrollableCache[key] == true { return true }
        // Probe the window's middle once, and the cursor's neighbourhood (80-pt cells) as it moves: a toolbar or
        // margin under the first hover must not settle it for the whole window
        let cell = "\(key)|\(Int(mouse.x / 80)),\(Int(mouse.y / 80))"
        guard !probedCells.contains(cell) else { return false }
        probedCells.insert(cell)
        let found = (scrollableCache[key] == nil && Self.scrollArea(at: CGPoint(x: w.midX, y: w.midY))) || Self.scrollArea(at: mouse)
        scrollableCache[key] = found
        return found
    }

    /// Whether the picker shows the scroll arrow: on a hovered browser or terminal window. Telling scrollable
    /// windows apart through Accessibility proved unreliable (Chrome pages, YouTube, feeds), and an arrow on every
    /// window read as the picker marking things on its own, so it is limited to the apps where scrolling capture
    /// is the point. S still works on any window.
    var offersScroll: Bool {
        onPicked == nil && Self.scrollHandler != nil && !isDragging && !overOffered && hoveredScrollApp != nil
    }

    /// Whether an AXScrollArea (or a web area) encloses the point (global Cocoa coordinates).
    private static func scrollArea(at p: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(mainHeight - p.y), &element) == .success,
              var e = element else { return false }
        for _ in 0..<24 {
            var role: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role) == .success,
               let r = role as? String, r == kAXScrollAreaRole || r == "AXWebArea" || r == "AXList" || r == kAXTableRole || r == kAXOutlineRole { return true }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success, let next = parent else { return false }
            e = next as! AXUIElement
        }
        return false
    }

    /// S: a scrolling capture of what a click would take (the hovered window, or the last area).
    func scrollPicked() {
        guard let handler = Self.scrollHandler, onPicked == nil, let screen = screenUnderMouse(),
              let r = focus?.intersection(screen.frame), r.width >= 40, r.height >= 60 else { NSSound.beep(); return }
        UserDefaults.standard.set(NSStringFromRect(r), forKey: Self.lastKey)
        finish(nil)
        handler(r, screen)
    }
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
    var lastDrag: CGPoint?   // where the last mouseDragged put the cursor (the true end of a drag; see mouseUp)

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

    /// The picker alone: the chosen area (global Cocoa coordinates) and its screen go to `completion`, nothing is
    /// saved; Esc gives (nil, nil). For captures that then do their own shooting (scrolling capture).
    static func pick(completion: @escaping (CGRect?, NSScreen?) -> Void, fallback: @escaping () -> Void) {
        current?.finish(nil)
        let capture = RegionCapture()
        capture.completion = { _ in completion(nil, nil) }   // only ever reached with nil: Esc or a failure
        capture.onPicked = { r, screen in completion(r, screen) }
        let front = NSWorkspace.shared.frontmostApplication
        capture.previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        current = capture
        Task { @MainActor in
            let ok = await capture.freezeWithScreenCaptureKit() || capture.freeze()
            guard ok, current === capture else { if current === capture { current = nil }; fallback(); return }
            capture.snapshotWindows()
            capture.show()
        }
    }

    /// Test control: `r` (global Cocoa points) saved to `url` without the picker, from the same frozen screen a click uses.
    static func captureArea(_ r: CGRect, to url: URL, completion: @escaping (URL?) -> Void) {
        let capture = RegionCapture()
        capture.url = url
        Task { @MainActor in
            guard await capture.freezeWithScreenCaptureKit(),
                  let f = capture.frozen.first(where: { $0.screen.frame.contains(CGPoint(x: r.midX, y: r.midY)) }) else { completion(nil); return }
            let saving = CFAbsoluteTimeGetCurrent()
            let saved = capture.save(r.intersection(f.screen.frame), from: f)
            Self.timings["save"] = (CFAbsoluteTimeGetCurrent() - saving) * 1000
            completion(saved ? url : nil)
        }
    }

    /// How long the last freeze took, step by step, in milliseconds (the test control's status.json "lastFreeze").
    static var timings: [String: Double] = [:]

    /// Each screen's display by ID, at its full pixel size.
    @MainActor private func freezeWithScreenCaptureKit() async -> Bool {
        frozen = []
        let began = CFAbsoluteTimeGetCurrent()
        var timings: [String: Double] = ["screens": Double(NSScreen.screens.count)]
        defer { Self.timings = timings; Self.timings["total"] = (CFAbsoluteTimeGetCurrent() - began) * 1000 }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return false }
        timings["content"] = (CFAbsoluteTimeGetCurrent() - began) * 1000
        let hidden = Recorder.shared.overlayWindowIDs           // a screen recording's pill and border are not captured
        let recorderWindows = content.windows.filter { hidden.contains($0.windowID) }
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { return false }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let shot = CFAbsoluteTimeGetCurrent()
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: recorderWindows), configuration: config),
                  !Self.isBlank(image) else { frozen = []; return false }
            timings["capture.\(frozen.count)"] = (CFAbsoluteTimeGetCurrent() - shot) * 1000
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
        let restoreOverlays = Recorder.shared.hideOverlaysForStill()
        defer { restoreOverlays() }
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
        var apps: [String] = []
        windows = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.width > 40, r.height > 40 else { return nil }
            apps.append(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? (w[kCGWindowOwnerName as String] as? String) ?? "")
            return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
        }
        windowApps = apps
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
        // Marching ants on the last area's outline and the breathing scroll arrow: only those small parts are
        // redrawn, while the overlay is up
        antsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, !self.isDragging else { return }
            self.antsPhase = (self.antsPhase + 1) .truncatingRemainder(dividingBy: 10)
            for v in self.views {
                if let last = self.offered { v.redrawOutline(last) }
                v.redrawScrollButton()
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
    lazy var offered: CGRect? = Prefs.offByDefault(Prefs.rememberArea) ? Self.lastArea : nil

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
        if let picked = onPicked {
            UserDefaults.standard.set(NSStringFromRect(r), forKey: Self.lastKey)
            closeOverlays()
            completion = nil
            onPicked = nil
            RegionCapture.current = nil
            picked(r, f.screen)
            return
        }
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
    static func showOutline(_ r: CGRect) -> NSWindow {
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
    private var scrollButton: CGRect?   // "Capture everything that scrolls", on the hovered browser/terminal window (local coords)
    private var scrollButtonPressed = false
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
    func redrawScrollButton() {
        if let r = scrollButton { setNeedsDisplay(r.insetBy(dx: -12, dy: -12)) }
    }

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

        // The scrolling capture, offered the way Snagit does it: a pulsing arrow with "Capture everything scrollable"
        // on the hovered window, but only for browsers and terminals (`offersScroll`): on every window it read as
        // the picker having picked something on its own (2026-11-04).
        scrollButton = nil
        if !capture.isDragging, let f = focus, capture.offersScroll {
            let pulse = 1 + 0.06 * sin(Double(capture.antsPhase) / 10 * .pi)   // breathes with the ants timer
            let radius = 22 * pulse
            let centre = CGPoint(x: f.midX, y: max(f.minY + 64, min(f.maxY - 64, f.minY + 64)))
            let text = "Capture everything scrollable"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
            let ts = (text as NSString).size(withAttributes: attributes)
            let label = CGRect(x: centre.x + radius + 10, y: centre.y - (ts.height + 12) / 2, width: ts.width + 24, height: ts.height + 12)
            let circle = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            let over = circle.contains(m) || label.contains(m)
            // Halo, then the orange disc with a down arrow
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: circle.insetBy(dx: -5, dy: -5)).fill()
            (over ? NSColor(calibratedRed: 1, green: 0.72, blue: 0.2, alpha: 1) : Self.orange).setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: circle)
            ring.lineWidth = 2
            ring.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: centre.x, y: centre.y + radius * 0.45))
            arrow.line(to: CGPoint(x: centre.x, y: centre.y - radius * 0.4))
            arrow.move(to: CGPoint(x: centre.x - radius * 0.38, y: centre.y - radius * 0.02))
            arrow.line(to: CGPoint(x: centre.x, y: centre.y - radius * 0.4))
            arrow.line(to: CGPoint(x: centre.x + radius * 0.38, y: centre.y - radius * 0.02))
            arrow.lineWidth = 3.5
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            // The label beside it
            let pill = NSBezierPath(roundedRect: label, xRadius: label.height / 2, yRadius: label.height / 2)
            NSColor(white: 0.1, alpha: over ? 0.95 : 0.85).setFill()
            pill.fill()
            (text as NSString).draw(at: CGPoint(x: label.minX + 12, y: label.minY + 6), withAttributes: attributes)
            scrollButton = circle.union(label)
        }

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
            let scroll = capture.offersScroll ? "\n↕ S or the button captures all of it" : ""
            hint("Click, hold, and drag to select region" + last + scroll, beside: loupeRect)
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
        if let b = scrollButton, b.contains(local(CGRect(origin: capture.mouse, size: .zero)).origin) {
            scrollButtonPressed = true   // a click on the button, not the start of a drag
            return
        }
        capture.dragStart = capture.mouse
        capture.lastDrag = nil
        capture.dragScreen = capture.screenUnderMouse()
        capture.redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        if scrollButtonPressed { return }
        capture.mouse = NSEvent.mouseLocation
        capture.lastDrag = capture.mouse
        capture.redraw()
    }

    override func mouseUp(with event: NSEvent) {
        let here = NSEvent.mouseLocation
        if scrollButtonPressed {
            scrollButtonPressed = false
            capture.mouse = here
            if let b = scrollButton, b.contains(local(CGRect(origin: here, size: .zero)).origin) {
                capture.scrollPicked()   // finishes the picker: `capture` (unowned) is gone after this, so nothing more here
            } else {
                capture.redraw()
            }
            return
        }
        // Releasing inside the auto-hiding Dock's strip: macOS reports the release at the Dock's top edge
        // (y ≈ 77), far from where the drag actually was, with no drag events in between — so the box bottom
        // would snap there and cut whatever sat in the Dock. A genuine release never jumps that far from the
        // last drag, so a big discontinuity means interference: the last drag position is where you let go.
        if let last = capture.lastDrag, hypot(here.x - last.x, here.y - last.y) > 8 {
            capture.mouse = last
        } else {
            capture.mouse = here
        }
        capture.mouseUp()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: capture.cancel()                       // Esc
        case 36, 76: capture.captureLastArea()          // Return, keypad Enter
        case 1: capture.scrollPicked()                  // S: scrolling capture of the hovered window / last area
        default: super.keyDown(with: event)
        }
    }
}
