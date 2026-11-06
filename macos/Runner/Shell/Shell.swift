import AppKit
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

/// Namespace for image helpers shared with the Swift app (CapturePanel adds `applyEffect`).
enum Renderer {}

/// The menu bar app, ported from the Swift SnapLite's AppDelegate: status item, capture panel (left click),
/// full menu (right click), global hotkeys, capture / countdown / copy text / recording flows.
/// The editor and Library are Flutter; this talks to them through `SnapLiteNative.shared`.
final class Shell: NSObject, NSMenuDelegate, NSPopoverDelegate {
    static let shared = Shell()

    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let panel = CapturePanelController()
    private var menu: NSMenu!
    private let recentMenu = NSMenu()
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let openEditorItem = NSMenuItem(title: "Open in Editor", action: #selector(toggleOpenEditor), keyEquivalent: "")
    private let copyImageItem = NSMenuItem(title: "Copy to Clipboard", action: #selector(toggleCopyImage), keyEquivalent: "")
    private let microphoneItem = NSMenuItem(title: "Record Microphone", action: #selector(toggleMicrophone), keyEquivalent: "")
    private let recorder = Recorder()
    private var recordingTimer: Timer?
    private var countdownTimer: Timer?
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    /// Which global shortcuts are live: all of them, only Capture Region, or none (per direct request,
    /// 2026-11-06: "the hot keys should be able to be disabled, sometimes other [than] option T you dont
    /// want any other hot keys to work"). Persisted as hotkeys.mode.
    enum HotkeyMode: String { case all, regionOnly, none }
    private var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: defaults.string(forKey: "hotkeys.mode") ?? "") ?? .all }
        set { defaults.set(newValue.rawValue, forKey: "hotkeys.mode") }
    }
    private let hotkeysItem = NSMenuItem(title: "Hotkeys", action: nil, keyEquivalent: "")
    private var hotkeyModeItems: [HotkeyMode: NSMenuItem] = [:]
    private let shortcutWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var busy = false   // a capture, countdown or region pick is in progress

    func start() {
        defaults.register(defaults: [Prefs.openEditor: true, Prefs.copyImage: false, Prefs.microphone: false])
        NSApp.appearance = Theme.appearance
        // In "Match System", follow light/dark switches while running
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            if Theme.choice == .system { NotificationCenter.default.post(name: Theme.changed, object: nil) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        showIdleIcon()
        menu = buildMenu()

        // Left click: the capture panel. Right click (or ⌃-click): the full menu, also behind the panel's gear.
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.delegate = self
        panel.gearMenu = menu
        panel.onCapture = { [weak self] config in self?.captureFromPanel(config) }
        panel.onOpenLibrary = { [weak self] in
            self?.popover.performClose(nil)
            self?.showLibrary()
        }
        registerHotKeys()
        NotificationCenter.default.addObserver(self, selector: #selector(registerHotKeys), name: Shortcuts.changed, object: nil)
        // The region picker offers S (scrolling capture) over anything that scrolls
        RegionCapture.scrollHandler = { [weak self] rect, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.scrollCapture(area: rect) }   // after the picker's completion
        }
        // Scripting hook: a distributed notification "com.mm.snaplite.scrollCapture" whose object is "x,y,w,h"
        // (global Cocoa points) runs a scrolling capture of that area without the picker (automated tests).
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(scriptedScrollCapture(_:)),
            name: Notification.Name("com.mm.snaplite.scrollCapture"), object: nil, suspensionBehavior: .deliverImmediately)

        ScreenPermission.checkAtLaunch()
        // A quiet look for a newer release once the app has settled; manual checks are in the menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { UpdateCheck.run(manual: false) }
        ScheduledCapture.shared.onChange = { [weak self] in
            guard let self, !self.busy, !self.recorder.isRecording else { return }
            self.showIdleIcon()
        }
        ScheduledCapture.shared.resumeIfRunning()
    }

    // MARK: - Menus

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Capture Region", #selector(captureRegion), shortcut: .region))
        menu.addItem(item("Capture Window", #selector(captureWindow), shortcut: .window))
        menu.addItem(item("Capture Full Screen", #selector(captureScreen), shortcut: .screen))
        let delayed = NSMenuItem(title: "Capture Region After Delay", action: nil, keyEquivalent: "")
        delayed.submenu = NSMenu()
        for seconds in [3, 5, 10] {
            let entry = item("\(seconds) Seconds", #selector(captureDelayed(_:)))
            entry.tag = seconds
            delayed.submenu?.addItem(entry)
        }
        menu.addItem(delayed)
        menu.addItem(item("Capture Scrolling Area", #selector(captureScrolling), shortcut: .scroll))
        menu.addItem(item("Copy Text…", #selector(grabText), shortcut: .text))
        menu.addItem(item("Record Screen…", #selector(startRecordingFromMenu), shortcut: .record))
        menu.addItem(ScheduledCapture.shared.menuItem())
        shortcutWarning.isEnabled = false
        menu.addItem(shortcutWarning)
        menu.addItem(.separator())
        menu.addItem(item("Library", #selector(showLibrary), shortcut: .library))
        menu.addItem(item("Open Image…", #selector(openImage)))
        let recent = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(item("Open Captures Folder", #selector(openFolder)))
        menu.addItem(.separator())
        let after = NSMenuItem(title: "After Capture", action: nil, keyEquivalent: "")
        after.submenu = NSMenu()
        for entry in [openEditorItem, copyImageItem] {
            entry.target = self
            after.submenu?.addItem(entry)
        }
        menu.addItem(after)
        hotkeysItem.submenu = NSMenu()
        for (mode, title) in [(HotkeyMode.all, "All Shortcuts"), (.regionOnly, "Only Capture Region"), (.none, "None (Paused)")] {
            let entry = NSMenuItem(title: title, action: #selector(setHotkeyMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            hotkeyModeItems[mode] = entry
            hotkeysItem.submenu?.addItem(entry)
        }
        menu.addItem(hotkeysItem)
        for entry in [microphoneItem, loginItem] {
            entry.target = self
            menu.addItem(entry)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(item("About SnapNow", #selector(showAbout)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(NSMenuItem(title: "Quit SnapNow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func checkForUpdates() { UpdateCheck.run(manual: true) }

    /// Compares the running version with the latest GitHub release of the (public) repo — no token needed —
    /// and says so: a notice when a newer one exists; on a manual check, also "you're current" or the error.
    enum UpdateCheck {
        static let latestURL = URL(string: "https://api.github.com/repos/msafarulla/snapnow/releases/latest")!
        static let page = URL(string: "https://github.com/msafarulla/snapnow/releases/latest")!

        static func run(manual: Bool) {
            var request = URLRequest(url: latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { data, _, _ in
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if manual { DispatchQueue.main.async { Toast.show("Couldn't check for updates", symbol: "exclamationmark.triangle.fill") } }
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                DispatchQueue.main.async {
                    if isNewer(latest, than: current) {
                        Toast.show("SnapNow \(latest) is available", symbol: "arrow.down.circle.fill",
                                   detail: "You have \(current). Check for Updates… in the menu opens the release.")
                        if manual { NSWorkspace.shared.open(page) }
                    } else if manual {
                        Toast.show("SnapNow \(current) is the latest version")
                    }
                }
            }.resume()
        }

        /// Dotted versions compared number by number: 1.58.20 is newer than 1.58.3.
        static func isNewer(_ a: String, than b: String) -> Bool {
            let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
            for i in 0..<max(x.count, y.count) {
                let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
                if p != q { return p > q }
            }
            return false
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "")"
        let build = "\(info?["CFBundleVersion"] ?? "")"
        let credits = NSAttributedString(
            string: "Control Alt Shift Technologies\nScreenshot, markup, recording and GIF capture.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "SnapNow",
            .applicationVersion: "Version \(version) (\(build))",
            .credits: credits,
        ])
    }

    private func item(_ title: String, _ action: Selector, shortcut: ShortcutAction? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let shortcut { shortcutItems[shortcut] = item }
        return item
    }

    /// Shows each item's current shortcut, and a warning line for ones another app owns.
    private func updateShortcutItems() {
        let region = Shortcuts.get(.region)?.display ?? "Capture Region"
        hotkeyModeItems[.regionOnly]?.title = "Only Capture Region (\(region))"
        for (mode, entry) in hotkeyModeItems { entry.state = mode == hotkeyMode ? .on : .off }
        switch hotkeyMode {
        case .all: hotkeysItem.title = "Hotkeys"
        case .regionOnly: hotkeysItem.title = "Hotkeys: Only \(region)"
        case .none: hotkeysItem.title = "Hotkeys: Paused"
        }
        for (action, item) in shortcutItems {
            let (key, mask) = Shortcuts.get(action)?.menuKey ?? ("", [])
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mask
        }
        let failed = Shortcuts.failed.compactMap { Shortcuts.get($0)?.display }
        shortcutWarning.title = "Shortcut in use by another app: " + failed.joined(separator: ", ")
        shortcutWarning.isHidden = failed.isEmpty
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateShortcutItems()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        openEditorItem.state = defaults.bool(forKey: Prefs.openEditor) ? .on : .off
        copyImageItem.state = defaults.bool(forKey: Prefs.copyImage) ? .on : .off
        microphoneItem.state = defaults.bool(forKey: Prefs.microphone) ? .on : .off

        recentMenu.removeAllItems()
        let files = (try? FileManager.default.contentsOfDirectory(at: Capture.folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                   options: .skipsHiddenFiles)) ?? []
        let recent = files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
        for (url, _) in recent {
            let entry = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            recentMenu.addItem(entry)
        }
        if recentMenu.items.isEmpty {
            let empty = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        }
    }

    // MARK: - Menu bar icon states

    /// A bold viewfinder as a template image: macOS draws it black on a light menu bar and white on a
    /// dark one, so it always has full contrast.
    private static let idleIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapNow")!
            .withSymbolConfiguration(config)!
        image.isTemplate = true
        return image
    }()

    private func showIdleIcon() {
        // While scheduled screenshots run, the icon says so
        statusItem.button?.image = ScheduledCapture.shared.isRunning
            ? NSImage(systemSymbolName: "camera.badge.clock", accessibilityDescription: "Scheduled screenshots running") ?? Self.idleIcon
            : Self.idleIcon
        statusItem.button?.contentTintColor = nil
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
    }

    private func showCountdown(_ seconds: Int) {
        CountdownHUD.show(seconds)
        statusItem.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Countdown")
        statusItem.button?.title = " \(seconds)"
        statusItem.button?.imagePosition = .imageLeading
    }

    // MARK: - Hotkeys

    @objc private func setHotkeyMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = HotkeyMode(rawValue: raw) else { return }
        hotkeyMode = mode
        registerHotKeys()
        switch mode {
        case .all: Toast.show("All shortcuts on")
        case .regionOnly: Toast.show("Only \(Shortcuts.get(.region)?.display ?? "Capture Region") is on")
        case .none: Toast.show("Shortcuts paused")
        }
    }

    /// Whether `action`'s global shortcut should be live under the current hotkey mode.
    private func hotkeyEnabled(_ action: ShortcutAction) -> Bool {
        guard Shortcuts.isEnabled(action) else { return false }   // switched off in Settings
        switch hotkeyMode {
        case .all: return true
        case .regionOnly: return action == .region
        case .none: return false
        }
    }

    /// Registers the shortcuts from Settings (those the hotkey mode allows); runs again whenever they change.
    @objc private func registerHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        Shortcuts.failed.removeAll()
        for action in ShortcutAction.allCases {
            guard hotkeyEnabled(action), let shortcut = Shortcuts.get(action) else { continue }
            let ok = HotKeyCenter.shared.register(shortcut) { [weak self] in self?.perform(action) }
            if !ok {
                Shortcuts.failed.append(action)
                NSLog("SnapNow: could not register %@ (another app owns it)", shortcut.display)
            }
        }
        updateShortcutItems()
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .region: captureRegion()
        case .scroll: captureScrolling()
        case .window: afterDelay { $0.capture(.window) }
        case .screen: afterDelay { $0.capture(.screen) }
        case .text: afterDelay { $0.grabText() }
        case .record: toggleRecording()
        case .library: showLibrary()
        }
    }

    // MARK: - Capture

    /// The area is picked first; the panel's timer then counts down before it's captured.
    @objc private func captureRegion() {
        let config = CaptureConfig.current
        capture(.region, delay: config.delayOn ? config.delaySeconds : 0)
    }
    /// Pick an area over something that scrolls; SnapNow scrolls it, shoots as it goes and stitches one tall image.
    @objc private func captureScrolling() { scrollCapture(area: nil) }

    @objc private func scriptedScrollCapture(_ n: Notification) {
        ScrollCapture.note("scripted request \(String(describing: n.object)) busy=\(busy)")
        guard let spec = n.object as? String else { return }
        let v = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4 else { return }
        scrollCapture(area: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
    }

    private func scrollCapture(area: CGRect?) {
        guard !busy, !recorder.isRecording, hasPermission() else { ScrollCapture.note("not started: busy \(busy), recording \(recorder.isRecording)"); return }
        busy = true
        ScrollCapture.start(area: area, sound: CaptureConfig.current.captureSound) { [weak self] url in
            self?.busy = false
            if let url { self?.handleCapture(url) }
        }
    }
    @objc private func captureWindow() { afterDelay { $0.capture(.window) } }
    @objc private func captureScreen() { afterDelay { $0.capture(.screen) } }

    /// Window, screen and text shortcuts honour the panel's timer: count down first when it's on.
    private func afterDelay(_ run: @escaping (Shell) -> Void) {
        let config = CaptureConfig.current
        guard config.delayOn else { return run(self) }
        countdown(config.delaySeconds) { [weak self] in if let self { run(self) } }
    }

    private func hasPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        showPermissionAlert()
        return false
    }

    // MARK: - Status item and panel

    @objc private func statusClicked() {
        if recorder.isRecording {
            stopRecording()
            return
        }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            statusItem.menu = menu            // attach just long enough to show it
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            panel.reload()
            panel.updateCompact(for: button.window?.screen)
            popover.appearance = Theme.appearance
            // Active first: over another app's full-screen Space the popover otherwise lands on the desktop Space
            // (or closes at once as the menu bar slides away) and nothing seems to happen.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let w = popover.contentViewController?.view.window {
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                w.makeKey()                                      // so the first click on a chip counts
            }
            // .transient only notices outside clicks while SnapNow is active, and activate() is just a request
            // (often ignored for a menu bar app), so a click in any other app closes the panel too. Global
            // mouse monitors need no Accessibility permission; clicks on our own icon aren't reported here.
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    private var outsideClicks: Any?

    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClicks { NSEvent.removeMonitor(m) }
        outsideClicks = nil
    }

    /// The panel's Capture button: optional countdown, then the tab's capture with its settings.
    private func captureFromPanel(_ config: CaptureConfig) {
        popover.performClose(nil)
        let run = { [weak self] in
            guard let self else { return }
            switch config.tab {
            case .allInOne: self.capture(.region)
            case .image:
                switch config.imageSelection {
                case .region: self.capture(.region)
                case .window: self.capture(.window)
                case .fullScreen: self.capture(.screen, cursor: config.cursor)
                }
            case .video: self.startRecording(fullScreen: config.videoSelection == .fullScreen)
            case .text: self.grabText()
            }
        }
        if config.delayOn && config.mode == .area {
            // Pick the area first; the countdown runs after it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.capture(.region, delay: config.delaySeconds) }
        } else if config.delayOn {
            countdown(config.delaySeconds, then: run)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: run)   // let the panel fade out first
        }
    }

    /// `delay`: for a region, pick the area first, then count down and capture it.
    func capture(_ mode: CaptureMode, cursor: Bool = false, delay: Int = 0) {
        guard !busy, !recorder.isRecording, hasPermission() else { return }
        busy = true
        let config = CaptureConfig.current
        Capture.run(mode, cursor: cursor, windowShadow: config.windowShadow, sound: config.captureSound, delay: delay) { [weak self] url in
            self?.busy = false
            if let url { self?.handleCapture(url) }   // nil: the user pressed Esc
        }
    }

    /// Image captures (hotkeys and the panel alike) get the panel's effect, clipboard, editor and share settings.
    private func handleCapture(_ url: URL) {
        let config = CaptureConfig.current
        Renderer.applyEffect(config.effect, to: url)
        if UserDefaults.standard.bool(forKey: Prefs.wmEnabled) { Watermark.apply(to: url) } // user's text/image watermark
        if Prefs.onByDefault(Prefs.stampTime) { CaptureStamp.apply(to: url) } // date & time, bottom-right (on top)
        if Prefs.onByDefault(Prefs.roundCorners) { RoundCorners.apply(to: url) } // rounded corners, last so it clips all
        SnapLiteNative.shared?.invoke("capturesChanged")
        switch config.share {
        case .none: break
        case .desktop:
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            try? FileManager.default.copyItem(at: url, to: Capture.uniqueURL(in: desktop, base: url.deletingPathExtension().lastPathComponent))
        case .finder: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .preview:
            if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        let copy = defaults.bool(forKey: Prefs.copyImage)
        let open = defaults.bool(forKey: Prefs.openEditor)
        if copy, let data = try? Data(contentsOf: url) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        }
        if open {
            openEditor(url)
        } else if !copy {
            Toast.show("Saved to Pictures › SnapNow")   // otherwise there is no sign the capture happened
        }
    }

    /// The menu's delayed region capture.
    @objc private func captureDelayed(_ sender: NSMenuItem) {
        capture(.region, delay: sender.tag)
    }

    /// Counts down on screen and in the menu bar (time to open a menu or hover something), then runs `action`.
    private func countdown(_ seconds: Int, then action: @escaping () -> Void) {
        guard !busy, !recorder.isRecording, hasPermission() else { return }
        busy = true
        var remaining = seconds
        showCountdown(remaining)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return }
            remaining -= 1
            if remaining > 0 {
                self.showCountdown(remaining)
                return
            }
            timer.invalidate()
            CountdownHUD.hide()
            self.showIdleIcon()
            // A moment for the countdown to leave the screen before the capture starts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.busy = false
                action()
            }
        }
    }

    /// Region capture straight to OCR; the text goes to the clipboard and the image is thrown away.
    @objc func grabText() {
        guard !busy, !recorder.isRecording, hasPermission() else { return }
        busy = true
        let temp = Capture.uniqueURL(in: Capture.cacheFolder, base: "grab-text")
        Capture.run(.region, to: temp, sound: CaptureConfig.current.captureSound) { [weak self] url in
            self?.busy = false
            guard let url else { return }
            // Read the whole file into memory first: ImageIO decodes lazily, and deleting the file
            // before Vision got to it left an empty image (seen on the Air). Delete only when done.
            guard let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                try? FileManager.default.removeItem(at: url)
                Toast.show("Could not read the capture", symbol: "exclamationmark.triangle.fill")
                return
            }
            Toast.show("Reading text…", symbol: "text.viewfinder")
            TextGrabber.recognize(image) { text in
                try? FileManager.default.removeItem(at: url)
                Shell.copyText(text)
            }
        }
    }

    /// Puts OCR text on the clipboard and previews it in a toast.
    static func copyText(_ text: String, hint: String = "") {
        guard !text.isEmpty else {
            Toast.show("No text found", symbol: "text.magnifyingglass")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Show what was read in the notice at the bottom; it is already on the clipboard
        let lines = text.split(separator: "\n").count
        Toast.show(lines == 1 ? "Copied 1 line" : "Copied \(lines) lines", symbol: "text.viewfinder", detail: text,
                   footnote: hint.isEmpty ? nil : hint)
    }

    private func showPermissionAlert() {
        PermissionGuide.shared.show()
    }

    // MARK: - Recording

    func toggleRecording() {
        if recorder.isRecording { stopRecording() } else { startRecording(fullScreen: false) }
    }

    @objc private func startRecordingFromMenu() {
        startRecording(fullScreen: false)
    }

    /// Full screen records the screen under the mouse; otherwise the user drags an area first.
    private func startRecording(fullScreen: Bool) {
        guard !busy, !recorder.isRecording, hasPermission() else { return }
        busy = true
        let begin = { [weak self] (rect: CGRect) in
            guard let self else { return }
            self.busy = false
            let config = CaptureConfig.current
            let started = self.recorder.start(rect: rect, microphone: config.microphone, showClicks: config.showClicks) { movie in
                self.recordingFinished(movie)
            }
            if started { self.showRecordingState() }
        }
        if fullScreen {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens[0]
            begin(screen.frame)
            return
        }
        RegionSelector.select(hint: "Drag to record an area, or click to record this whole screen. Esc cancels.") { [weak self] rect in
            guard let rect else {
                self?.busy = false
                return
            }
            // Give the overlay time to disappear so it is not in the first frames
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { begin(rect) }
        }
    }

    /// While recording, the menu bar icon is a red stop button with the elapsed time.
    private func showRecordingState() {
        popover.performClose(nil)   // a click on the icon now stops the recording (see statusClicked)
        statusItem.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        statusItem.button?.contentTintColor = .systemRed
        statusItem.button?.imagePosition = .imageLeading
        updateRecordingTime()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateRecordingTime() }
    }

    private func updateRecordingTime() {
        let seconds = Int(Date().timeIntervalSince(recorder.startedAt ?? Date()))
        statusItem.button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func stopRecording() {
        recorder.stop()
    }

    private func recordingFinished(_ movie: URL?) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        showIdleIcon()
        guard let movie else {
            Toast.show("Recording failed", symbol: "exclamationmark.triangle.fill")
            return
        }
        SnapLiteNative.shared?.invoke("capturesChanged")
        if CaptureConfig.current.openVideoWhenDone {
            Toast.show("Recording saved. Trim it with ⌘T in QuickTime.", symbol: "video.fill")
            NSWorkspace.shared.open(movie)
        } else {
            Toast.show("Recording saved to the Library", symbol: "video.fill")
        }
    }

    // MARK: - Settings

    @objc private func toggleOpenEditor() { defaults.set(!defaults.bool(forKey: Prefs.openEditor), forKey: Prefs.openEditor) }
    @objc private func toggleCopyImage() { defaults.set(!defaults.bool(forKey: Prefs.copyImage), forKey: Prefs.copyImage) }
    @objc private func toggleMicrophone() { defaults.set(!defaults.bool(forKey: Prefs.microphone), forKey: Prefs.microphone) }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Editor, library and files (Flutter)

    func openEditor(_ url: URL) {
        NSApp.activate()
        SnapLiteNative.shared?.invoke("openEditor", url.path)
    }

    @objc func showLibrary() {
        NSApp.activate()
        SnapLiteNative.shared?.invoke("showLibrary")
    }

    @objc func openImage() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = Capture.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openEditor(url)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openEditor(url) }
    }

    @objc func showSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Capture.folder)
    }
}
