import AppKit
import ServiceManagement

/// UserDefaults keys shared by the menu bar menu and the Settings window.
enum Prefs {
    static let openEditor = "openEditorAfterCapture"
    static let copyImage = "copyAfterCapture"
    static let microphone = "recordMicrophone"
    /// Format Save As starts on; empty means the last one used.
    static let saveAsFormat = "saveAs.defaultFormat"
    /// Animated GIF frames a second ("15", "25" or "50"); the editor reads it each time it makes a GIF.
    static let gifFps = "gifFps"
    static let gifFpsChoices = ["50", "25", "15"]
    /// Area capture re-offers the last region (outlined; Enter or a click inside re-captures it). Default on.
    static let rememberArea = "regionCapture.rememberArea"

    /// A bool pref that defaults to true when it has never been set (plain `bool(forKey:)` would read false).
    static func onByDefault(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
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
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SnapNow Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: Theme.changed, object: nil)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        rebuild()
        NSApp.activate()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func rebuild() {
        guard let window else { return }
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
        stack.addArrangedSubview(checkbox("Remember the last capture area (Enter re-captures it)", on: Prefs.onByDefault(Prefs.rememberArea),
                                          action: #selector(prefToggled(_:)), key: Prefs.rememberArea))
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

        // Shortcuts
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Shortcuts"))
        stack.addArrangedSubview(note("Click a shortcut, then press the new keys (with ⌃, ⌥ or ⌘). Delete clears it, Esc cancels."))
        let keys = NSGridView(numberOfColumns: 3, rows: 0)
        keys.rowSpacing = 6
        keys.columnSpacing = 12
        for action in ShortcutAction.allCases {
            let what = NSTextField(labelWithString: action.label)
            what.font = Theme.font(12)
            what.textColor = Theme.dimText
            let recorder = ShortcutRecorder()
            recorder.widthAnchor.constraint(equalToConstant: 110).isActive = true
            recorder.shortcut = Shortcuts.get(action)
            recorder.onChange = { [weak self] new in self?.shortcutChanged(new, for: action) }
            let status = NSTextField(labelWithString: Shortcuts.failed.contains(action) ? "⚠︎ in use by another app" : "")
            status.font = Theme.font(11)
            status.textColor = .systemOrange
            keys.addRow(with: [what, recorder, status])
        }
        keys.column(at: 1).width = 120
        stack.addArrangedSubview(keys)
        let resetKeys = NSButton(title: "Reset Shortcuts", target: self, action: #selector(resetShortcuts))
        resetKeys.bezelStyle = .rounded
        stack.addArrangedSubview(resetKeys)

        let content = Theme.makeBackdrop()
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
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

    /// Rejects reserved and duplicate combinations; otherwise saves, which re-registers the hotkeys.
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
