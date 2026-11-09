import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// UserDefaults keys shared by the menu bar menu and the Settings window.
enum Prefs {
    static let openEditor = "openEditorAfterCapture"
    static let copyImage = "copyAfterCapture"
    static let microphone = "recordMicrophone"
    /// Option+click anywhere shows the pointing hand (same as the WMOS automation). Default on.
    static let altClickHand = "altClickHand"
    /// Format Save As starts on; empty means the last one used.
    static let saveAsFormat = "saveAs.defaultFormat"
    /// Animated GIF frames a second ("15", "25" or "50"); the editor reads it each time it makes a GIF.
    static let gifFps = "gifFps"
    static let gifFpsChoices = ["50", "25", "15"]
    /// Area capture re-offers the last region (outlined; Enter or a click inside re-captures it). Default on.
    static let rememberArea = "regionCapture.rememberArea"
    /// Burns the capture's date & time into the bottom-right corner. Default on.
    static let stampTime = "capture.stampTime"
    /// Rounds the capture's corners. Default on.
    static let roundCorners = "capture.roundCorners"
    /// A new capture opens in the editor already in Crop mode (frame + handles ready). Default on.
    static let openInCrop = "capture.openInCrop"
    /// Watermark stamped on captures (text and/or image), all configurable; off by default.
    static let wmEnabled = "watermark.enabled"
    static let wmText = "watermark.text"
    static let wmImage = "watermark.imagePath"        // copied into Application Support; stable path
    static let wmPlacement = "watermark.placement"    // bottomRight | center | tiled
    static let wmOpacity = "watermark.opacity"        // 10…100 (percent); default 30
    static let wmPlacements = ["bottomRight", "center", "tiled"]
    static var wmOpacityValue: Int { UserDefaults.standard.object(forKey: wmOpacity) == nil ? 8 : UserDefaults.standard.integer(forKey: wmOpacity) }

    /// A bool pref that defaults to true when it has never been set (plain `bool(forKey:)` would read false).
    static func onByDefault(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    /// A bool pref that is off until the user turns it on (the picker's remembered last area, 2026-11-04).
    static func offByDefault(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Which tools get a toolbar button; the rest are under More.
enum ToolbarPrefs {
    static let changed = Notification.Name("SnapLiteToolbarChanged")
    private static let key = "toolbarTools"
    /// Toolbar order, used for every arrangement so toggling a tool never reshuffles the rest.
    // Box is the editor's Shape button (rectangle, square, ellipse or circle), so Ellipse isn't listed on its own
    static let order: [Tool] = [.select, .arrow, .text, .callout, .box, .line, .pen, .step, .highlight, .blur, .spotlight, .crop]
    static let defaults: [Tool] = [.select, .arrow, .text, .callout, .box, .step, .highlight, .blur, .crop]

    static var visible: [Tool] {
        get {
            guard let raw = UserDefaults.standard.array(forKey: key) as? [Int] else { return defaults }
            return raw.compactMap(Tool.init(rawValue:))
        }
        set {
            let ordered = order.filter(newValue.contains)
            UserDefaults.standard.set(ordered.map(\.rawValue), forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let stack = NSStackView()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SnapNow Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: Theme.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: Shortcuts.changed, object: nil)   // on/off + "in use" status
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        rebuild()
        guard let window else { return }
        // Shown from the menu bar panel's gear menu with ⌘,: the app is not active yet and the window
        // used to stay behind the front app (or on another Space when the user was in a full-screen
        // app), so it took a second ⌘, to see it (2026-11-06). Activate first, join the active Space,
        // and order the window front regardless of activation.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func rebuild() {
        guard let window else { return }
        // A rebuild while the window is open (a checkbox, a recorded key, a theme change) keeps the
        // window's height and the distance scrolled from the top; otherwise the view jumped back to
        // the top on every toggle ("checking or unchecking scrolls me back", 2026-11-06).
        var keepHeight: CGFloat?
        var keepFromTop: CGFloat?
        if window.isVisible, let old = window.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first, let doc = old.documentView {
            keepHeight = old.bounds.height
            keepFromTop = doc.bounds.height - old.contentView.bounds.maxY
        }
        Theme.style(window)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Appearance
        stack.addArrangedSubview(heading("Appearance"))
        let appearance = NSPopUpButton(frame: .zero, pullsDown: false)
        appearance.addItems(withTitles: AppearanceChoice.allCases.map(\.label))
        appearance.selectItem(at: AppearanceChoice.allCases.firstIndex(of: Theme.choice) ?? 0)
        appearance.target = self
        appearance.action = #selector(appearanceChosen(_:))
        stack.addArrangedSubview(row("Theme", appearance))
        stack.addArrangedSubview(note("Glass follows your Mac's light/dark mode and accent color. Tokyo Night matches your terminal."))

        // Toolbar
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Toolbar"))
        stack.addArrangedSubview(note("Checked tools get a toolbar button; the rest are under More."))
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 18
        let visible = ToolbarPrefs.visible
        var cells: [NSView] = []
        for tool in ToolbarPrefs.order {
            // No icon on the checkbox itself: a button image replaces the check mark
            let box = checkbox(tool.label, on: visible.contains(tool), action: #selector(toolToggled(_:)))
            box.tag = tool.rawValue
            cells.append(box)
            if cells.count == 3 {
                grid.addRow(with: cells)
                cells.removeAll()
            }
        }
        // Pad the last row with separate empty views (a grid cannot hold the same view twice)
        if !cells.isEmpty { grid.addRow(with: cells + (cells.count..<3).map { _ in NSView() }) }
        for i in 0..<3 { grid.column(at: i).width = 140 }
        stack.addArrangedSubview(grid)
        let reset = NSButton(title: "Reset Toolbar", target: self, action: #selector(resetToolbar))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        // Capture
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Capture"))
        let defaults = UserDefaults.standard
        stack.addArrangedSubview(checkbox("Open captures in the editor", on: defaults.bool(forKey: Prefs.openEditor),
                                          action: #selector(prefToggled(_:)), key: Prefs.openEditor))
        stack.addArrangedSubview(checkbox("Copy captures to the clipboard", on: defaults.bool(forKey: Prefs.copyImage),
                                          action: #selector(prefToggled(_:)), key: Prefs.copyImage))
        stack.addArrangedSubview(checkbox("Record the microphone with screen recordings", on: defaults.bool(forKey: Prefs.microphone),
                                          action: #selector(prefToggled(_:)), key: Prefs.microphone))
        stack.addArrangedSubview(checkbox("Remember the last capture area (Enter re-captures it)", on: Prefs.offByDefault(Prefs.rememberArea),
                                          action: #selector(prefToggled(_:)), key: Prefs.rememberArea))
        stack.addArrangedSubview(checkbox("Stamp the date & time on captures (bottom-right)", on: Prefs.onByDefault(Prefs.stampTime),
                                          action: #selector(prefToggled(_:)), key: Prefs.stampTime))
        stack.addArrangedSubview(checkbox("Round the capture corners", on: Prefs.onByDefault(Prefs.roundCorners),
                                          action: #selector(prefToggled(_:)), key: Prefs.roundCorners))
        stack.addArrangedSubview(checkbox("Open new captures in Crop mode", on: Prefs.onByDefault(Prefs.openInCrop),
                                          action: #selector(prefToggled(_:)), key: Prefs.openInCrop))
        stack.addArrangedSubview(checkbox("Open SnapNow at login", on: SMAppService.mainApp.status == .enabled,
                                          action: #selector(loginToggled(_:))))
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        let names = SaveAs.available.map(\.name)
        format.addItems(withTitles: ["Last Used"] + names)
        format.selectItem(at: names.firstIndex(of: defaults.string(forKey: Prefs.saveAsFormat) ?? "").map { $0 + 1 } ?? 0)
        format.target = self
        format.action = #selector(saveAsFormatChosen(_:))
        stack.addArrangedSubview(row("Save As format", format))
        stack.addArrangedSubview(note("⇧⌘S starts on this format. Captures stay PNG so their markup stays editable."))
        let fps = NSPopUpButton(frame: .zero, pullsDown: false)
        fps.addItems(withTitles: Prefs.gifFpsChoices.map { "\($0) frames a second" })
        fps.selectItem(at: Prefs.gifFpsChoices.firstIndex(of: defaults.string(forKey: Prefs.gifFps) ?? "") ?? 0)
        fps.target = self
        fps.action = #selector(gifFpsChosen(_:))
        stack.addArrangedSubview(row("GIF frame rate", fps))
        stack.addArrangedSubview(note("For Save as Animated GIF and ⇧⌘C. More frames look smoother; fewer make smaller files."))

        // Watermark
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Watermark"))
        stack.addArrangedSubview(checkbox("Add a watermark to captures", on: defaults.bool(forKey: Prefs.wmEnabled),
                                          action: #selector(prefToggled(_:)), key: Prefs.wmEnabled))
        let wmTextField = NSTextField(string: defaults.string(forKey: Prefs.wmText) ?? "")
        wmTextField.placeholderString = "Watermark text"
        wmTextField.target = self
        wmTextField.action = #selector(watermarkTextChanged(_:))
        wmTextField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(row("Text", wmTextField))
        let imgName = NSTextField(labelWithString: Self.wmImageName())
        imgName.font = Theme.font(12)
        imgName.textColor = Theme.dimText
        watermarkImageLabel = imgName
        let chooseImg = NSButton(title: "Choose…", target: self, action: #selector(chooseWatermarkImage))
        chooseImg.bezelStyle = .rounded
        let clearImg = NSButton(title: "Clear", target: self, action: #selector(clearWatermarkImage))
        clearImg.bezelStyle = .rounded
        let imgRow = NSStackView(views: [chooseImg, clearImg, imgName])
        imgRow.spacing = 8
        imgRow.alignment = .centerY
        stack.addArrangedSubview(row("Image", imgRow))
        let placement = NSPopUpButton(frame: .zero, pullsDown: false)
        placement.addItems(withTitles: ["Bottom-right", "Centered", "Tiled"])
        placement.selectItem(at: Prefs.wmPlacements.firstIndex(of: defaults.string(forKey: Prefs.wmPlacement) ?? "bottomRight") ?? 0)
        placement.target = self
        placement.action = #selector(watermarkPlacementChosen(_:))
        stack.addArrangedSubview(row("Placement", placement))
        let opacity = NSSlider(value: Double(Prefs.wmOpacityValue), minValue: 5, maxValue: 100, target: self, action: #selector(watermarkOpacityChanged(_:)))
        opacity.widthAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(row("Opacity", opacity))
        stack.addArrangedSubview(note("Your text and/or image are stamped on every capture at the chosen spot and opacity."))

        // Shortcuts
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Shortcuts"))
        stack.addArrangedSubview(note("Click a shortcut, then press the new keys (with ⌃, ⌥ or ⌘). Delete clears it, Esc cancels."))
        // Plain rows, not an NSGridView: inside the scrolled Settings the grid drew only one of its
        // columns at a time on the 14" (labels without buttons, then checkboxes without labels,
        // "sometimes"), so each row is a horizontal stack with fixed column widths.
        let labelWidth = ShortcutAction.allCases
            .map { ($0.label as NSString).size(withAttributes: [.font: Theme.font(12)]).width }.max().map { ceil($0) + 4 } ?? 220
        let keys = NSStackView()
        keys.orientation = .vertical
        keys.alignment = .leading
        keys.spacing = 6
        for action in ShortcutAction.allCases {
            let enabled = Shortcuts.isEnabled(action)
            let onOff = NSButton(checkboxWithTitle: "", target: self, action: #selector(shortcutToggled(_:)))
            onOff.state = enabled ? .on : .off
            onOff.tag = ShortcutAction.allCases.firstIndex(of: action)!
            onOff.toolTip = "Off: this key is not taken by SnapNow"
            let what = NSTextField(labelWithString: action.label)
            what.font = Theme.font(12)
            what.textColor = enabled ? Theme.dimText : Theme.muted
            what.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            let recorder = ShortcutRecorder()
            recorder.widthAnchor.constraint(equalToConstant: 110).isActive = true
            recorder.shortcut = Shortcuts.get(action)
            recorder.isEnabled = enabled
            recorder.onChange = { [weak self] new in self?.shortcutChanged(new, for: action) }
            let status = NSTextField(labelWithString: enabled ? (Shortcuts.failed.contains(action) ? "⚠︎ in use by another app" : "") : "off")
            status.font = Theme.font(11)
            status.textColor = enabled ? .systemOrange : Theme.muted
            let row = NSStackView(views: [onOff, what, recorder, status])
            row.spacing = 12
            row.alignment = .centerY
            keys.addArrangedSubview(row)
        }
        stack.addArrangedSubview(keys)
        let resetKeys = NSButton(title: "Reset Shortcuts", target: self, action: #selector(resetShortcuts))
        resetKeys.bezelStyle = .rounded
        stack.addArrangedSubview(resetKeys)

        // The settings sit in a scroll view and the window is never taller than the screen it is
        // on: sized to the content's full height, the Shortcuts section at the bottom landed below the
        // 13" Air's screen edge with no way to reach it (2026-11-05). Resizable vertically; the
        // width stays the content's own. The view hierarchy inside is unchanged from before (backdrop
        // + stack, not flipped): a flipped document view made the shortcut buttons vanish.
        // The blur backdrop is the window's content view and the scroll view sits on top of it; the
        // scrolled document is a plain view. With the backdrop (an NSVisualEffectView) as the document,
        // AppKit stopped drawing the bezelled recorder buttons as soon as the document was taller than
        // the window - fine on a 15" Air (no scrolling), blank buttons on a 14" MacBook Pro (2026-11-06).
        let content = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let fit = content.fittingSize
        content.frame = NSRect(origin: .zero, size: fit)
        content.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = content
        let backdrop = Theme.makeBackdrop()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        window.contentView = backdrop
        backdrop.layoutSubtreeIfNeeded()   // settle the layout before the first draw
        // Never taller than ~70% of the screen's visible height (the rest scrolls): at the old
        // "screen minus 48" cap the window still filled a 14" MacBook Pro ("settings window is
        // still so big", 2026-11-06).
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = keepHeight.map { min($0, fit.height) } ?? min(fit.height, (screenHeight * 0.7).rounded())
        window.contentMinSize = NSSize(width: fit.width, height: min(360, fit.height))
        window.contentMaxSize = NSSize(width: fit.width, height: fit.height)
        window.setContentSize(NSSize(width: fit.width, height: height))
        // AppKit scrolls a non-flipped document to its bottom; start at the first section (or where the
        // user was) instead.
        scroll.layoutSubtreeIfNeeded()
        let fromTop = min(max(0, keepFromTop ?? 0), max(0, fit.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, fit.height - scroll.contentView.bounds.height - fromTop)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.font(14, bold: true)
        label.textColor = Theme.text
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.font(12)
        label.textColor = Theme.muted
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.font(13)
        label.textColor = Theme.dimText
        let row = NSStackView(views: [label, control])
        row.spacing = 10
        return row
    }

    private func separator() -> NSView {
        let line = FillView(.border)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: 472).isActive = true
        return line
    }

    private func checkbox(_ title: String, on: Bool, action: Selector, key: String? = nil) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.attributedTitle = NSAttributedString(string: title, attributes: [.font: Theme.font(13), .foregroundColor: Theme.text])
        box.state = on ? .on : .off
        box.identifier = key.map { NSUserInterfaceItemIdentifier($0) }
        return box
    }

    // MARK: - Actions

    @objc private func appearanceChosen(_ sender: NSPopUpButton) {
        Theme.choice = AppearanceChoice.allCases[sender.indexOfSelectedItem]   // posts Theme.changed, which rebuilds this window
    }

    @objc private func toolToggled(_ sender: NSButton) {
        guard let tool = Tool(rawValue: sender.tag) else { return }
        var visible = ToolbarPrefs.visible
        if sender.state == .on { visible.append(tool) } else { visible.removeAll { $0 == tool } }
        ToolbarPrefs.visible = visible
    }

    @objc private func resetToolbar() {
        ToolbarPrefs.visible = ToolbarPrefs.defaults
        rebuild()
    }

    @objc private func prefToggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
    }

    @objc private func saveAsFormatChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        UserDefaults.standard.set(index > 0 ? sender.titleOfSelectedItem : "", forKey: Prefs.saveAsFormat)
    }

    @objc private func gifFpsChosen(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(Prefs.gifFpsChoices[sender.indexOfSelectedItem], forKey: Prefs.gifFps)
    }

    // MARK: Watermark

    private weak var watermarkImageLabel: NSTextField?

    /// The user's watermark image is copied here (a stable path that survives the original being moved).
    static func watermarkDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SnapNow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func wmImageName() -> String {
        let p = UserDefaults.standard.string(forKey: Prefs.wmImage) ?? ""
        return p.isEmpty ? "None" : (p as NSString).lastPathComponent
    }

    @objc private func watermarkTextChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue, forKey: Prefs.wmText)
    }

    @objc private func watermarkPlacementChosen(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(Prefs.wmPlacements[sender.indexOfSelectedItem], forKey: Prefs.wmPlacement)
    }

    @objc private func watermarkOpacityChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(Int(sender.doubleValue.rounded()), forKey: Prefs.wmOpacity)
    }

    @objc private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension
        let dest = Self.watermarkDir().appendingPathComponent("watermark.\(ext)")
        for old in (try? FileManager.default.contentsOfDirectory(at: Self.watermarkDir(), includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix("watermark.") {
            try? FileManager.default.removeItem(at: old)
        }
        do { try FileManager.default.copyItem(at: src, to: dest) } catch { return }
        UserDefaults.standard.set(dest.path, forKey: Prefs.wmImage)
        watermarkImageLabel?.stringValue = dest.lastPathComponent
    }

    @objc private func clearWatermarkImage() {
        UserDefaults.standard.removeObject(forKey: Prefs.wmImage)
        watermarkImageLabel?.stringValue = "None"
    }

    /// Rejects reserved and duplicate combinations; otherwise saves, which re-registers the hotkeys.
    @objc private func shortcutToggled(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        Shortcuts.setEnabled(sender.state == .on, for: action)   // posts Shortcuts.changed -> re-registers + rebuild
    }

    private func shortcutChanged(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if let shortcut {
            if shortcut.isReserved {
                Toast.show("\(shortcut.display) is a macOS shortcut", symbol: "exclamationmark.triangle.fill")
                rebuild()
                return
            }
            if let other = Shortcuts.owner(of: shortcut, except: action) {
                Toast.show("\(shortcut.display) is already used for \(other.label)", symbol: "exclamationmark.triangle.fill")
                rebuild()
                return
            }
        }
        Shortcuts.set(shortcut, for: action)
        rebuild()   // shows any "in use by another app" result
    }

    @objc private func resetShortcuts() {
        Shortcuts.resetAll()
        rebuild()
    }

    @objc private func loginToggled(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = sender.state == .on ? .off : .on
            NSAlert(error: error).runModal()
        }
    }
}

/// Click to record: shows "Press keys…", takes the next combination with ⌃, ⌥ or ⌘.
/// SnapLite's own hotkeys are paused while recording and always resumed when it ends.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? {
        didSet { updateTitle() }
    }
    var onChange: ((Shortcut?) -> Void)?
    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            if recording { HotKeyCenter.shared.suspend() } else { HotKeyCenter.shared.resume() }
            updateTitle()
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    private func updateTitle() {
        title = recording ? "Press keys…" : shortcut?.display ?? "None"
    }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    /// Ends recording first (resuming hotkeys), then reports, so re-registration sees them active.
    private func finish(_ result: Shortcut??) {
        recording = false
        guard let result else { return }   // cancelled
        shortcut = result
        onChange?(result)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: finish(nil)                       // Esc cancels
        case 51, 117: finish(.some(nil))           // Delete clears
        default:
            if let new = Shortcut(event: event) { finish(.some(new)) } else { NSSound.beep() }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)   // ⌘ combinations arrive here instead of keyDown
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { recording = false }   // the row was rebuilt or the window closed
        super.viewWillMove(toWindow: newWindow)
    }
}

/// The editor's tools, with the Swift app's raw values (stored in "toolbarTools"); the Flutter editor reads the same list.
enum Tool: Int, CaseIterable {
    case select, arrow, line, box, ellipse, pen, highlight, text, callout, step, blur, spotlight, crop, grabText

    var label: String {
        ["Select", "Arrow", "Line", "Shape", "Ellipse", "Pen", "Highlight", "Text", "Callout", "Step", "Blur", "Spotlight", "Crop",
         "Copy Text"][rawValue]
    }
}
