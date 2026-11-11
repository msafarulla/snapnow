// Checks for the pure parts of SnapNow's Matrix rain (macos/Runner/Shell/MatrixRainCore.swift): the cmatrix column engine
// and the typing guard. No XCTest host app needed:
//   swiftc -O -o /tmp/matrix_rain_check macos/Runner/Shell/MatrixRainCore.swift tools/matrix_rain_check/main.swift && /tmp/matrix_rain_check
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

// A fixed generator so the runs are repeatable (xorshift32)
func seeded(_ seed: UInt32) -> () -> UInt32 { var s = seed; return { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s } }

// ---- engine: initial state (var_init) ----
var m = MatrixColumns(lines: 40, cols: 61, rand: seeded(7))
for j in 0..<61 {
    if j % 2 == 0 {
        check(m.matrix[61 + j] == MatrixColumns.space, "row 1 of even column \(j) starts as the ' ' sentinel")
        check((1...40).contains(m.spaces[j]), "spaces[\(j)] in 1...LINES")
        check((3...39).contains(m.length[j]), "length[\(j)] in 3...LINES-1")
    } else {
        check(m.matrix[61 + j] == MatrixColumns.empty, "odd column \(j) unused")
    }
}

// ---- engine: running ----
var sawHead = false, sawTail = false, maxCells = 0
for _ in 0..<600 {
    m.step()
    var cells = 0
    for i in 0...40 {
        for j in 0..<61 {
            let v = m.matrix[i * 61 + j]
            if j % 2 == 1 { check(v == MatrixColumns.empty, "odd column \(j) stays empty"); continue }
            check(v == MatrixColumns.empty || v == MatrixColumns.space || (33...122).contains(v), "charset rand()%90+33 (got \(v))")
            if m.isHead[i * 61 + j] { check(v != MatrixColumns.empty && v != MatrixColumns.space, "a head is a character"); sawHead = true }
            if (33...122).contains(v) && !m.isHead[i * 61 + j] { sawTail = true }
            if (33...122).contains(v) { cells += 1 }
        }
    }
    maxCells = max(maxCells, cells)
}
check(sawHead && sawTail, "streams with heads and tails appear")
check(maxCells > 0 && maxCells < 41 * 31, "some, not all, cells lit (max \(maxCells))")
// each stream has exactly one head per column segment: count heads per column never exceeds streams that fit
for j in stride(from: 0, to: 61, by: 2) {
    let heads = (0...40).filter { m.isHead[$0 * 61 + j] && (33...122).contains(m.matrix[$0 * 61 + j]) }.count
    check(heads <= 20, "column \(j) heads sane (\(heads))")
}
// cell(row:col:) maps screen row r to matrix row r+1
if let c = (0..<40).compactMap({ m.cell(row: $0, col: 0) }).first { check((33...122).contains(c.code), "cell() returns a character") }
// tiny display (fewer than 4 rows): no crash, rnd(n<=0) = 0
var tiny = MatrixColumns(lines: 2, cols: 4, rand: seeded(3))
for _ in 0..<50 { tiny.step() }
check(true, "tiny display runs")

// ---- speed: one 5K-ish display (142 used columns x 84 rows) ----
var big = MatrixColumns(lines: 84, cols: 284)
let t0 = Date()
for _ in 0..<1000 { big.step() }
let perStepMs = Date().timeIntervalSince(t0)  // seconds for 1000 steps = ms per step
print(String(format: "engine: %.3f ms per frame on 284x84 (budget 40 ms)", perStepMs))
check(perStepMs < 5, "engine step well under a frame")

// ---- typing guard ----
typealias F = FocusInfo
check(TypingGuard.isTyping(nil), "nothing readable: typing")
check(TypingGuard.isTyping(F(bundleID: "com.apple.Safari", role: nil)), "role unreadable: typing")
check(TypingGuard.isTyping(F(bundleID: "com.mitchellh.ghostty", role: "AXWindow")), "Ghostty: typing")
check(TypingGuard.isTyping(F(bundleID: "com.apple.Terminal", role: TypingGuard.noFocus)), "Terminal: typing even unfocused")
check(TypingGuard.isTyping(F(bundleID: "com.googlecode.iterm2", role: "AXGroup")), "iTerm2: typing")
check(TypingGuard.isTyping(F(bundleID: "dev.warp.Warp-Stable", role: "AXGroup")), "Warp: typing")
for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
    check(TypingGuard.isTyping(F(bundleID: "com.apple.TextEdit", role: role)), "\(role): typing")
}
check(TypingGuard.isTyping(F(bundleID: "x", role: "AXTextField", subrole: "AXSecureTextField")), "password field: typing")
check(TypingGuard.isTyping(F(bundleID: "x", role: "AXGroup", subrole: "AXSecureTextField")), "secure subrole: typing")
check(TypingGuard.isTyping(F(bundleID: "x", role: "AXGroup", valueSettable: true, hasSelectedTextRange: true)), "settable value + caret: typing")
check(TypingGuard.isTyping(F(bundleID: "com.google.Chrome", role: "AXGroup", editableAncestor: true)), "contenteditable: typing")
check(!TypingGuard.isTyping(F(bundleID: "com.apple.finder", role: TypingGuard.noFocus)), "desktop, nothing focused: not typing")
check(!TypingGuard.isTyping(F(bundleID: "com.apple.Safari", role: "AXWebArea")), "a web page, not editable: not typing")
check(!TypingGuard.isTyping(F(bundleID: "com.apple.finder", role: "AXList")), "a Finder list: not typing")
check(!TypingGuard.isTyping(F(bundleID: "com.apple.Music", role: "AXButton", valueSettable: true)), "settable value without a caret: not typing")

// ---- shortcut -> how it is listened for ----
let mKey = 46
check(MatrixTrigger.mode(keyCode: mKey, modifiers: MatrixTrigger.shift) == .whenNotTyping, "⇧M (if recorded): monitor, when not typing")
check(MatrixTrigger.defaultKeyCode == mKey && MatrixTrigger.defaultModifiers == MatrixTrigger.control | MatrixTrigger.option | MatrixTrigger.shift | MatrixTrigger.cmd,
      "the default is ⌃⌥⇧⌘M")
check(MatrixTrigger.mode(keyCode: MatrixTrigger.defaultKeyCode, modifiers: MatrixTrigger.defaultModifiers) == .systemHotKey, "the default is a system hotkey")
check(MatrixTrigger.isOldDefault(keyCode: mKey, modifiers: MatrixTrigger.shift), "a stored ⇧M is the old default: migrated")
check(!MatrixTrigger.isOldDefault(keyCode: mKey, modifiers: MatrixTrigger.control | MatrixTrigger.option), "a recorded ⌃⌥M is kept")
check(!MatrixTrigger.isOldDefault(keyCode: 45, modifiers: MatrixTrigger.shift), "a recorded ⇧N is kept")
check(!MatrixTrigger.isOldDefault(keyCode: -1, modifiers: 0), "a cleared shortcut stays cleared")
check(!MatrixTrigger.isOldDefault(keyCode: mKey, modifiers: MatrixTrigger.defaultModifiers), "the new default is not migrated again")
check(MatrixTrigger.mode(keyCode: mKey, modifiers: 0) == .whenNotTyping, "a bare key: monitor")
check(MatrixTrigger.mode(keyCode: mKey, modifiers: MatrixTrigger.control | MatrixTrigger.option) == .systemHotKey, "⌃⌥M: system hotkey")
check(MatrixTrigger.mode(keyCode: mKey, modifiers: MatrixTrigger.cmd | MatrixTrigger.shift) == .systemHotKey, "⇧⌘M: system hotkey")
check(MatrixTrigger.mode(keyCode: mKey, modifiers: MatrixTrigger.option) == .systemHotKey, "⌥M: system hotkey")
check(MatrixTrigger.mode(keyCode: mKey, modifiers: MatrixTrigger.control | MatrixTrigger.shift) == .systemHotKey, "⌃⇧M: system hotkey")
check(MatrixTrigger.mode(keyCode: nil, modifiers: 0) == .off, "cleared: off")
check(MatrixTrigger.mode(keyCode: -1, modifiers: 0) == .off, "the stored 'cleared' value: off")
check(MatrixTrigger.systemHotKey.hint == "Works everywhere", "hint: system hotkey")
check(MatrixTrigger.whenNotTyping.hint == "Only when not typing; the key is still typed", "hint: monitor")

print(failures == 0 ? "matrix_rain_check: all passed" : "matrix_rain_check: \(failures) failed")
exit(failures == 0 ? 0 : 1)
