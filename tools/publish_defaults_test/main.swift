import Foundation

// Checks for Settings › Defaults (macos/Runner/Shell/DefaultsFile.swift, compiled alone with this file by run.sh): only the
// settings' keys go out and come in (excluded and unknown keys never), publish then apply between "Macs" (UserDefaults
// suites), home-relative paths, own publishes and applied ids skipped, half-written, damaged and newer-format files
// skipped, an unreachable folder, the atomic write.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    print(ok ? "PASS" : "FAIL", what + (ok ? "" : " (line \(line))"))
    if !ok { failures += 1 }
}

// Settings of every kind, shaped like PublishDefaults.published (excluded keys such as regionCapture.lastArea and
// sharedDefaults.installId are not in it)
let entries: [DefaultsFile.Entry] = [
    .json("style.arrow"),
    .json("captureConfig") { data in (try? JSONSerialization.jsonObject(with: data)) is [String: Any] },
    .text("callout.style"),
    .bool("followDrag"),
    .intText("draw.color", 0...0xFFFF_FFFF),
    .choice("liveDrawCloseSpeed", ["fast", "normal", "relaxed", "slow"]),
    .int("watermark.opacity", 5...100),
    .bool("capture.stampTime"),
    .choice("hotkeys.mode", ["all", "regionOnly", "none"]),
    .json("shortcut.region"),
    .bool("shortcut.region.enabled"),
    .intArray("toolbarTools") { (0..<14).contains($0) },
    .number("schedule.interval") { $0 > 0 },
    .path("schedule.folder"),
    .path("watermark.imagePath"),
]
let home = "/Users/someone"

var suites: [String] = []
var folders: [URL] = []

func suite() -> UserDefaults {
    let name = "snapnow.publish-defaults-test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    suites.append(name)
    return d
}

func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("publish-defaults-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    folders.append(url)
    return url
}

func publish(_ d: UserDefaults, install: String, id: String = UUID().uuidString, mac: String = "Mac One") -> DefaultsFile.Publish {
    DefaultsFile.Publish(publishedAt: Date(timeIntervalSince1970: 1_800_000_000), publishId: id, mac: mac, installId: install,
                         appVersion: "1.83.0+273", values: DefaultsFile.snapshot(d, entries: entries))
}

func readOK(_ folder: URL) -> DefaultsFile.Publish? {
    if case .ok(let p) = DefaultsFile.read(folder: folder) { return p }
    return nil
}

let arrowJSON = #"{"end":"triangle","headSize":"large","pattern":"dashed","start":"none","tapered":true,"width":7}"#

// 1. Whitelist filtering
do {
    let a = suite()
    a.set(arrowJSON.data(using: .utf8), forKey: "style.arrow")
    a.set(true, forKey: "followDrag")
    a.set("{{100, 100}, {300, 200}}", forKey: "regionCapture.lastArea")   // excluded: screen coordinates
    a.set("A-INSTALL", forKey: "sharedDefaults.installId")                 // excluded: bookkeeping
    a.set("regionOnly", forKey: "hotkeys.mode")                            // per Mac before; published now
    let values = DefaultsFile.snapshot(a, entries: entries, home: home)
    check(Set(values.keys) == Set(entries.map(\.key)), "snapshot holds exactly the settings' keys")
    check(values["regionCapture.lastArea"] == nil && values["sharedDefaults.installId"] == nil, "excluded keys are never published")
    check(values["hotkeys.mode"] as? String == "regionOnly", "the hotkey mode is published")
    check(values["watermark.opacity"] is NSNull, "a never-set key is published as null")
    check((values["style.arrow"] as? [String: Any])?["width"] as? Int == 7, "JSON data goes in as the JSON object itself")

    a.set(42, forKey: "callout.style")                             // wrong type stored: left out, not published as null
    check(DefaultsFile.snapshot(a, entries: entries)["callout.style"] == nil, "a stored value of the wrong type is left out")

    let b = suite()
    b.set("{{0, 0}, {10, 10}}", forKey: "regionCapture.lastArea")
    b.set("B-INSTALL", forKey: "sharedDefaults.installId")
    b.set(30, forKey: "watermark.opacity")
    b.set("cloud", forKey: "callout.style")
    b.set(false, forKey: "capture.stampTime")
    let incoming: [String: Any] = [
        "regionCapture.lastArea": "{{5, 5}, {9, 9}}", "sharedDefaults.installId": "A", "someFutureKey": 1,   // excluded / unknown
        "watermark.opacity": 400,                                             // out of the slider's range: rejected
        "liveDrawCloseSpeed": "warp",                                         // not a choice: rejected
        "callout.style": 3,                                                   // wrong type: rejected
        "followDrag": "yes",                                                  // wrong type: rejected
        "draw.color": "4281237749",                                           // fine
        "capture.stampTime": true,                                            // fine
    ]
    let result = DefaultsFile.apply(incoming, to: b, entries: entries, home: home)
    let (applied, rejected) = (result.applied, result.rejected)
    check(b.string(forKey: "regionCapture.lastArea") == "{{0, 0}, {10, 10}}" && b.string(forKey: "sharedDefaults.installId") == "B-INSTALL"
          && b.object(forKey: "someFutureKey") == nil, "excluded and unknown keys are ignored on apply")
    check(Set(rejected) == ["watermark.opacity", "liveDrawCloseSpeed", "callout.style", "followDrag"], "invalid values are rejected: \(rejected.sorted())")
    check(b.integer(forKey: "watermark.opacity") == 30 && b.string(forKey: "callout.style") == "cloud" && b.object(forKey: "followDrag") == nil,
          "a rejected value keeps this Mac's own")
    check(Set(applied) == ["draw.color", "capture.stampTime"] && b.string(forKey: "draw.color") == "4281237749" && b.bool(forKey: "capture.stampTime"),
          "valid values are applied")
    check(DefaultsFile.apply(["draw.color": "-1"], to: b, entries: entries).rejected == ["draw.color"], "an integer text out of range is rejected")
    check(DefaultsFile.apply(["watermark.opacity": 30.5], to: b, entries: entries).rejected == ["watermark.opacity"], "a fraction is not an integer")
    check(DefaultsFile.apply(["capture.stampTime": 1], to: b, entries: entries).rejected == ["capture.stampTime"], "a number is not a bool")
    check(DefaultsFile.apply(["style.arrow": "not json"], to: b, entries: entries).rejected == ["style.arrow"], "JSON keys need an object or array")
}

// 2. Round trip: publish on one Mac, apply on another
do {
    let a = suite(), b = suite()
    a.set(arrowJSON.data(using: .utf8), forKey: "style.arrow")
    a.set(try! JSONSerialization.data(withJSONObject: ["tab": "image", "delaySeconds": 3]), forKey: "captureConfig")
    a.set("pill", forKey: "callout.style")
    a.set(false, forKey: "followDrag")
    a.set("4281237749", forKey: "draw.color")
    a.set("slow", forKey: "liveDrawCloseSpeed")
    a.set(55, forKey: "watermark.opacity")
    // capture.stampTime never set on A: B's own setting goes back to the default
    b.set(false, forKey: "capture.stampTime")
    b.set(true, forKey: "followDrag")

    let folder = tempFolder()
    let p = publish(a, install: "install-A", id: "id-1")
    try! DefaultsFile.write(try! DefaultsFile.encode(p), to: folder)
    let left = try! FileManager.default.contentsOfDirectory(atPath: folder.path)
    check(left == [DefaultsFile.name], "the atomic write leaves only the file (no temp files): \(left)")
    guard let read = readOK(folder) else { check(false, "the published file reads back"); exit(1) }
    check(read.publishId == "id-1" && read.mac == "Mac One" && read.installId == "install-A" && read.appVersion == "1.83.0+273"
          && read.publishedAt == p.publishedAt && read.format == DefaultsFile.format, "the header round-trips")
    check(DefaultsFile.decide(read, installId: "install-B", lastAppliedId: nil, force: false) == .apply, "another Mac's publish is applied")
    let rejected = DefaultsFile.apply(read.values, to: b, entries: entries).rejected
    check(rejected.isEmpty, "nothing rejected on the round trip: \(rejected)")
    let arrow = b.data(forKey: "style.arrow").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSDictionary
    check(arrow == (try! JSONSerialization.jsonObject(with: arrowJSON.data(using: .utf8)!) as! NSDictionary), "the arrow style arrives as the same JSON")
    let config = b.data(forKey: "captureConfig").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    check(config?["tab"] as? String == "image" && config?["delaySeconds"] as? Int == 3, "the capture settings arrive")
    check(b.string(forKey: "callout.style") == "pill" && b.object(forKey: "followDrag") as? Bool == false
          && b.string(forKey: "draw.color") == "4281237749" && b.string(forKey: "liveDrawCloseSpeed") == "slow"
          && b.integer(forKey: "watermark.opacity") == 55, "text, bool, integer-text, choice and integer values arrive")
    check(b.object(forKey: "capture.stampTime") == nil, "a key never set on the publishing Mac is reset on the receiver")
    check(DefaultsFile.snapshot(b, entries: entries).count == entries.count, "the receiver can publish the same keys back")

    // A newer publish replaces the file; an older app's file without a key leaves that key alone
    b.set("square", forKey: "callout.style")
    var older = publish(a, install: "install-A", id: "id-2")
    older.values.removeValue(forKey: "callout.style")
    try! DefaultsFile.write(try! DefaultsFile.encode(older), to: folder)
    check(readOK(folder)?.publishId == "id-2", "publishing again replaces the file")
    DefaultsFile.apply(readOK(folder)!.values, to: b, entries: entries)
    check(b.string(forKey: "callout.style") == "square", "a key missing from the file keeps the receiver's value")
}

// 3. Own publish and already applied ids
do {
    let a = suite()
    let p = publish(a, install: "install-A", id: "id-9")
    check(DefaultsFile.decide(p, installId: "install-A", lastAppliedId: nil, force: false) == .own, "this install's own publish is skipped")
    check(DefaultsFile.decide(p, installId: "install-A", lastAppliedId: nil, force: true) == .own, "even Apply now skips the own publish")
    check(DefaultsFile.decide(p, installId: "install-B", lastAppliedId: "id-9", force: false) == .alreadyApplied, "an applied id is not applied twice")
    check(DefaultsFile.decide(p, installId: "install-B", lastAppliedId: "id-9", force: true) == .apply, "Apply now applies it again")
    check(DefaultsFile.decide(p, installId: "install-B", lastAppliedId: "id-8", force: false) == .apply, "a new id is applied")
}

// 4. Damaged, half-written and newer files; unreachable folder
do {
    let a = suite()
    let good = try! DefaultsFile.encode(publish(a, install: "install-A", id: "id-1"))
    func isMalformed(_ r: DefaultsFile.ReadResult) -> Bool { if case .malformed = r { return true }; return false }
    check(isMalformed(DefaultsFile.decode(good.prefix(good.count / 2))), "a half-written file is malformed")
    check(isMalformed(DefaultsFile.decode(Data())), "an empty file is malformed")
    check(isMalformed(DefaultsFile.decode("not json at all".data(using: .utf8)!)), "garbage is malformed")
    check(isMalformed(DefaultsFile.decode("[1, 2]".data(using: .utf8)!)), "a JSON array is malformed")
    var doc = try! JSONSerialization.jsonObject(with: good) as! [String: Any]
    for field in ["format", "publishId", "installId", "publishedAt", "values"] {
        var d = doc
        d.removeValue(forKey: field)
        check(isMalformed(DefaultsFile.decode(try! JSONSerialization.data(withJSONObject: d))), "a file without \(field) is malformed")
    }
    doc["format"] = true
    check(isMalformed(DefaultsFile.decode(try! JSONSerialization.data(withJSONObject: doc))), "a format that is not a number is malformed")
    doc["format"] = 1
    doc["values"] = ["a", "b"]
    check(isMalformed(DefaultsFile.decode(try! JSONSerialization.data(withJSONObject: doc))), "values that are not an object are malformed")
    doc["values"] = [:] as [String: Any]
    doc["format"] = DefaultsFile.format + 1
    if case .newer(let v) = DefaultsFile.decode(try! JSONSerialization.data(withJSONObject: doc)) {
        check(v == DefaultsFile.format + 1, "a newer format is reported with its number")
    } else {
        check(false, "a newer format is skipped as newer")
    }

    let folder = tempFolder()
    try! good.prefix(40).write(to: folder.appendingPathComponent(DefaultsFile.name))
    check(isMalformed(DefaultsFile.read(folder: folder)), "a cut-off file in the folder is skipped as malformed")

    let gone = FileManager.default.temporaryDirectory.appendingPathComponent("publish-defaults-missing-\(UUID().uuidString)")
    if case .unreachable = DefaultsFile.read(folder: gone) { check(true, "a missing folder is unreachable") } else { check(false, "a missing folder is unreachable") }
    var threw = false
    do { try DefaultsFile.write(good, to: gone) } catch { threw = true }
    check(threw && !FileManager.default.fileExists(atPath: gone.path), "publishing to a missing folder fails and creates nothing")
    let empty = tempFolder()
    if case .missing = DefaultsFile.read(folder: empty) { check(true, "an empty folder has nothing published") } else { check(false, "an empty folder has nothing published") }
    try! Data().write(to: empty.appendingPathComponent(".\(DefaultsFile.name).icloud"))
    if case .downloading = DefaultsFile.read(folder: empty) { check(true, "an iCloud placeholder waits for the download") } else { check(false, "an iCloud placeholder waits for the download") }
}

// 5. Settings that used to stay per Mac (hotkeys, shortcuts, toolbar) and paths in the home folder
do {
    let a = suite()
    let shortcut = #"{"keyCode":35,"modifiers":2048}"#
    a.set(shortcut.data(using: .utf8), forKey: "shortcut.region")
    a.set(false, forKey: "shortcut.region.enabled")
    a.set("none", forKey: "hotkeys.mode")
    a.set([1, 3, 7], forKey: "toolbarTools")
    a.set(90.0, forKey: "schedule.interval")
    a.set(home + "/Pictures/Scheduled", forKey: "schedule.folder")
    a.set("/Volumes/Share/marks.png", forKey: "watermark.imagePath")            // outside the home
    let values = DefaultsFile.snapshot(a, entries: entries, home: home)
    check(values["schedule.folder"] as? String == "~/Pictures/Scheduled", "a folder inside the home goes as ~/...")
    check(values["watermark.imagePath"] == nil, "a path outside the home is not published (not even as null)")
    check(values["toolbarTools"] as? [Int] == [1, 3, 7] && values["schedule.interval"] as? Double == 90, "integer lists and numbers go as they are")
    check(DefaultsFile.homeRelative(home, home: home) == "~" && DefaultsFile.homeRelative(home + "x/y", home: home) == nil,
          "the home itself is ~, a sibling that only starts with the same letters is outside")

    let folder = tempFolder()
    let p = DefaultsFile.Publish(publishedAt: Date(), publishId: "p5", mac: "Mac One", installId: "A", appVersion: "x", values: values)
    try! DefaultsFile.write(try! DefaultsFile.encode(p), to: folder)
    let read = readOK(folder)!

    // A Mac whose home has that folder
    let homeB = tempFolder()
    try! FileManager.default.createDirectory(at: homeB.appendingPathComponent("Pictures/Scheduled"), withIntermediateDirectories: true)
    let b = suite()
    b.set("/Users/b/watermark.png", forKey: "watermark.imagePath")
    let rb = DefaultsFile.apply(read.values, to: b, entries: entries, home: homeB.path)
    check(rb.rejected.isEmpty && rb.missing.isEmpty, "everything applies on a Mac that has the folder: \(rb.rejected) \(rb.missing)")
    check(b.string(forKey: "schedule.folder") == homeB.path + "/Pictures/Scheduled", "the ~/ path is expanded in this Mac's home")
    check(b.string(forKey: "watermark.imagePath") == "/Users/b/watermark.png", "a path that was not published keeps this Mac's own")
    check(b.string(forKey: "hotkeys.mode") == "none" && b.object(forKey: "shortcut.region.enabled") as? Bool == false
          && b.data(forKey: "shortcut.region").flatMap { String(data: $0, encoding: .utf8) }.map { $0.contains("\"keyCode\":35") } == true,
          "hotkey mode, a custom shortcut and its on/off flag arrive")
    check(b.array(forKey: "toolbarTools") as? [Int] == [1, 3, 7] && b.double(forKey: "schedule.interval") == 90, "the toolbar list and the interval arrive")

    // A Mac whose home lacks it: that one key is skipped and named, the rest applies
    let homeC = tempFolder()
    let c = suite()
    c.set(homeC.path + "/Own", forKey: "schedule.folder")
    let rc = DefaultsFile.apply(read.values, to: c, entries: entries, home: homeC.path)
    check(rc.missing == ["schedule.folder"] && c.string(forKey: "schedule.folder") == homeC.path + "/Own",
          "a folder missing on this Mac is skipped, named, and this Mac keeps its own")
    check(c.string(forKey: "hotkeys.mode") == "none", "the other settings still apply")

    // Paths that must never be taken
    for bad in ["~/../../etc", "/etc", "~/a/../../b", "relative/path", "~user/x"] {
        check(DefaultsFile.apply(["schedule.folder": bad], to: c, entries: entries, home: homeC.path).rejected == ["schedule.folder"],
              "path \(bad) is rejected")
    }
    check(DefaultsFile.apply(["schedule.folder": "~"], to: c, entries: entries, home: homeC.path).applied == ["schedule.folder"]
          && c.string(forKey: "schedule.folder") == homeC.path, "~ alone is the home")
    check(DefaultsFile.apply(["toolbarTools": [1, 99]], to: c, entries: entries).rejected == ["toolbarTools"], "a tool number out of range is rejected")
    check(DefaultsFile.apply(["toolbarTools": [true]], to: c, entries: entries).rejected == ["toolbarTools"], "a bool is not a tool number")
    check(DefaultsFile.apply(["schedule.interval": -5], to: c, entries: entries).rejected == ["schedule.interval"], "a negative interval is rejected")
    check(DefaultsFile.apply(["hotkeys.mode": "sometimes"], to: c, entries: entries).rejected == ["hotkeys.mode"], "an unknown hotkey mode is rejected")
}

for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
for url in folders { try? FileManager.default.removeItem(at: url) }
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
