import AppKit

enum CaptureTab: String, Codable, CaseIterable {
    case allInOne, image, video, text

    var label: String { ["Area", "Image", "Video", "Text"][CaptureTab.allCases.firstIndex(of: self)!] }
    var symbol: String { ["record.circle", "camera.fill", "video.fill", "text.viewfinder"][CaptureTab.allCases.firstIndex(of: self)!] }
}

enum ImageSelection: String, Codable, CaseIterable {
    case region, window, fullScreen

    var label: String { ["Region", "Window", "Full Screen"][ImageSelection.allCases.firstIndex(of: self)!] }
}

enum VideoSelection: String, Codable, CaseIterable {
    case region, fullScreen

    var label: String { ["Region", "Full Screen"][VideoSelection.allCases.firstIndex(of: self)!] }
}

/// Applied to image captures only (Area, Window, Screen).
enum CaptureEffect: String, Codable, CaseIterable {
    case none, border, shadow, borderShadow

    var label: String { ["None", "Border", "Shadow", "Border + Shadow"][CaptureEffect.allCases.firstIndex(of: self)!] }
}

/// Applied to image captures only (Area, Window, Screen).
enum CaptureShare: String, Codable, CaseIterable {
    case none, desktop, finder, preview

    var label: String {
        ["None", "Save a Copy to Desktop", "Show in Finder", "Open in Preview"][CaptureShare.allCases.firstIndex(of: self)!]
    }
}

/// Everything the capture panel controls. Presets are saved copies of this.
struct CaptureConfig: Codable, Equatable {
    var tab = CaptureTab.allInOne
    var imageSelection = ImageSelection.region
    var videoSelection = VideoSelection.region
    var effect = CaptureEffect.none
    var share = CaptureShare.none
    var openEditor = true
    var copyToClipboard = false
    var cursor = false              // full-screen image captures only (screencapture -C)
    var delayOn = false
    var delaySeconds = 5
    var microphone = false
    var showClicks = true
    var openVideoWhenDone = true
    var windowShadow = false        // Selection ⚙: keep the shadow on window captures
    var captureSound = false        // Selection ⚙: play the camera sound

    init() {}

    /// Missing keys (settings saved by an older version) fall back to the defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureConfig()
        tab = try c.decodeIfPresent(CaptureTab.self, forKey: .tab) ?? d.tab
        imageSelection = try c.decodeIfPresent(ImageSelection.self, forKey: .imageSelection) ?? d.imageSelection
        videoSelection = try c.decodeIfPresent(VideoSelection.self, forKey: .videoSelection) ?? d.videoSelection
        effect = try c.decodeIfPresent(CaptureEffect.self, forKey: .effect) ?? d.effect
        share = try c.decodeIfPresent(CaptureShare.self, forKey: .share) ?? d.share
        openEditor = try c.decodeIfPresent(Bool.self, forKey: .openEditor) ?? d.openEditor
        copyToClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? d.copyToClipboard
        cursor = try c.decodeIfPresent(Bool.self, forKey: .cursor) ?? d.cursor
        delayOn = try c.decodeIfPresent(Bool.self, forKey: .delayOn) ?? d.delayOn
        delaySeconds = try c.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? d.delaySeconds
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? d.microphone
        showClicks = try c.decodeIfPresent(Bool.self, forKey: .showClicks) ?? d.showClicks
        openVideoWhenDone = try c.decodeIfPresent(Bool.self, forKey: .openVideoWhenDone) ?? d.openVideoWhenDone
        windowShadow = try c.decodeIfPresent(Bool.self, forKey: .windowShadow) ?? d.windowShadow
        captureSound = try c.decodeIfPresent(Bool.self, forKey: .captureSound) ?? d.captureSound
    }

    private static let key = "captureConfig"
    private static let presetsKey = "capturePresets"

    /// The saved configuration. The menu and Settings toggles (editor, clipboard, microphone) stay in step via Prefs.
    static var current: CaptureConfig {
        get {
            var config = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(CaptureConfig.self, from: $0) }
                ?? CaptureConfig()
            let defaults = UserDefaults.standard
            config.openEditor = defaults.bool(forKey: Prefs.openEditor)
            config.copyToClipboard = defaults.bool(forKey: Prefs.copyImage)
            config.microphone = defaults.bool(forKey: Prefs.microphone)
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
            let defaults = UserDefaults.standard
            defaults.set(newValue.openEditor, forKey: Prefs.openEditor)
            defaults.set(newValue.copyToClipboard, forKey: Prefs.copyImage)
            defaults.set(newValue.microphone, forKey: Prefs.microphone)
        }
    }

    /// Cursor capture only works for non-interactive (full screen) captures.
    var cursorAvailable: Bool { tab == .image && imageSelection == .fullScreen }

    /// The global shortcut that does what the Capture button does.
    var shortcutAction: ShortcutAction {
        switch tab {
        case .allInOne: return .region
        case .image:
            switch imageSelection {
            case .region: return .region
            case .window: return .window
            case .fullScreen: return .screen
            }
        case .video: return .record
        case .text: return .text
        }
    }

    static var presets: [(name: String, config: CaptureConfig)] {
        get {
            let stored = UserDefaults.standard.data(forKey: presetsKey)
                .flatMap { try? JSONDecoder().decode([NamedConfig].self, from: $0) } ?? []
            return stored.map { ($0.name, $0.config) }
        }
        set {
            let stored = newValue.map { NamedConfig(name: $0.name, config: $0.config) }
            if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: presetsKey) }
        }
    }

    private struct NamedConfig: Codable {
        var name: String
        var config: CaptureConfig
    }
}

extension Renderer {
    /// Rewrites the PNG at `url` with a border and/or a drop shadow (shadow adds transparent padding).
    static func applyEffect(_ effect: CaptureEffect, to url: URL) {
        // Decode from memory: the same file is rewritten below, and ImageIO reads lazily
        guard effect != .none, let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
        let image = NSImage(contentsOf: url)
        let scale = CGFloat(cg.width) / max(image?.size.width ?? CGFloat(cg.width), 1)
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let shadow = effect == .shadow || effect == .borderShadow
        let pad = shadow ? 24 * scale : 0
        guard let ctx = CGContext(data: nil, width: Int(w + pad * 2), height: Int(h + pad * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let frame = CGRect(x: pad, y: pad, width: w, height: h)
        if shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 18 * scale, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(frame)
            ctx.restoreGState()
        }
        ctx.draw(cg, in: frame)
        if effect == .border || effect == .borderShadow {
            let line = 2 * scale
            ctx.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
            ctx.setLineWidth(line)
            ctx.stroke(frame.insetBy(dx: line / 2, dy: line / 2))
        }
        guard let output = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: output)
        rep.size = NSSize(width: (w + pad * 2) / scale, height: (h + pad * 2) / scale)   // keep Retina dpi
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }
}

/// The capture modes shown as chips. They map onto the saved `CaptureConfig` fields, so older settings
/// and presets keep working: Area is region capture (Space switches to window picking).
enum PanelMode: CaseIterable {
    case area, window, screen, video, text

    var label: String { ["Area", "Window", "Screen", "Video", "Text"][PanelMode.allCases.firstIndex(of: self)!] }
    var symbol: String {
        ["viewfinder", "macwindow", "display", "record.circle", "text.viewfinder"][PanelMode.allCases.firstIndex(of: self)!]
    }
}

extension CaptureConfig {
    var mode: PanelMode {
        get {
            switch tab {
            case .allInOne: return .area
            case .image:
                switch imageSelection {
                case .region: return .area
                case .window: return .window
                case .fullScreen: return .screen
                }
            case .video: return .video
            case .text: return .text
            }
        }
        set {
            switch newValue {
            case .area: tab = .allInOne
            case .window: tab = .image; imageSelection = .window
            case .screen: tab = .image; imageSelection = .fullScreen
            case .video: tab = .video
            case .text: tab = .text
            }
        }
    }
}

/// The capture panel shown from the menu bar icon: mode chips, a shutter button, option chips and a footer.
final class CapturePanelController: NSViewController, NSMenuDelegate {
    var onCapture: ((CaptureConfig) -> Void)?
    var onOpenLibrary: (() -> Void)?
    var gearMenu: NSMenu?

    private var config = CaptureConfig.current
    private let modes = NSStackView()
    private let options = NSStackView()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let presetsMenu = NSMenu()
    private let shutter = ShutterButton()

    override func loadView() {
        let root = FillView(.surface)   // clear in Glass: the popover's own frosted material shows
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 428).isActive = true

        modes.spacing = 4
        options.orientation = .vertical
        options.alignment = .centerX
        options.spacing = 6

        shutter.target = self
        shutter.action = #selector(captureClicked)
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.alignment = .center
        hint.font = Theme.font(11)
        hint.alignment = .center

        let presets = ThemedButton(symbol: "slider.horizontal.3", label: "Presets", target: self, action: #selector(showPresets(_:)))
        presets.fontSize = 12
        presetsMenu.delegate = self
        let library = ThemedButton(symbol: "photo.on.rectangle.angled", target: self, action: #selector(openLibrary))
        library.toolTip = "Library"
        let gear = ThemedButton(symbol: "gearshape", target: self, action: #selector(showGear(_:)))
        gear.toolTip = "Settings and more"
        let footerLine = FillView(.border)
        let footer = NSStackView()
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        footer.addView(presets, in: .leading)
        footer.addView(library, in: .trailing)
        footer.addView(gear, in: .trailing)

        for view in [modes, shutter, shortcutLabel, options, hint, footerLine, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            modes.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            modes.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            shutter.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 16),
            shutter.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            shortcutLabel.topAnchor.constraint(equalTo: shutter.bottomAnchor, constant: 4),
            shortcutLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            options.topAnchor.constraint(equalTo: shortcutLabel.bottomAnchor, constant: 14),
            options.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hint.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 8),
            hint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            footerLine.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            footerLine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footerLine.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footerLine.heightAnchor.constraint(equalToConstant: 1),
            footer.topAnchor.constraint(equalTo: footerLine.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: Theme.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: Shortcuts.changed, object: nil)
    }

    /// Re-reads the saved settings (the menu or Settings may have changed them) and redraws.
    func reload() {
        config = CaptureConfig.current
        rebuild()
    }

    private func save() {
        CaptureConfig.current = config
        rebuild()
    }

    // MARK: - Building

    @objc private func rebuild() {
        guard isViewLoaded else { return }
        modes.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for mode in PanelMode.allCases {
            let chip = makeChip(mode.label, symbol: mode.symbol, on: config.mode == mode, filled: true, action: #selector(modeClicked(_:)))
            chip.tag = PanelMode.allCases.firstIndex(of: mode)!
            modes.addArrangedSubview(chip)
        }

        options.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var rows: [[NSView]] = []
        switch config.mode {
        case .area, .window, .screen:
            rows.append([toggleChip("Copy", "doc.on.doc", config.copyToClipboard, tag: 2),
                         toggleChip("Edit", "pencil.and.outline", config.openEditor, tag: 1),
                         menuChip(delayLabel, "timer", #selector(showDelay(_:)), on: config.delayOn)])
            rows.append([menuChip(config.effect == .none ? "Effect" : config.effect.label, "sparkles", #selector(showEffects(_:)),
                                  on: config.effect != .none),
                         menuChip(config.share == .none ? "Share" : shortShare, "square.and.arrow.up", #selector(showShare(_:)),
                                  on: config.share != .none),
                         menuChip("More", "ellipsis", #selector(showMore(_:)), on: false)])
            hint.stringValue = config.mode == .area ? "Drag an area, or press Space to pick a window." : ""
        case .video:
            rows.append([menuChip(config.videoSelection == .fullScreen ? "Full Screen" : "Area", "rectangle.dashed",
                                  #selector(showVideoArea(_:)), on: false),
                         toggleChip("Mic", "mic", config.microphone, tag: 4),
                         toggleChip("Clicks", "cursorarrow.click", config.showClicks, tag: 5)])
            rows.append([toggleChip("Open after", "play.rectangle", config.openVideoWhenDone, tag: 6),
                         menuChip(delayLabel, "timer", #selector(showDelay(_:)), on: config.delayOn)])
            hint.stringValue = "Saved as .mov in the Library; right-click one there to make a GIF."
        case .text:
            rows.append([menuChip(delayLabel, "timer", #selector(showDelay(_:)), on: config.delayOn)])
            hint.stringValue = "Select an area: its text is copied. Table columns become tabs."
        }
        for row in rows {
            let stack = NSStackView(views: row)
            stack.spacing = 6
            options.addArrangedSubview(stack)
        }
        hint.textColor = Theme.muted
        hint.isHidden = hint.stringValue.isEmpty

        shutter.recording = config.mode == .video
        shortcutLabel.stringValue = Shortcuts.get(config.shortcutAction)?.display ?? ""
        shortcutLabel.textColor = Theme.muted
        Theme.refresh(view)
    }

    private var delayLabel: String { config.delayOn ? "\(config.delaySeconds)s delay" : "No delay" }

    private var shortShare: String {
        switch config.share {
        case .none: return "Share"
        case .desktop: return "To Desktop"
        case .finder: return "In Finder"
        case .preview: return "In Preview"
        }
    }

    private func makeChip(_ title: String, symbol: String, on: Bool, filled: Bool, action: Selector) -> ThemedButton {
        let chip = ThemedButton(symbol: symbol, label: title, target: self, action: action)
        chip.chip = true
        chip.chipFilled = filled
        chip.isActive = on
        chip.fontSize = 12
        chip.iconBox = NSSize(width: 14, height: 14)
        let width = (title as NSString).size(withAttributes: [.font: Theme.font(12)]).width + 40
        chip.fixedSize = NSSize(width: ceil(width), height: 28)
        return chip
    }

    private func toggleChip(_ title: String, _ symbol: String, _ on: Bool, tag: Int) -> ThemedButton {
        let chip = makeChip(title, symbol: symbol, on: on, filled: false, action: #selector(toggleClicked(_:)))
        chip.tag = tag
        chip.toolTip = on ? "On" : "Off"
        return chip
    }

    private func menuChip(_ title: String, _ symbol: String, _ action: Selector, on: Bool) -> ThemedButton {
        makeChip(title + " ▾", symbol: symbol, on: on, filled: false, action: action)
    }

    private func popUp(_ menu: NSMenu, under view: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 2 : -2), in: view)
    }

    private func menu(_ items: [(String, Bool, Int, Bool)], action: Selector) -> NSMenu {
        let menu = NSMenu()
        for (title, on, tag, enabled) in items {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.state = on ? .on : .off
            item.tag = tag
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Actions

    @objc private func modeClicked(_ sender: NSButton) {
        config.mode = PanelMode.allCases[sender.tag]
        save()
    }

    @objc private func toggleClicked(_ sender: NSButton) {
        switch sender.tag {
        case 1: config.openEditor.toggle()
        case 2: config.copyToClipboard.toggle()
        case 4: config.microphone.toggle()
        case 5: config.showClicks.toggle()
        case 6: config.openVideoWhenDone.toggle()
        default: break
        }
        save()
    }

    @objc private func showDelay(_ sender: NSButton) {
        let items = [("No delay", !config.delayOn, 0, true)] + [3, 5, 10].map { ("\($0) seconds", config.delayOn && config.delaySeconds == $0, $0, true) }
        popUp(menu(items, action: #selector(delayChosen(_:))), under: sender)
    }

    @objc private func delayChosen(_ sender: NSMenuItem) {
        config.delayOn = sender.tag > 0
        if sender.tag > 0 { config.delaySeconds = sender.tag }
        save()
    }

    @objc private func showEffects(_ sender: NSButton) {
        let items = CaptureEffect.allCases.enumerated().map { ($0.element.label, config.effect == $0.element, $0.offset, true) }
        popUp(menu(items, action: #selector(effectChosen(_:))), under: sender)
    }

    @objc private func effectChosen(_ sender: NSMenuItem) {
        config.effect = CaptureEffect.allCases[sender.tag]
        save()
    }

    @objc private func showShare(_ sender: NSButton) {
        let items = CaptureShare.allCases.enumerated().map { ($0.element.label, config.share == $0.element, $0.offset, true) }
        popUp(menu(items, action: #selector(shareChosen(_:))), under: sender)
    }

    @objc private func shareChosen(_ sender: NSMenuItem) {
        config.share = CaptureShare.allCases[sender.tag]
        save()
    }

    @objc private func showVideoArea(_ sender: NSButton) {
        let items = [("Drag an Area", config.videoSelection == .region, 0, true), ("Full Screen", config.videoSelection == .fullScreen, 1, true)]
        popUp(menu(items, action: #selector(videoAreaChosen(_:))), under: sender)
    }

    @objc private func videoAreaChosen(_ sender: NSMenuItem) {
        config.videoSelection = sender.tag == 1 ? .fullScreen : .region
        save()
    }

    /// Less-used options: cursor (full-screen captures only), window shadow, capture sound, reset.
    @objc private func showMore(_ sender: NSButton) {
        let menu = self.menu([("Include Cursor (Screen only)", config.cursor, 1, config.cursorAvailable),
                              ("Include Window Shadow", config.windowShadow, 2, true),
                              ("Play Capture Sound", config.captureSound, 3, true)], action: #selector(moreChosen(_:)))
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Capture Options", action: #selector(resetClicked), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        popUp(menu, under: sender)
    }

    @objc private func moreChosen(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: config.cursor.toggle()
        case 2: config.windowShadow.toggle()
        case 3: config.captureSound.toggle()
        default: break
        }
        save()
    }

    /// Back to the defaults, keeping the chosen mode.
    @objc private func resetClicked() {
        let mode = config.mode
        config = CaptureConfig()
        config.mode = mode
        save()
    }

    @objc private func captureClicked() {
        onCapture?(config)
    }

    @objc private func openLibrary() {
        onOpenLibrary?()
    }

    @objc private func showGear(_ sender: NSButton) {
        if let gearMenu { popUp(gearMenu, under: sender) }
    }

    // MARK: - Presets

    @objc private func showPresets(_ sender: NSButton) {
        popUp(presetsMenu, under: sender)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === presetsMenu else { return }
        menu.removeAllItems()
        let presets = CaptureConfig.presets
        for (i, preset) in presets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = preset.config == config ? .on : .off
            menu.addItem(item)
        }
        if presets.isEmpty {
            let empty = NSMenuItem(title: "No presets yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let save = NSMenuItem(title: "Save Current Settings as Preset…", action: #selector(savePreset), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        if !presets.isEmpty {
            let delete = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            delete.submenu = NSMenu()
            for (i, preset) in presets.enumerated() {
                let item = NSMenuItem(title: preset.name, action: #selector(deletePreset(_:)), keyEquivalent: "")
                item.tag = i
                item.target = self
                delete.submenu?.addItem(item)
            }
            menu.addItem(delete)
        }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        let presets = CaptureConfig.presets
        guard presets.indices.contains(sender.tag) else { return }
        config = presets[sender.tag].config
        save()
    }

    @objc private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Name these capture settings:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "\(config.mode.label) preset"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        CaptureConfig.saveOrReplacePreset(name: name, config: config)
        Toast.show("Saved preset “\(name)”", symbol: "star.fill")
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        var presets = CaptureConfig.presets
        guard presets.indices.contains(sender.tag) else { return }
        presets.remove(at: sender.tag)
        CaptureConfig.presets = presets
    }
}

extension CaptureConfig {
    /// Same name replaces the old preset.
    static func saveOrReplacePreset(name: String, config: CaptureConfig) {
        var list = presets.filter { $0.name != name }
        list.append((name, config))
        presets = list
    }
}

/// A camera-style shutter: a ring with a gap around a disk in the accent color.
final class ShutterButton: NSButton {
    /// Video mode: a red center, like a camera's record button.
    var recording = false {
        didSet { needsDisplay = true }
    }
    private var hovering = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        widthAnchor.constraint(equalToConstant: 76).isActive = true
        heightAnchor.constraint(equalToConstant: 76).isActive = true
        toolTip = "Capture"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        ring.lineWidth = 4
        Theme.text.withAlphaComponent(0.85).setStroke()
        ring.stroke()

        // The disk shrinks a little while pressed, like a real shutter
        let inset: CGFloat = isHighlighted ? 13 : 10
        let disk = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        let center = recording ? NSColor.systemRed : Theme.accent
        glow.shadowColor = center.withAlphaComponent(hovering ? 0.55 : 0.3)
        glow.shadowBlurRadius = hovering ? 10 : 5
        glow.set()
        (hovering ? center.blended(withFraction: 0.12, of: .white)! : center).setFill()
        disk.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
