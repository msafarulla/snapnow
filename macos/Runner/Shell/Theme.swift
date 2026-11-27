import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

enum AppearanceChoice: String, CaseIterable {
    case glass, system, light, dark, tokyoNight, dracula, nord, gruvbox, catppuccin, oneDark

    var label: String {
        switch self {
        case .glass: return "Glass"
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .tokyoNight: return "Tokyo Night"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .gruvbox: return "Gruvbox"
        case .catppuccin: return "Catppuccin"
        case .oneDark: return "One Dark"
        }
    }
}

struct Palette {
    var background: NSColor   // canvas
    var surface: NSColor      // toolbars, panels, window
    var raised: NSColor       // cards, hovered buttons
    var highlight: NSColor    // pressed buttons
    var border: NSColor
    var text: NSColor
    var dimText: NSColor
    var muted: NSColor
    var accent: NSColor
    var onAccent: NSColor
    var isDark: Bool
    var monospaced: Bool

    /// Light gray canvas, white bars, blue accent.
    static let light = Palette(background: NSColor(hex: 0xE6E6E9), surface: NSColor(hex: 0xF7F7F8), raised: NSColor(hex: 0xECECEF),
                               highlight: NSColor(hex: 0xE0E0E5), border: NSColor(hex: 0xD3D3D8), text: NSColor(hex: 0x26262A),
                               dimText: NSColor(hex: 0x55555C), muted: NSColor(hex: 0x8A8A92), accent: NSColor(hex: 0x2F7CF6),
                               onAccent: .white, isDark: false, monospaced: false)
    static let dark = Palette(background: NSColor(hex: 0x1C1C1E), surface: NSColor(hex: 0x2A2A2D), raised: NSColor(hex: 0x38383B),
                              highlight: NSColor(hex: 0x45454A), border: NSColor(hex: 0x3E3E42), text: NSColor(hex: 0xECECEE),
                              dimText: NSColor(hex: 0xB9B9BF), muted: NSColor(hex: 0x86868C), accent: NSColor(hex: 0x4D8EFF),
                              onAccent: .white, isDark: true, monospaced: false)
    /// Glass: clear surfaces over a frosted backdrop, system accent color. Text colors are solid for contrast.
    static let glassLight = Palette(background: NSColor(hex: 0xE4E4E8, alpha: 0.55), surface: .clear,
                                    raised: NSColor(white: 1, alpha: 0.55), highlight: NSColor(white: 0, alpha: 0.07),
                                    border: NSColor(white: 0, alpha: 0.10), text: NSColor(hex: 0x1D1D1F), dimText: NSColor(hex: 0x4A4A50),
                                    muted: NSColor(hex: 0x606066), accent: .controlAccentColor, onAccent: .white,
                                    isDark: false, monospaced: false)
    static let glassDark = Palette(background: NSColor(hex: 0x161618, alpha: 0.55), surface: .clear,
                                   raised: NSColor(white: 1, alpha: 0.08), highlight: NSColor(white: 1, alpha: 0.14),
                                   border: NSColor(white: 1, alpha: 0.12), text: NSColor(hex: 0xF5F5F7), dimText: NSColor(hex: 0xC7C7CC),
                                   muted: NSColor(hex: 0x9C9CA2), accent: .controlAccentColor, onAccent: .white,
                                   isDark: true, monospaced: false)
    /// Matches the Ghostty terminal (tokyonight + FiraMono).
    static let tokyoNight = Palette(background: NSColor(hex: 0x1A1B26), surface: NSColor(hex: 0x16161E), raised: NSColor(hex: 0x24283B),
                                    highlight: NSColor(hex: 0x292E42), border: NSColor(hex: 0x2F334D), text: NSColor(hex: 0xC0CAF5),
                                    dimText: NSColor(hex: 0xA9B1D6), muted: NSColor(hex: 0x565F89), accent: NSColor(hex: 0x7AA2F7),
                                    onAccent: NSColor(hex: 0x1A1B26), isDark: true, monospaced: true)
    static let dracula = Palette(background: NSColor(hex: 0x282A36), surface: NSColor(hex: 0x21222C), raised: NSColor(hex: 0x343746),
                                 highlight: NSColor(hex: 0x3C3F51), border: NSColor(hex: 0x44475A), text: NSColor(hex: 0xF8F8F2),
                                 dimText: NSColor(hex: 0xBCC0D8), muted: NSColor(hex: 0x6272A4), accent: NSColor(hex: 0xBD93F9),
                                 onAccent: NSColor(hex: 0x282A36), isDark: true, monospaced: false)
    static let nord = Palette(background: NSColor(hex: 0x2E3440), surface: NSColor(hex: 0x2B313B), raised: NSColor(hex: 0x3B4252),
                              highlight: NSColor(hex: 0x434C5E), border: NSColor(hex: 0x3B4252), text: NSColor(hex: 0xECEFF4),
                              dimText: NSColor(hex: 0xC0C8D8), muted: NSColor(hex: 0x6B7489), accent: NSColor(hex: 0x88C0D0),
                              onAccent: NSColor(hex: 0x2E3440), isDark: true, monospaced: false)
    static let gruvbox = Palette(background: NSColor(hex: 0x282828), surface: NSColor(hex: 0x1D2021), raised: NSColor(hex: 0x3C3836),
                                 highlight: NSColor(hex: 0x504945), border: NSColor(hex: 0x504945), text: NSColor(hex: 0xEBDBB2),
                                 dimText: NSColor(hex: 0xC4B596), muted: NSColor(hex: 0x928374), accent: NSColor(hex: 0xFE8019),
                                 onAccent: NSColor(hex: 0x282828), isDark: true, monospaced: false)
    static let catppuccin = Palette(background: NSColor(hex: 0x1E1E2E), surface: NSColor(hex: 0x181825), raised: NSColor(hex: 0x313244),
                                    highlight: NSColor(hex: 0x45475A), border: NSColor(hex: 0x313244), text: NSColor(hex: 0xCDD6F4),
                                    dimText: NSColor(hex: 0xBAC2DE), muted: NSColor(hex: 0x6C7086), accent: NSColor(hex: 0xCBA6F7),
                                    onAccent: NSColor(hex: 0x1E1E2E), isDark: true, monospaced: false)
    static let oneDark = Palette(background: NSColor(hex: 0x282C34), surface: NSColor(hex: 0x21252B), raised: NSColor(hex: 0x323842),
                                 highlight: NSColor(hex: 0x3E4451), border: NSColor(hex: 0x3E4451), text: NSColor(hex: 0xABB2BF),
                                 dimText: NSColor(hex: 0x9199A6), muted: NSColor(hex: 0x5C6370), accent: NSColor(hex: 0x61AFEF),
                                 onAccent: NSColor(hex: 0x282C34), isDark: true, monospaced: false)
}

/// The app's colors and font, chosen in Settings › Appearance. Views read these at draw time,
/// so posting `Theme.changed` and redrawing is enough to switch.
enum Theme {
    static let changed = Notification.Name("SnapLiteThemeChanged")
    private static let key = "appearance"

    static var choice: AppearanceChoice {
        get { AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .glass }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NSApp.appearance = appearance
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Glass, unless "Reduce transparency" is on (then solid Light/Dark).
    static var isGlass: Bool {
        choice == .glass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var palette: Palette {
        switch choice {
        case .glass:
            if !isGlass { return systemIsDark ? .dark : .light }
            return systemIsDark ? .glassDark : .glassLight
        case .light: return .light
        case .dark: return .dark
        case .tokyoNight: return .tokyoNight
        case .dracula: return .dracula
        case .nord: return .nord
        case .gruvbox: return .gruvbox
        case .catppuccin: return .catppuccin
        case .oneDark: return .oneDark
        case .system:
            return systemIsDark ? .dark : .light
        }
    }

    /// nil follows the system.
    static var appearance: NSAppearance? {
        switch choice {
        case .glass, .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark, .tokyoNight, .dracula, .nord, .gruvbox, .catppuccin, .oneDark: return NSAppearance(named: .darkAqua)
        }
    }

    static var background: NSColor { palette.background }
    static var surface: NSColor { palette.surface }
    static var raised: NSColor { palette.raised }
    static var highlight: NSColor { palette.highlight }
    static var border: NSColor { palette.border }
    static var text: NSColor { palette.text }
    static var dimText: NSColor { palette.dimText }
    static var muted: NSColor { palette.muted }
    static var accent: NSColor { palette.accent }
    static var onAccent: NSColor { palette.onAccent }

    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        if palette.monospaced,
           let fira = NSFontManager.shared.font(withFamily: "FiraMono Nerd Font Mono", traits: [], weight: 5, size: size) {
            return fira
        }
        return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    static func style(_ window: NSWindow) {
        window.appearance = appearance
        window.backgroundColor = isGlass ? .windowBackgroundColor : surface   // Glass: the backdrop view blurs
        window.titlebarAppearsTransparent = true
    }

    /// A window's root view: a frosted backdrop with a surface fill on top. The fill is clear in Glass
    /// (the blur shows) and solid in the other themes, so switching themes needs only a redraw.
    static func makeBackdrop() -> NSView {
        let blur = NSVisualEffectView()
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        let fill = FillView(.surface)
        fill.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            fill.topAnchor.constraint(equalTo: blur.topAnchor),
            fill.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    /// Redraws a view tree after a theme change.
    static func refresh(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(refresh)
    }
}

/// A flat, rounded button: icon and/or label, hover and pressed backgrounds, an "active" state
/// for the selected tool, a filled "primary" kind, and a vertical layout (icon over label) for the toolbar.
class ThemedButton: NSButton {
    enum Kind {
        case plain, primary
    }

    var kind = Kind.plain {
        didSet { needsDisplay = true }
    }
    var isActive = false {
        didSet { needsDisplay = true }
    }
    var vertical = false {
        didSet { invalidateIntrinsicContentSize() }
    }
    var icon: NSImage? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var label: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var fixedSize: NSSize?
    /// Vertical layout: the box the icon is fitted into, and an optional label size.
    var iconBox = NSSize(width: 24, height: 20)
    var fontSize: CGFloat?
    /// Capsule "chip" look (Glass capture panel); `chipFilled` paints the active chip in the accent color.
    var chip = false
    var chipFilled = false
    private var hovering = false

    init(symbol: String? = nil, label: String = "", kind: Kind = .plain, target: AnyObject? = nil, action: Selector? = nil) {
        self.label = label
        self.kind = kind
        super.init(frame: .zero)
        icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label.isEmpty ? $0 : label) }
        isBordered = false
        title = ""
        self.target = target
        self.action = action
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Act on the first click even when the window isn't active yet (the menu bar panel often isn't),
    /// instead of spending that click on activating the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var labelFont: NSFont { Theme.font(fontSize ?? (vertical ? 11 : 13)) }

    override var intrinsicContentSize: NSSize {
        if let fixedSize { return fixedSize }
        let labelWidth = label.isEmpty ? 0 : (label as NSString).size(withAttributes: [.font: labelFont]).width
        if vertical { return NSSize(width: max(58, labelWidth + 16), height: 50) }
        var width: CGFloat = 20 + labelWidth
        if let icon { width += min(icon.size.width, 22) + (label.isEmpty ? 0 : 6) }
        return NSSize(width: max(width, 30), height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
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
        let background: NSColor?
        var foreground: NSColor
        switch kind {
        case .primary:
            background = isHighlighted ? Theme.accent.blended(withFraction: 0.2, of: .black) : hovering
                ? Theme.accent.blended(withFraction: 0.12, of: .white) : Theme.accent
            foreground = Theme.onAccent
        case .plain where chip:
            background = isActive ? (chipFilled ? Theme.accent : Theme.accent.withAlphaComponent(0.18))
                : isHighlighted ? Theme.highlight : hovering ? Theme.highlight.withAlphaComponent(0.6) : Theme.raised
            foreground = isActive ? (chipFilled ? Theme.onAccent : Theme.accent) : Theme.text
        case .plain:
            background = vertical && isActive ? nil : isActive ? Theme.accent.withAlphaComponent(0.2)
                : isHighlighted ? Theme.highlight : hovering ? Theme.raised : nil
            foreground = isActive ? Theme.accent : hovering ? Theme.text : Theme.dimText
        }
        if !isEnabled { foreground = foreground.withAlphaComponent(0.35) }
        if let background {
            background.setFill()
            let radius = chip ? bounds.height / 2 : 6
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }

        let labelSize = label.isEmpty ? .zero : (label as NSString).size(withAttributes: [.font: labelFont])
        if vertical {
            // Icon above label; the active tool gets an accent bar underneath
            // Icon box and label are centered as a group
            let iconSize = icon.map { fit($0.size, in: iconBox) } ?? .zero
            let gap: CGFloat = 3
            let top = ((bounds.height - iconBox.height - gap - labelSize.height) / 2).rounded()
            let inset = (iconBox.height - iconSize.height) / 2
            let iconY = isFlipped ? top + inset : bounds.height - top - iconBox.height + inset
            if let icon {
                tinted(icon, foreground)
                    .draw(in: NSRect(x: (bounds.width - iconSize.width) / 2, y: iconY, width: iconSize.width, height: iconSize.height))
            }
            let labelY = isFlipped ? top + iconBox.height + gap : bounds.height - top - iconBox.height - gap - labelSize.height
            (label as NSString).draw(at: NSPoint(x: (bounds.width - labelSize.width) / 2, y: labelY),
                                     withAttributes: [.font: labelFont, .foregroundColor: foreground])
            if isActive {
                Theme.accent.setFill()
                let barY = isFlipped ? bounds.height - 2 : 0
                NSBezierPath(roundedRect: NSRect(x: 10, y: barY, width: bounds.width - 20, height: 2), xRadius: 1, yRadius: 1).fill()
            }
            return
        }

        let iconSize = icon.map { fit($0.size, in: NSSize(width: 22, height: 18)) } ?? .zero
        let gap: CGFloat = icon != nil && !label.isEmpty ? 6 : 0
        var x = (bounds.width - iconSize.width - gap - labelSize.width) / 2
        if let icon {
            let rect = NSRect(x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
            tinted(icon, foreground).draw(in: rect)
            x += iconSize.width + gap
        }
        if !label.isEmpty {
            (label as NSString).draw(at: NSPoint(x: x, y: (bounds.height - labelSize.height) / 2),
                                     withAttributes: [.font: labelFont, .foregroundColor: foreground])
        }
    }

    private func fit(_ size: NSSize, in box: NSSize) -> NSSize {
        let k = min(box.width / max(size.width, 1), box.height / max(size.height, 1), 1.4)
        return NSSize(width: size.width * k, height: size.height * k)
    }

    /// Template images (SF Symbols, style previews) take the button's text color.
    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Round color swatches with a ring around the selected one (-1: none, e.g. a custom color).
final class SwatchPicker: NSView {
    var colors: [(name: String, color: NSColor)] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }
    var onChange: ((Int) -> Void)?
    private let diameter: CGFloat = 18, spacing: CGFloat = 8

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(colors.count) * (diameter + spacing) + spacing, height: 30)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func frame(at i: Int) -> NSRect {
        NSRect(x: spacing + CGFloat(i) * (diameter + spacing), y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, entry) in colors.enumerated() {
            let r = frame(at: i)
            if i == selectedIndex {
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3.5, dy: -3.5))
                ring.lineWidth = 2
                Theme.accent.setStroke()
                ring.stroke()
            }
            entry.color.setFill()
            NSBezierPath(ovalIn: r).fill()
            let edge = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            Theme.border.setStroke()
            edge.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = colors.indices.first(where: { frame(at: $0).insetBy(dx: -4, dy: -6).contains(p) }) else { return }
        selectedIndex = i
        onChange?(i)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeAllToolTips()
        for (i, entry) in colors.enumerated() {
            addToolTip(frame(at: i), owner: entry.name as NSString, userData: nil)
        }
    }
}

/// A view filled with one of the theme's colors (toolbars, panels, dividers).
final class FillView: NSView {
    enum Role {
        case surface, background, border, raised
    }

    private let role: Role

    init(_ role: Role) {
        self.role = role
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        switch role {
        case .surface: Theme.surface.setFill()
        case .background: Theme.background.setFill()
        case .border: Theme.border.setFill()
        case .raised: Theme.raised.setFill()
        }
        dirtyRect.intersection(bounds).fill()   // the dirty rect can reach past a 1-point divider
    }
}
