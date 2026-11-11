import Foundation

/// The rain itself: a faithful port of cmatrix's default mode (cmatrix.c, GPLv3, Chris Allegretta 1999-2017 / Abishek V Ashok
/// 2017-, "new style scrolling"), the same algorithm as my browser-automation rain: matrix[LINES+1][COLS] of char codes (-1 empty, 32 a gap), every SECOND column used, per-column
/// spaces[] gap counter and length[], the same per-frame column walk, charset rand()%90+33, the head marked. Pure (no AppKit)
/// so tools/matrix_rain_check.swift can test it.
struct MatrixColumns {
    static let empty = -1, space = 32, randMin = 33, randNum = 90
    let lines: Int, cols: Int
    private(set) var matrix: [Int]        // (lines + 1) * cols, row-major
    private(set) var isHead: [Bool]
    private(set) var spaces: [Int]
    private(set) var length: [Int]
    private let rand: () -> UInt32

    /// `rnd(n)` = rand() % n, as cmatrix; 0 for n <= 0 (a display only a few rows high).
    static func rnd(_ n: Int, _ rand: () -> UInt32) -> Int { n > 0 ? Int(rand() % UInt32(n)) : 0 }
    static func randchar(_ rand: () -> UInt32) -> Int { rnd(randNum, rand) + randMin }   // 33...122

    init(lines: Int, cols: Int, rand: @escaping () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }) {
        let l = max(lines, 1), c = max(cols, 1)
        self.lines = l; self.cols = c; self.rand = rand
        var m = Array(repeating: MatrixColumns.empty, count: (l + 1) * c)
        var sp = Array(repeating: 0, count: c), len = Array(repeating: 0, count: c)
        for j in stride(from: 0, to: c, by: 2) {          // var_init(): even columns only
            sp[j] = MatrixColumns.rnd(l, rand) + 1
            len[j] = MatrixColumns.rnd(l - 3, rand) + 3
            m[c + j] = MatrixColumns.space                // sentinel ' ' for creation of new streams
        }
        matrix = m; spaces = sp; length = len
        isHead = Array(repeating: false, count: m.count)
    }

    /// One frame: cmatrix's column walk, unchanged.
    mutating func step() {
        let L = lines, C = cols, sp = MatrixColumns.space, em = MatrixColumns.empty
        for j in stride(from: 0, to: C, by: 2) {
            if matrix[j] == em && matrix[C + j] == sp && spaces[j] > 0 {
                spaces[j] -= 1
            } else if matrix[j] == em && matrix[C + j] == sp {
                length[j] = MatrixColumns.rnd(L - 3, rand) + 3
                matrix[j] = MatrixColumns.randchar(rand)
                spaces[j] = MatrixColumns.rnd(L, rand) + 1
            }
            var i = 0, y = 0, z = 0, firstcoldone = false
            while i <= L {
                while i <= L && (matrix[i * C + j] == sp || matrix[i * C + j] == em) { i += 1 }   // skip over spaces
                if i > L { break }
                z = i; y = 0                                                                       // go to the head of this column
                while i <= L && matrix[i * C + j] != sp && matrix[i * C + j] != em { isHead[i * C + j] = false; i += 1; y += 1 }
                if i > L { matrix[z * C + j] = sp; continue }
                matrix[i * C + j] = MatrixColumns.randchar(rand); isHead[i * C + j] = true
                if y > length[j] || firstcoldone { matrix[z * C + j] = sp; matrix[j] = em }
                firstcoldone = true; i += 1
            }
        }
    }

    /// What screen row `row` (0-based; matrix row row+1) of column `col` shows: nil for nothing, else the character code and
    /// whether it is a stream's head (drawn white).
    func cell(row: Int, col: Int) -> (code: Int, head: Bool)? {
        let k = (row + 1) * cols + col
        let v = matrix[k]
        return v == MatrixColumns.empty || v == MatrixColumns.space ? nil : (v, isHead[k])
    }
}

/// What the keyboard focus is on, as read through the Accessibility API (MatrixRain.focusInfo()).
struct FocusInfo {
    var bundleID: String?
    /// The focused element's AXRole; nil when it could not be read; TypingGuard.noFocus when the app has no focused element.
    var role: String?
    var subrole: String? = nil
    var valueSettable = false        // AXValue can be set (an editable value)
    var hasSelectedTextRange = false // AXSelectedTextRange exists (a text caret)
    var editableAncestor = false     // AXEditableAncestor exists (editable web content: contenteditable, a web text box)
}

/// A bare key or ⇧+key recorded for the rain fires only when nobody is typing. Conservative: when unsure, it is typing.
enum TypingGuard {
    static let noFocus = "AXNoFocusedElement"
    /// Terminals: any key may be typed into a shell, and their text views do not always say so.
    static let terminals: Set<String> = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"]
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let textSubroles: Set<String> = ["AXSecureTextField", "AXSearchField"]

    static func isTyping(_ focus: FocusInfo?) -> Bool {
        guard let focus else { return true }                              // nothing could be read
        if let b = focus.bundleID, terminals.contains(b) { return true }
        guard let role = focus.role else { return true }                  // the role could not be read
        if role == noFocus { return false }                               // the app has nothing focused (e.g. the desktop)
        if textRoles.contains(role) { return true }
        if let s = focus.subrole, textSubroles.contains(s) { return true }
        if focus.valueSettable && focus.hasSelectedTextRange { return true }
        if focus.editableAncestor { return true }
        return false
    }
}

/// How the Matrix rain's shortcut (Settings › Shortcuts, `shortcut.matrix`, default ⌃⌥⇧⌘M) is listened for. With ⌃, ⌥ or ⌘ it is a real
/// system hotkey (Carbon RegisterEventHotKey): it works everywhere, also while typing and in terminals, and the key is
/// swallowed. A bare key or ⇧+key cannot be one, so a global key monitor watches for it and fires only when nobody is
/// typing (TypingGuard); the key still reaches the app. No shortcut: only the menu bar item toggles the rain.
enum MatrixTrigger: Equatable {
    case off, systemHotKey, whenNotTyping
    // Carbon modifier bits (Events.h): cmdKey, shiftKey, optionKey, controlKey
    static let cmd = 0x100, shift = 0x200, option = 0x800, control = 0x1000

    /// The default: ⌃⌥⇧⌘M, a system hotkey (works everywhere, nothing is typed).
    static let defaultKeyCode = 46, defaultModifiers = control | option | shift | cmd   // kVK_ANSI_M
    /// 1.80.27-1.80.29 shipped ⇧M (monitor mode) as the default; a stored ⇧M is that old default, not a choice.
    static func isOldDefault(keyCode: Int, modifiers: Int) -> Bool { keyCode == 46 && modifiers == shift }

    static func mode(keyCode: Int?, modifiers: Int) -> MatrixTrigger {
        guard let keyCode, keyCode >= 0 else { return .off }
        return modifiers & (cmd | option | control) != 0 ? .systemHotKey : .whenNotTyping
    }

    var hint: String {
        switch self {
        case .off: return "No shortcut: the menu bar item turns the rain on and off"
        case .systemHotKey: return "Works everywhere"
        case .whenNotTyping: return "Only when not typing; the key is still typed"
        }
    }
}
