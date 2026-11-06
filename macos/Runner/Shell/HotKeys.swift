import AppKit
import Carbon

/// A key combination as Carbon understands it (virtual key code + Carbon modifier flags).
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int

    /// From a key press; nil unless it includes ⌃, ⌥ or ⌘ (a bare key would fire while typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        guard carbon & (controlKey | optionKey | cmdKey) != 0, Self.keyNames[Int(event.keyCode)] != nil else { return nil }
        keyCode = Int(event.keyCode)
        modifiers = carbon
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var display: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "?")
    }

    /// For NSMenuItem: the key character and modifier mask ("" when the key has no menu form).
    var menuKey: (String, NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { mask.insert(.control) }
        if modifiers & optionKey != 0 { mask.insert(.option) }
        if modifiers & shiftKey != 0 { mask.insert(.shift) }
        if modifiers & cmdKey != 0 { mask.insert(.command) }
        if let f = Self.functionKeys.firstIndex(of: keyCode) {
            return (String(UnicodeScalar(UInt32(NSF1FunctionKey + f))!), mask)
        }
        guard let name = Self.keyNames[keyCode], name.count == 1 else { return ("", []) }
        return (name.lowercased(), mask)
    }

    /// System shortcuts that must not be taken over.
    var isReserved: Bool {
        let command = modifiers & (controlKey | optionKey | cmdKey) == cmdKey
        let shiftCommand = modifiers == cmdKey | shiftKey
        if command, [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_S,
                     kVK_ANSI_H, kVK_ANSI_M, kVK_Tab, kVK_Space].contains(keyCode) { return true }
        if shiftCommand, [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6].contains(keyCode) { return true }   // macOS screenshots
        return false
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12]
    static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
            kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        for (i, code) in functionKeys.enumerated() { names[code] = "F\(i + 1)" }
        return names
    }()
}

/// The global shortcuts, configurable in Settings › Shortcuts.
enum ShortcutAction: String, CaseIterable {
    case region, scroll, window, screen, text, record, library

    var label: String {
        switch self {
        case .region: return "Capture region (Space: window)"
        case .scroll: return "Capture scrolling area"
        case .window: return "Capture window"
        case .screen: return "Capture full screen"
        case .text: return "Copy text"
        case .record: return "Record screen (again to stop)"
        case .library: return "Library"
        }
    }

    var defaultShortcut: Shortcut {
        let key: Int
        switch self {
        case .region: key = kVK_ANSI_C
        case .scroll: key = kVK_ANSI_S
        case .window: key = kVK_ANSI_W
        case .screen: key = kVK_ANSI_F
        case .text: key = kVK_ANSI_T
        case .record: key = kVK_ANSI_R
        case .library: key = kVK_ANSI_O
        }
        return Shortcut(keyCode: key, modifiers: controlKey | shiftKey)
    }
}

enum Shortcuts {
    static let changed = Notification.Name("SnapLiteShortcutsChanged")
    /// Shortcuts that could not be registered (another app owns them); shown in the menu and Settings.
    static var failed: [ShortcutAction] = []
    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }
    private static let cleared = Shortcut(keyCode: -1, modifiers: 0)

    /// nil when the user cleared it.
    static func get(_ action: ShortcutAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key(action)),
              let stored = try? JSONDecoder().decode(Shortcut.self, from: data) else { return action.defaultShortcut }
        return stored == cleared ? nil : stored
    }

    static func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if let data = try? JSONEncoder().encode(shortcut ?? cleared) { UserDefaults.standard.set(data, forKey: key(action)) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func resetAll() {
        ShortcutAction.allCases.forEach {
            UserDefaults.standard.removeObject(forKey: key($0))
            UserDefaults.standard.removeObject(forKey: key($0) + ".enabled")
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Per-shortcut on/off (Settings checkbox; default on): off means the key is not registered at all,
    /// so another app can have it (per direct request, 2026-11-06: "no option to disable the ones where
    /// I dont want to shortkey").
    static func isEnabled(_ action: ShortcutAction) -> Bool {
        UserDefaults.standard.object(forKey: key(action) + ".enabled") as? Bool ?? true
    }

    static func setEnabled(_ on: Bool, for action: ShortcutAction) {
        UserDefaults.standard.set(on, forKey: key(action) + ".enabled")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The other action already using `shortcut`, if any.
    static func owner(of shortcut: Shortcut, except action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && get($0) == shortcut }
    }
}

/// Global hotkeys through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        let shortcut: Shortcut
        let handler: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private var suspendCount = 0

    /// Returns false when the combination could not be registered (usually another app owns it).
    @discardableResult
    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        entries[id] = Entry(shortcut: shortcut, handler: handler)
        return suspendCount > 0 || activate(id)
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        entries.removeAll()
    }

    /// While a shortcut is being recorded, the current ones must not fire. Calls nest; every
    /// suspend() needs a matching resume().
    func suspend() {
        suspendCount += 1
        guard suspendCount == 1 else { return }
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        guard suspendCount == 0 else { return }
        entries.keys.forEach { _ = activate($0) }
    }

    private func activate(_ id: UInt32) -> Bool {
        guard let entry = entries[id] else { return false }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4C54), id: id)   // 'SNLT'
        let status = RegisterEventHotKey(UInt32(entry.shortcut.keyCode), UInt32(entry.shortcut.modifiers), hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeyCenter.shared.entries[id.id]?.handler() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
