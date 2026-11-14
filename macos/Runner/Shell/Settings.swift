import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// UserDefaults keys shared by the menu bar menu and the Settings window.
/// How draw mode's glass goes when it is lifted: each mark flies into the menu bar icon in turn, newest first (default); the
/// whole drawing flies there at once; or it just goes. Nothing drawn: it just goes, whichever is chosen.
enum DrawClose: String, CaseIterable {
    case fade, fly, off
    var title: String {
        switch self {
        case .fade: return "One by one (each mark flies into the menu bar icon in turn)"
        case .fly: return "All at once (the drawing flies into the menu bar icon)"
        case .off: return "None"
        }
    }
    static var current: DrawClose {
        if let v = UserDefaults.standard.string(forKey: Prefs.liveDrawClose), let c = DrawClose(rawValue: v) { return c }
        return Prefs.onByDefault(Prefs.liveDrawCloseAnimation) ? .fade : .off
    }
}

/// How fast "One by one" sends the marks into the menu bar icon (Settings › Draw mode › Speed), read each time the glass is
/// lifted and passed to the editor with drawFadeOut. The pace itself lives in Dart (DrawCloseSpeed in editor_page.dart, same
/// names); Fast is the pace before there was a choice. With Reduce Motion the marks only fade, at the Fast pace.
enum DrawCloseSpeed: String, CaseIterable {
    case fast, normal, relaxed, slow
    var title: String {
        switch self {
        case .fast: return "Fast (350 ms a mark, 110 ms apart, at most 1.3 s)"
        case .normal: return "Normal (520 ms a mark, 190 ms apart, at most 2.2 s)"
        case .relaxed: return "Relaxed (700 ms a mark, 270 ms apart, at most 3 s)"
        case .slow: return "Slow (950 ms a mark, 380 ms apart, at most 4.2 s)"
        }
    }
    /// Seconds LiveDraw.leave waits for the editor to say the last mark is gone: this choice's cap in Dart plus room for a
    /// busy main thread (Fast: the 2 s of before). test/draw_fade_out_test.dart reads these lines and checks them.
    var wait: TimeInterval {
        switch self {
        case .fast: return 2.0
        case .normal: return 3.2
        case .relaxed: return 4.0
        case .slow: return 5.2
        }
    }
    static var current: DrawCloseSpeed {
        UserDefaults.standard.string(forKey: Prefs.liveDrawCloseSpeed).flatMap(DrawCloseSpeed.init(rawValue:)) ?? .normal
    }
}

enum Prefs {
    static let openEditor = "openEditorAfterCapture"
    static let copyImage = "copyAfterCapture"
    static let microphone = "recordMicrophone"
    static let systemAudio = "recordSystemAudio"            // on by default: the computer's sound goes into recordings
    static let transcribe = "transcribeRecordings"          // on by default: a transcript after every recording
    static let transcriptLanguage = "transcriptLanguage"    // a language identifier; empty = the system language
    /// Option+click anywhere shows the pointing hand (same as my browser automation). Default on.
    static let altClickHand = "altClickHand"
    /// Double-tap Option freezes the screen and opens it full-screen in the editor for drawing (session mode). Default on.
    static let liveDraw = "liveDrawMode"
    /// Glass level of draw mode's toolbar and panel, in percent: 100 clear frosted glass ... 0 solid. Default 100.
    static let liveDrawGlass = "liveDrawGlass"
    /// Before 1.82.6: lifting draw mode flies the markup into the menu bar icon, on/off. Read only when liveDrawClose is unset (off → DrawClose.off).
    static let liveDrawCloseAnimation = "liveDrawCloseAnimation"
    /// How the glass goes when draw mode is lifted (DrawClose raw value; Settings › Draw mode › Closing).
    static let liveDrawClose = "liveDrawClose"
    /// How fast "One by one" goes (DrawCloseSpeed raw value; Settings › Draw mode › Speed). Unset = normal.
    static let liveDrawCloseSpeed = "liveDrawCloseSpeed"
    /// The Matrix rain's shortcut (Settings › Shortcuts, default ⌃⌥⇧⌘M) is live. Default on. The menu item works either way.
    static let matrixRain = "matrixRain"
    static let glassChoices: [(label: String, value: Int)] = [("100% glass (clear)", 100), ("75% glass", 75), ("50% glass", 50),
                                                                 ("25% glass", 25), ("0% (solid)", 0)]
    static var glassLevel: Int {
        let v = UserDefaults.standard.string(forKey: liveDrawGlass).flatMap(Int.init) ?? 100
        return glassChoices.map(\.value).contains(v) ? v : 100
    }
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
    /// Settings › Draw mode › Speed: only meaningful (enabled) while Closing is "One by one".
    private weak var closingSpeed: NSPopUpButton?

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
        // Settings › Defaults: values applied from another Mac, and the group's status line
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildIfShown), name: PublishDefaults.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildIfShown), name: PublishDefaults.statusChanged, object: nil)
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

        // Draw mode (double-tap Option)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Draw mode"))
        let glass = NSPopUpButton(frame: .zero, pullsDown: false)
        glass.addItems(withTitles: Prefs.glassChoices.map { $0.label })
        glass.selectItem(at: Prefs.glassChoices.firstIndex { $0.value == Prefs.glassLevel } ?? 0)
        glass.target = self
        glass.action = #selector(glassChosen(_:))
        stack.addArrangedSubview(row("Glass", glass))
        let closing = NSPopUpButton(frame: .zero, pullsDown: false)
        closing.addItems(withTitles: DrawClose.allCases.map(\.title))
        closing.selectItem(at: DrawClose.allCases.firstIndex(of: DrawClose.current) ?? 0)
        closing.target = self
        closing.action = #selector(drawCloseChosen(_:))
        stack.addArrangedSubview(row("Closing", closing))
        let speed = NSPopUpButton(frame: .zero, pullsDown: false)
        speed.addItems(withTitles: DrawCloseSpeed.allCases.map(\.title))
        speed.selectItem(at: DrawCloseSpeed.allCases.firstIndex(of: DrawCloseSpeed.current) ?? 1)
        speed.target = self
        speed.action = #selector(drawCloseSpeedChosen(_:))
        speed.isEnabled = DrawClose.current == .fade
        closingSpeed = speed
        stack.addArrangedSubview(row("Speed", speed))
        stack.addArrangedSubview(note("Speed paces One by one; many marks come closer together. Reduce Motion: they just fade."))
        stack.addArrangedSubview(checkbox("Matrix rain (\(Shortcuts.get(.matrix)?.display ?? "no shortcut"); change it under Shortcuts)",
                                          on: Prefs.onByDefault(Prefs.matrixRain),
                                          action: #selector(prefToggled(_:)), key: Prefs.matrixRain))
        stack.addArrangedSubview(note("Double-tap Option lays this over your screen to draw on. 100% is clear frosted glass; lower values tint the toolbar and panel, down to solid."))

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
        stack.addArrangedSubview(checkbox("Record the computer's sound with screen recordings", on: Prefs.onByDefault(Prefs.systemAudio),
                                          action: #selector(prefToggled(_:)), key: Prefs.systemAudio))
        let quality = NSPopUpButton(frame: .zero, pullsDown: false)
        quality.addItems(withTitles: RecordingQuality.allCases.map(\.title))
        quality.selectItem(at: RecordingQuality.allCases.firstIndex(of: RecordingQuality.current) ?? 1)
        quality.target = self
        quality.action = #selector(recordingQualityChosen(_:))
        stack.addArrangedSubview(row("Recording quality", quality))
        stack.addArrangedSubview(note("Recordings are HEVC. Standard keeps screen text sharp at about a gigabyte an hour or less; High keeps more detail, Small the least."))
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

        // Transcripts
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Transcripts"))
        stack.addArrangedSubview(checkbox("Transcribe screen recordings", on: Prefs.onByDefault(Prefs.transcribe),
                                          action: #selector(prefToggled(_:)), key: Prefs.transcribe))
        let language = NSPopUpButton(frame: .zero, pullsDown: false)
        language.target = self
        language.action = #selector(transcriptLanguageChosen(_:))
        fillLanguages(language)
        stack.addArrangedSubview(row("Language", language))
        stack.addArrangedSubview(note("Made on this Mac only: the sound never leaves it (a language's speech model may come from Apple once). "
            + "A .txt with [mm:ss] lines and .srt captions go next to the movie. Older movies: right-click in the Library › Make Transcript."))

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

        // Defaults: the same drawing and capture defaults on every Mac (PublishDefaults)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Defaults"))
        let sync = PublishDefaults.shared
        let hasFolder = sync.folder != nil
        let folderName = NSTextField(labelWithString: sync.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "None (off)")
        folderName.font = Theme.font(12)
        folderName.textColor = Theme.dimText
        folderName.lineBreakMode = .byTruncatingMiddle
        folderName.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        let chooseFolder = NSButton(title: "Choose…", target: self, action: #selector(chooseDefaultsFolder))
        chooseFolder.bezelStyle = .rounded
        let clearFolder = NSButton(title: "Clear", target: self, action: #selector(clearDefaultsFolder))
        clearFolder.bezelStyle = .rounded
        clearFolder.isEnabled = hasFolder
        let folderRow = NSStackView(views: [chooseFolder, clearFolder, folderName])
        folderRow.spacing = 8
        folderRow.alignment = .centerY
        stack.addArrangedSubview(row("Shared defaults folder", folderRow))
        let publishButton = NSButton(title: "Publish my defaults", target: self, action: #selector(publishDefaults))
        publishButton.bezelStyle = .rounded
        publishButton.isEnabled = hasFolder
        let applyButton = NSButton(title: "Apply now", target: self, action: #selector(applyDefaultsNow))
        applyButton.bezelStyle = .rounded
        applyButton.isEnabled = hasFolder
        let buttons = NSStackView(views: [publishButton, applyButton])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        let autoApply = checkbox("Apply published defaults from other Macs automatically", on: sync.autoApply,
                                 action: #selector(defaultsAutoApplyToggled(_:)))
        autoApply.isEnabled = hasFolder
        stack.addArrangedSubview(autoApply)
        let status = NSTextField(wrappingLabelWithString: sync.statusLine)
        status.font = Theme.font(12)
        status.textColor = Theme.dimText
        status.preferredMaxLayoutWidth = 472
        status.widthAnchor.constraint(equalToConstant: 472).isActive = true
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(note("Every setting, shortcuts included. Not: screen places, permission prompts, this group. Home folders as ~/…"))

        // Shortcuts
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Shortcuts"))
        stack.addArrangedSubview(note("Click a shortcut, then press the new keys (with ⌃, ⌥ or ⌘; Matrix rain also takes ⇧+key or a bare key). Delete clears it, Esc cancels."))
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
            recorder.allowsPlain = action == .matrix
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
            if action == .matrix {                       // which of the two ways the rain's key works
                let mode = Shortcuts.get(.matrix).map { $0.matrixTrigger } ?? .off
                let hint = NSTextField(labelWithString: mode.hint)
                hint.font = Theme.font(11)
                hint.textColor = Theme.muted
                let indent = NSView()
                indent.widthAnchor.constraint(equalToConstant: 30).isActive = true
                let hintRow = NSStackView(views: [indent, hint])
                hintRow.spacing = 0
                keys.addArrangedSubview(hintRow)
            }
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

    @objc private func drawCloseChosen(_ sender: NSPopUpButton) {
        let close = DrawClose.allCases[sender.indexOfSelectedItem]
        UserDefaults.standard.set(close.rawValue, forKey: Prefs.liveDrawClose)
        closingSpeed?.isEnabled = close == .fade
    }

    @objc private func drawCloseSpeedChosen(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(DrawCloseSpeed.allCases[sender.indexOfSelectedItem].rawValue, forKey: Prefs.liveDrawCloseSpeed)
    }

    @objc private func glassChosen(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(String(Prefs.glassChoices[sender.indexOfSelectedItem].value), forKey: Prefs.liveDrawGlass)
    }

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

    /// The system language first, then every language this Mac can transcribe on-device (added when known).
    private func fillLanguages(_ popup: NSPopUpButton) {
        let chosen = UserDefaults.standard.string(forKey: Prefs.transcriptLanguage) ?? ""
        func add(_ title: String, _ id: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = id
            popup.menu?.addItem(item)
            if id == chosen { popup.select(item) }
        }
        add("System (\(TranscriptEngine.displayName(TranscriptEngine.systemLanguage)))", "")
        if !chosen.isEmpty { add(TranscriptEngine.displayName(chosen), chosen) }
        Task { @MainActor in
            for id in await TranscriptEngine.supportedLanguages() where id != chosen { add(TranscriptEngine.displayName(id), id) }
        }
    }

    @objc private func transcriptLanguageChosen(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.selectedItem?.representedObject as? String ?? "", forKey: Prefs.transcriptLanguage)
    }

    @objc private func prefToggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
        if key == Prefs.matrixRain { NotificationCenter.default.post(name: Shortcuts.changed, object: nil) }   // re-registers at once
    }

    @objc private func saveAsFormatChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        UserDefaults.standard.set(index > 0 ? sender.titleOfSelectedItem : "", forKey: Prefs.saveAsFormat)
    }

    @objc private func recordingQualityChosen(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(RecordingQuality.allCases[sender.indexOfSelectedItem].rawValue, forKey: RecordingQuality.prefKey)
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

    // MARK: Defaults

    @objc private func rebuildIfShown() {
        if window?.isVisible == true { rebuild() }
    }

    @objc private func chooseDefaultsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "A folder all your Macs can reach: iCloud Drive, a synced folder or a network folder."
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PublishDefaults.shared.folder = url
        rebuild()
    }

    @objc private func clearDefaultsFolder() {
        PublishDefaults.shared.folder = nil
        rebuild()
    }

    @objc private func publishDefaults() { PublishDefaults.shared.publish() }

    @objc private func applyDefaultsNow() { PublishDefaults.shared.check(force: true) }

    @objc private func defaultsAutoApplyToggled(_ sender: NSButton) {
        PublishDefaults.shared.autoApply = sender.state == .on
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
    /// Also accept a bare key or ⇧+key (the Matrix rain's row; everywhere else they would fire while typing).
    var allowsPlain = false
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
            if let new = Shortcut(event: event, allowPlain: allowsPlain) { finish(.some(new)) } else { NSSound.beep() }
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
