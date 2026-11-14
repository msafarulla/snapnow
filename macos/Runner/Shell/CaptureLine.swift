import AppKit
import QuickLookThumbnailing

/// The capture line: rest the pointer in the middle of the menu bar and a strip slides down from the top of that screen
/// with the newest captures hanging on a cord. Drag one into any app (a copy goes there, the capture stays), click to copy
/// it, double-click to open it in the editor, right-click for the rest. Move away and the strip goes back up. A new capture
/// shows the line for a moment (Settings › Capture line). The captures are the files in the captures folder, newest first;
/// "Take Off the Line" only hides one here (the file stays in the Library).
final class CaptureLine: NSObject {
    static let shared = CaptureLine()

    static let enabledKey = "captureLine.enabled"                 // on by default
    static let showOnCaptureKey = "captureLine.showOnCapture"     // on by default
    private static let hiddenKey = "captureLine.hidden"           // file names taken off the line on this Mac
    private static let kinds: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mp4", "mov", "pdf"]

    static var enabled: Bool { Prefs.onByDefault(enabledKey) }
    static var showOnCapture: Bool { Prefs.onByDefault(showOnCaptureKey) }

    private var panel: NSPanel?
    private var lineView: CaptureLineView?
    private var pollTimer: Timer?
    private var folderSource: DispatchSourceFileSystemObject?
    private var restingSince: Date?            // the pointer came to rest in the menu bar's middle
    private var awaySince: Date?               // the pointer left the strip
    private var holdUntil = Date.distantPast   // shown for a new capture: stays at least this long
    private var newestSeen: Date = .distantPast
    private(set) var isShown = false
    var dragging = false
    var menuOpen = false

    func start() {
        newestSeen = files(limit: 1).first.map(modified) ?? Date()
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        watchFolder()
    }

    // MARK: - Files

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The newest captures that are not taken off the line.
    private func files(limit: Int) -> [URL] {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        let all = (try? FileManager.default.contentsOfDirectory(at: Capture.folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: .skipsHiddenFiles)) ?? []
        return all
            .filter { Self.kinds.contains($0.pathExtension.lowercased()) && !hidden.contains($0.lastPathComponent) }
            .map { ($0, modified($0)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private func watchFolder() {
        let fd = open(Capture.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.folderChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderSource = source
    }

    private var folderWork: DispatchWorkItem?
    private func folderChanged() {
        folderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, Self.enabled else { return }
            let newest = self.files(limit: 1).first.map(self.modified) ?? .distantPast
            let isNew = newest > self.newestSeen
            self.newestSeen = max(newest, self.newestSeen)
            if self.isShown { self.reload() }
            // a new capture: the line comes down for a moment, unless draw mode has the screen
            if isNew, Self.showOnCapture, !LiveDraw.shared.busy {
                self.holdUntil = Date().addingTimeInterval(3)
                self.show(on: self.screenUnderPointer() ?? NSScreen.main)
            }
        }
        folderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)   // the file is written, renamed, stamped: one look
    }

    // MARK: - Showing and hiding

    private func screenUnderPointer() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(p) }
    }

    /// Every 0.15 s: the pointer resting in the middle third of the menu bar brings the line down on that screen; away from
    /// the strip for a moment puts it back.
    private func tick() {
        guard Self.enabled else {
            if isShown { hide() }
            return
        }
        let p = NSEvent.mouseLocation
        guard let screen = screenUnderPointer() else { return }
        if !isShown {
            let bar = max(6, screen.frame.maxY - screen.visibleFrame.maxY)
            let inBar = p.y >= screen.frame.maxY - bar
            let third = screen.frame.width / 3
            let inMiddle = p.x >= screen.frame.minX + third && p.x <= screen.frame.maxX - third
            if inBar && inMiddle && NSEvent.pressedMouseButtons == 0 && !LiveDraw.shared.busy {
                if restingSince == nil { restingSince = Date() }
                if Date().timeIntervalSince(restingSince!) >= 0.35 { show(on: screen) }
            } else {
                restingSince = nil
            }
            return
        }
        guard let panel, !dragging, !menuOpen, Date() > holdUntil else { awaySince = nil; return }
        var zone = panel.frame
        zone.size.height = (panel.screen ?? screen).frame.maxY - zone.minY     // the strip and the menu bar above it
        if zone.insetBy(dx: 0, dy: -8).contains(p) {
            awaySince = nil
        } else {
            if awaySince == nil { awaySince = Date() }
            if Date().timeIntervalSince(awaySince!) >= 0.5 { hide() }
        }
    }

    func toggle() {
        if isShown { hide() } else {
            holdUntil = Date().addingTimeInterval(4)
            show(on: screenUnderPointer() ?? NSScreen.main)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none                      // never part of a capture or a shared screen
        let v = CaptureLineView(owner: self)
        p.contentView = v
        lineView = v
        return p
    }

    private func show(on screen: NSScreen?) {
        guard let screen, !isShown || panel?.screen != screen else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let height: CGFloat = 150
        let frame = NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY - height, width: screen.frame.width, height: height)
        isShown = true
        awaySince = nil
        restingSince = nil
        panel.ignoresMouseEvents = false
        reload(width: frame.width)
        let slide: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 40
        panel.setFrame(frame.offsetBy(dx: 0, dy: slide), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        run(0.2) { t in
            let e = 1 - pow(1 - t, 3)                                  // ease out
            panel.setFrame(frame.offsetBy(dx: 0, dy: slide * (1 - e)), display: true)
            panel.alphaValue = e
        }
    }

    private var animation: Timer?
    private var animationDone: (() -> Void)?

    /// Steps [step] from 0 to 1 over [duration] on the main run loop (the window animator proxy did nothing for this
    /// panel: it stayed at its starting place, fully transparent). A new run replaces the one under way.
    private func run(_ duration: TimeInterval, done: (() -> Void)? = nil, _ step: @escaping (CGFloat) -> Void) {
        animation?.invalidate()
        animationDone = done
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let t = min(1, CGFloat(Date().timeIntervalSince(began) / duration))
            step(t)
            if t >= 1 {
                timer.invalidate()
                self?.animation = nil
                let finished = self?.animationDone
                self?.animationDone = nil
                finished?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    /// At once when a capture starts (the strip must not be in the picture or in the way).
    func hide(now: Bool = false) {
        guard isShown, let panel else { return }
        isShown = false
        awaySince = nil
        holdUntil = .distantPast
        if now { animation?.invalidate(); animation = nil; animationDone = nil; panel.orderOut(nil); panel.ignoresMouseEvents = true; return }
        let from = panel.alphaValue
        run(0.16, done: { [weak self] in
            if self?.isShown == false { panel.orderOut(nil); panel.ignoresMouseEvents = true }   // out of the way of every click
        }) { t in panel.alphaValue = from * (1 - t) }
    }

    private func reload(width: CGFloat? = nil) {
        guard let lineView else { return }
        let w = width ?? lineView.bounds.width
        lineView.setFiles(files(limit: 80), width: w)      // more than fit: the line scrolls
    }

    // MARK: - While dragging one out

    /// The strip gets out of the way of the app the capture is dragged to, and comes back when the drag is over.
    func dragBegan() {
        dragging = true
        animation?.invalidate(); animation = nil; animationDone = nil
        panel?.alphaValue = 0
        panel?.ignoresMouseEvents = true
    }

    func dragEnded() {
        dragging = false
        panel?.ignoresMouseEvents = false
        if isShown { panel?.alphaValue = 1; awaySince = Date() }
    }

    // MARK: - What a card can do

    func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = [url as NSURL]
        if let image = NSImage(contentsOf: url), ["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(url.pathExtension.lowercased()) {
            objects.insert(image, at: 0)
        }
        pb.writeObjects(objects)
        Toast.show("Copied", detail: url.lastPathComponent)
    }

    func openInEditor(_ url: URL) {
        hide()
        Shell.shared.openEditor(url)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Off the line on this Mac; the file stays in the captures folder and the Library.
    func takeOff(_ url: URL) {
        var hidden = UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []
        hidden.append(url.lastPathComponent)
        UserDefaults.standard.set(Array(hidden.suffix(300)), forKey: Self.hiddenKey)
        reload()
    }

    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        SnapLiteNative.shared?.invoke("capturesChanged")
        reload()
    }
}

/// The strip: a soft shade from the top edge, the cord, and one card per capture hanging from it.
final class CaptureLineView: NSView {
    static let slot: CGFloat = 150
    private unowned let owner: CaptureLine
    private var cards: [CaptureCardView] = []
    private var shown: [URL] = []

    init(owner: CaptureLine) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The cord sags a little towards the middle.
    private func cordY(at x: CGFloat, width: CGFloat) -> CGFloat {
        let t = max(0, min(1, x / max(1, width)))
        return 12 + 4 * 12 * t * (1 - t)
    }

    /// How far the line is scrolled: 0 = the newest capture at its starting place, growing towards the older ones.
    private var offset: CGFloat = 0
    private var lineWidth: CGFloat = 0

    func setFiles(_ files: [URL], width: CGFloat) {
        if files == shown, abs(lineWidth - width) < 1, !cards.isEmpty { return }
        let sameSet = files.first == shown.first
        shown = files
        lineWidth = width
        cards.forEach { $0.removeFromSuperview() }
        cards = files.enumerated().map { i, url in CaptureCardView(url: url, owner: owner, tilt: i % 2 == 0 ? -1.6 : 1.4) }
        cards.forEach { addSubview($0) }
        if !sameSet { offset = 0 }                 // a new capture: back to the newest
        place()
    }

    /// What does not fit to the right is reached by scrolling.
    private var maxOffset: CGFloat { max(0, CGFloat(cards.count) * Self.slot + 40 - lineWidth) }

    /// The cards along the cord: centred when they all fit, otherwise from the left edge, newest first, shifted by the scroll.
    private func place() {
        offset = max(0, min(maxOffset, offset))
        let total = CGFloat(cards.count) * Self.slot
        let start = (total + 40 <= lineWidth ? (lineWidth - total) / 2 : 20) + Self.slot / 2 - offset
        for (i, card) in cards.enumerated() {
            let x = start + CGFloat(i) * Self.slot
            card.isHidden = x < -Self.slot || x > lineWidth + Self.slot
            if !card.isHidden { card.hang(centerX: x, top: cordY(at: x, width: lineWidth) - 5) }
        }
        needsDisplay = true
    }

    /// Two fingers sideways (or up and down), or a mouse wheel, move along the line.
    override func scrollWheel(with event: NSEvent) {
        guard maxOffset > 0 else { return }
        let dx = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
        offset += dx * (event.hasPreciseScrollingDeltas ? 1 : 12)
        place()
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        // shade: darkest at the top edge, gone by the bottom of the strip
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.42), NSColor.black.withAlphaComponent(0.16), .clear])?
            .draw(in: bounds, angle: 90)
        let cord = NSBezierPath()
        cord.move(to: NSPoint(x: -4, y: 12))
        cord.curve(to: NSPoint(x: w + 4, y: 12), controlPoint1: NSPoint(x: w * 0.33, y: 28), controlPoint2: NSPoint(x: w * 0.67, y: 28))
        cord.lineWidth = 2
        NSColor.white.withAlphaComponent(0.85).setStroke()
        cord.stroke()
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.8)]
        if offset > 1 { ("‹" as NSString).draw(at: NSPoint(x: 6, y: 58), withAttributes: hint) }
        if offset < maxOffset - 1 { ("›" as NSString).draw(at: NSPoint(x: w - 16, y: 58), withAttributes: hint) }
        if cards.isEmpty {
            let text = "No captures yet"
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font(13), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (w - size.width) / 2, y: 44), withAttributes: attrs)
        }
    }
}

/// One capture on the line: a peg on the cord, the picture under it. The drag source.
final class CaptureCardView: NSView, NSDraggingSource {
    private static let maxSize = NSSize(width: 128, height: 88)
    private static let pegHeight: CGFloat = 16
    private static var thumbs = NSCache<NSString, NSImage>()

    let url: URL
    private unowned let owner: CaptureLine
    private let picture = NSImageView()
    private var downAt: NSPoint?
    private var dragStarted = false
    private var restY: CGFloat = 0
    private var hovering = false { didSet { if hovering != oldValue { settle() } } }

    init(url: URL, owner: CaptureLine, tilt: CGFloat) {
        self.url = url
        self.owner = owner
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.maxSize.width + 8, height: Self.maxSize.height + 8 + Self.pegHeight)))
        wantsLayer = true
        frameCenterRotation = tilt
        toolTip = url.deletingPathExtension().lastPathComponent
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 5
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = 2
        picture.layer?.borderColor = NSColor.white.cgColor
        picture.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        picture.unregisterDraggedTypes()
        addSubview(picture)
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.45)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -3)
            return s
        }()
        layoutPicture(for: Self.maxSize)
        loadThumbnail()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func hang(centerX: CGFloat, top: CGFloat) {
        restY = top
        setFrameOrigin(NSPoint(x: centerX - frame.width / 2, y: top))
    }

    /// The picture keeps its shape inside the card, hanging from the peg.
    private func layoutPicture(for size: NSSize) {
        let scale = min(Self.maxSize.width / max(1, size.width), Self.maxSize.height / max(1, size.height))
        let w = max(40, size.width * scale), h = max(30, size.height * scale)
        picture.frame = NSRect(x: (bounds.width - w) / 2, y: Self.pegHeight - 4, width: w, height: h)
        needsDisplay = true
    }

    private func loadThumbnail() {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)-\(stamp)" as NSString
        if let cached = Self.thumbs.object(forKey: key) {
            picture.image = cached
            layoutPicture(for: cached.size)
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 256, height: 176),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                Self.thumbs.setObject(image, forKey: key)
                self?.picture.image = image
                self?.layoutPicture(for: image.size)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // the peg: over the cord at the top, gripping the picture's top edge
        let peg = NSBezierPath(roundedRect: NSRect(x: bounds.midX - 4, y: 0, width: 8, height: Self.pegHeight), xRadius: 3, yRadius: 3)
        Theme.accent.setFill()
        peg.fill()
    }

    /// Under the pointer the card drops a little towards you.
    private func settle() {
        setFrameOrigin(NSPoint(x: frame.minX, y: restY + (hovering ? 6 : 0)))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let downAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - downAt.x, p.y - downAt.y) > 4 else { return }
        dragStarted = true
        // the file itself (Finder, mail, chat and upload fields take it) and, for a picture, its image data (editors, notes)
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "tiff"].contains(ext),
           let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size < 40_000_000, let data = try? Data(contentsOf: url) {
            item.setData(data, forType: ext == "png" ? .png : (ext == "tiff" ? .tiff : NSPasteboard.PasteboardType("public.jpeg")))
        }
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(picture.frame, contents: picture.image)
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        owner.dragBegan()
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard !dragStarted else { return }
        if event.clickCount >= 2 { owner.openInEditor(url) } else { owner.copy(url) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Copy", #selector(copyIt))
        add("Open in Editor", #selector(openIt))
        add("Show in Finder", #selector(revealIt))
        menu.addItem(.separator())
        add("Take Off the Line", #selector(takeOff))
        add("Move to Trash", #selector(trashIt))
        owner.menuOpen = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        owner.menuOpen = false
    }

    @objc private func copyIt() { owner.copy(url) }
    @objc private func openIt() { owner.openInEditor(url) }
    @objc private func revealIt() { owner.reveal(url) }
    @objc private func takeOff() { owner.takeOff(url) }
    @objc private func trashIt() { owner.trash(url) }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        owner.dragEnded()
    }
}
