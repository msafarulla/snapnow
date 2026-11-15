import AppKit
import ApplicationServices
import QuartzCore

/// Matrix rain over the display you are working on: its shortcut (Settings › Shortcuts, default ⌃⌥⇧⌘M, a system hotkey; see MatrixTrigger)
/// or the menu's Matrix Rain turns cmatrix's rain on; the shortcut again or Escape turns it off. The same effect and timing as my browser-automation rain
/// (MatrixColumns, a port of cmatrix): every second column, a white head, a green tail, 40 ms a frame, over a light black
/// wash so the screen stays visible. One borderless, click-through window on one display (the one draw mode would open on:
/// LiveDraw.targetScreen(); it stays there until the rain is turned off) above everything (screen-saver
/// level, every Space and over full-screen apps), never in a capture (sharingType none) but in a screen recording, never taking
/// focus. A virtual display is the exception: its window is always capturable (see VirtualDisplay), so the rain is in a capture of it. Each cell is a layer showing a cached glyph image, and a frame only touches the cells that changed. Off while
/// the screen is locked or asleep; rebuilt when displays change (same display while it exists); never together with draw mode (opening draw mode stops
/// it, and it does not start while draw mode is up).
final class MatrixRain {
    static let shared = MatrixRain()
    private(set) var running = false
    private var paused = false
    private var screens: [RainScreen] = []     // one at most: the display chosen when the rain was turned on
    private var timer: Timer?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    static let frame: TimeInterval = 0.04          // cmatrix -u 4: napms(update * 10)
    /// The shortcut the global monitor answers (a bare key or ⇧+key, only when not typing); nil when the shortcut is a system
    /// hotkey (HotKeyCenter answers it), cleared, switched off, or paused by the menu's hotkey mode. Set by Shell.registerHotKeys
    /// whenever the shortcuts change, so a new one works at once and the old one is gone.
    var monitorShortcut: Shortcut?
    /// Out of captures and screenshots, but in a screen recording while one runs (it is part of what you see).
    static var sharing: NSWindow.SharingType { Recorder.shared.isRecording ? .readOnly : .none }
    /// The sharing type of the rain window on one display. A virtual display has no panel: its picture exists only by
    /// being captured (by whatever app streams it to a real screen), so a window left out of captures would never be
    /// seen there. Its rain window is therefore always capturable. Accepted consequence: a SnapNow capture or a
    /// screenshot of a virtual display includes the rain while it runs. Physical displays: `sharing`, as before.
    static func sharing(virtual: Bool) -> NSWindow.SharingType { virtual ? .readOnly : sharing }
    /// Test control status.json "matrixScreens": the rain window's display (one entry while it runs), its display id, whether it is virtual, the sharing type set
    /// on the window and the one the window server reports for it.
    var screenStatus: [[String: Any]] {
        func name(_ t: NSWindow.SharingType) -> String { t == .none ? "none" : t == .readOnly ? "readOnly" : "other(\(t.rawValue))" }
        return screens.map { s in
            let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(s.window.windowNumber)) as? [[String: Any]])?.first
            let server = (info?[kCGWindowSharingState as String] as? UInt).flatMap { NSWindow.SharingType(rawValue: $0) }
            return ["display": s.displayName, "displayID": Int(s.displayID), "virtual": s.virtual, "sharing": name(s.window.sharingType),
                    "serverSharing": server.map(name) ?? "unknown"]
        }
    }
    static let washAlpha: CGFloat = 0.5            // "background can slightly become black" (as the browser rain)

    /// Global and local key monitors (the same Accessibility / Input Monitoring permissions as draw mode's double-tap).
    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.key(e, local: false) }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.key(e, local: true) ?? e }) { monitors.append(m) }
        let ws = NSWorkspace.shared.notificationCenter, dist = DistributedNotificationCenter.default()
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ f: @escaping () -> Void) {
            observers.append((c, c.addObserver(forName: name, object: nil, queue: .main) { _ in f() }))
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.pause(true) }
        on(ws, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.pause(false) }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.pause(true) }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.pause(false) }
        on(dist, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.pause(true) }
        on(dist, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.pause(false) }
        on(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, self.running else { return }
            self.buildScreens()
        }
        on(NotificationCenter.default, Recorder.recordingChanged) { [weak self] in
            self?.screens.forEach { $0.window.sharingType = MatrixRain.sharing(virtual: $0.virtual) }
        }
    }

    /// The recorded bare key or ⇧+key (not typing) toggles; Escape stops. A global monitor cannot swallow the key, so it still
    /// reaches the app: acceptable only because it never fires while a text field (or a terminal) has the focus.
    private func key(_ e: NSEvent, local: Bool) -> NSEvent? {
        if e.keyCode == 53, running {                             // Escape
            stop()
            return local ? nil : e                                // in SnapNow's own windows it only stops the rain
        }
        guard let want = monitorShortcut, !e.isARepeat, Shortcut.of(e) == want else { return e }
        // SnapNow's own windows: Flutter's text fields are not reliably visible to Accessibility, so a plain key there types
        if local { return e }
        if TypingGuard.isTyping(MatrixRain.focusInfo()) { return e }
        toggle()
        return e
    }

    func toggle() { running ? stop() : begin() }

    /// One line in SnapNow's trace log (~/Library/Caches/SnapLite/trace.log): how the shortcut was set up, for support.
    static func note(_ m: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SnapLite/trace.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write("\(Date()) matrix-rain \(m)\n".data(using: .utf8)!); try? h.close() }
    }

    func begin() {
        guard !running, !LiveDraw.shared.active else { return }
        running = true
        paused = MatrixRain.screenLocked()           // started (from the menu) while the screen is locked: wait for the unlock
        buildScreens()
        if !paused { startTimer() }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate(); timer = nil
        for s in screens { s.window.orderOut(nil); s.window.close() }
        screens = []
    }

    static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func pause(_ on: Bool) {
        paused = on
        guard running else { return }
        if on { timer?.invalidate(); timer = nil } else if timer == nil { startTimer() }
    }

    private func startTimer() {
        let t = Timer(timeInterval: MatrixRain.frame, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.004
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The rain's one window. Turned on: the display you are working on (draw mode's choice). Displays changed while it
    /// runs: the same display if it is still there, else the one you are working on now. It never follows the pointer.
    private func buildScreens() {
        let kept = screens.first?.displayID
        for s in screens { s.window.orderOut(nil); s.window.close() }
        let screen = kept.flatMap { id in NSScreen.screens.first { VirtualDisplay.id(of: $0) == id } } ?? LiveDraw.targetScreen()
        screens = screen.map { [RainScreen(screen: $0)] } ?? []
    }

    private func tick() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in screens { s.tick() }
        CATransaction.commit()
    }

    // ---- What has the keyboard focus (Accessibility) ----

    /// The focused element of the frontmost app, as TypingGuard needs it; nil when Accessibility is not allowed or the
    /// focused app cannot be read. Each call waits at most ~0.15 s for an app that does not answer.
    static func focusInfo() -> FocusInfo? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appValue = appRef, CFGetTypeID(appValue) == AXUIElementGetTypeID() else { return nil }
        let app = appValue as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focusRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusRef)
        if err == .noValue { return FocusInfo(bundleID: bundle, role: TypingGuard.noFocus) }
        guard err == .success, let focusValue = focusRef, CFGetTypeID(focusValue) == AXUIElementGetTypeID() else {
            return FocusInfo(bundleID: bundle, role: nil)
        }
        let el = focusValue as! AXUIElement
        func string(_ attr: String) -> String? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v as? String : nil
        }
        func exists(_ attr: String) -> Bool {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success && v != nil
        }
        var settable = DarwinBoolean(false)
        let canSet = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        return FocusInfo(bundleID: bundle, role: string(kAXRoleAttribute), subrole: string(kAXSubroleAttribute),
                         valueSettable: canSet, hasSelectedTextRange: exists(kAXSelectedTextRangeAttribute),
                         editableAncestor: exists("AXEditableAncestor"))
    }
}

/// Tells a virtual display (made by software, no panel: seen only through an app that captures and streams it) from a
/// physical one. There is no public API for this, so the display's info dictionary is read through a CoreDisplay
/// function looked up at run time (no link-time dependency): when the function or the flag is missing the display
/// counts as physical, which is the behaviour before this existed. A built-in display is never virtual.
enum VirtualDisplay {
    private typealias InfoFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let info: InfoFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: InfoFunction.self)
    }()

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        guard id != 0, CGDisplayIsBuiltin(id) == 0, let dict = info?(id)?.takeRetainedValue() as? [String: Any] else { return false }
        return (dict["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue ?? false
    }

    static func id(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func isVirtual(_ screen: NSScreen) -> Bool { isVirtual(id(of: screen)) }
}

/// One display's rain: its window, its columns and a layer per used cell.
private final class RainScreen {
    let window: NSWindow
    let virtual: Bool                      // a virtual display: the window stays capturable (MatrixRain.sharing(virtual:))
    let displayName: String
    let displayID: CGDirectDisplayID
    private var engine: MatrixColumns
    private let glyphs: RainGlyphs
    private var cells: [CALayer] = []      // row-major: rows 0..<lines, used (even) columns only
    private var shown: [Int]               // what each cell layer shows: 0 nothing, else code * 2 + head
    private let usedCols: Int

    init(screen: NSScreen) {
        glyphs = RainGlyphs.shared(scale: screen.backingScaleFactor)
        virtual = VirtualDisplay.isVirtual(screen)
        displayName = screen.localizedName
        displayID = VirtualDisplay.id(of: screen)
        let size = screen.frame.size, cw = glyphs.cell.width, ch = glyphs.cell.height
        let cols = max(1, Int(size.width / cw)), lines = max(1, Int(size.height / ch))
        engine = MatrixColumns(lines: lines, cols: cols)
        usedCols = (cols + 1) / 2

        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                 // every click and scroll goes to the apps underneath
        w.level = .screenSaver                      // above normal windows, the menu bar, the Dock and full-screen apps
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // never in a SnapNow capture or a screenshot; in a screen recording, yes; on a virtual display always capturable
        w.sharingType = MatrixRain.sharing(virtual: virtual)
        w.animationBehavior = .none
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        let root = CALayer()
        root.frame = view.bounds
        root.backgroundColor = NSColor.black.withAlphaComponent(MatrixRain.washAlpha).cgColor
        view.layer = root
        w.contentView = view
        w.setFrame(screen.frame, display: false)
        window = w

        let m = RainGlyphs.margin
        shown = Array(repeating: 0, count: lines * usedCols)
        cells.reserveCapacity(shown.count)
        for row in 0..<lines {
            for k in 0..<usedCols {
                let l = CALayer()
                l.contentsScale = screen.backingScaleFactor
                l.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
                // screen row 0 at the top; layer coordinates start at the bottom-left
                l.frame = CGRect(x: CGFloat(k * 2) * cw - m, y: size.height - CGFloat(row + 1) * ch - m, width: cw + 2 * m, height: ch + 2 * m)
                l.isHidden = true
                root.addSublayer(l)
                cells.append(l)
            }
        }
        w.orderFrontRegardless()                    // shown without activating SnapNow or changing the frontmost app
    }

    func tick() {
        engine.step()
        for row in 0..<engine.lines {
            for k in 0..<usedCols {
                let idx = row * usedCols + k
                let key = engine.cell(row: row, col: k * 2).map { $0.code * 2 + ($0.head ? 1 : 0) } ?? 0
                guard key != shown[idx] else { continue }   // only the cells that changed
                shown[idx] = key
                let layer = cells[idx]
                if key == 0 { layer.isHidden = true; continue }
                layer.contents = glyphs.image(code: key / 2, head: key % 2 == 1)
                layer.isHidden = false
            }
        }
    }
}

/// The 90 characters in white (head) and neon green (tail), Menlo 15 with a thin dark outline so they read on light
/// screens too, rendered once per display scale.
private final class RainGlyphs {
    static let margin: CGFloat = 2
    private static var byScale: [CGFloat: RainGlyphs] = [:]
    static func shared(scale: CGFloat) -> RainGlyphs {
        if let g = byScale[scale] { return g }
        let g = RainGlyphs(scale: scale)
        byScale[scale] = g
        return g
    }

    let cell: CGSize
    private let scale: CGFloat
    private let font: NSFont
    private var images: [Int: CGImage] = [:]
    private static let tail = NSColor(srgbRed: 0, green: 1, blue: 0x41 / 255.0, alpha: 1)   // #00ff41

    private init(scale: CGFloat) {
        self.scale = scale
        font = NSFont(name: "Menlo", size: 15) ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let w = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        cell = CGSize(width: w, height: (15 * 1.15).rounded())
    }

    func image(code: Int, head: Bool) -> CGImage? {
        let key = code * 2 + (head ? 1 : 0)
        if let i = images[key] { return i }
        let m = RainGlyphs.margin
        let pw = Int(ceil((cell.width + 2 * m) * scale)), ph = Int(ceil((cell.height + 2 * m) * scale))
        guard let scalar = UnicodeScalar(code),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let s = String(Character(scalar)) as NSString
        let at = NSPoint(x: m, y: m)
        // the outline first (stroke only: a positive stroke width, in percent of the font size; ~3 px as the browser rain)
        s.draw(at: at, withAttributes: [.font: font, .strokeColor: NSColor.black.withAlphaComponent(0.85), .strokeWidth: 20])
        s.draw(at: at, withAttributes: [.font: font, .foregroundColor: head ? NSColor.white : RainGlyphs.tail])
        NSGraphicsContext.restoreGraphicsState()
        let img = ctx.makeImage()
        images[key] = img
        return img
    }
}
