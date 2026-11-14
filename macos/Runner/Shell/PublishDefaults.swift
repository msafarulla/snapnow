import AppKit
import SystemConfiguration

/// Settings › Defaults: the same settings on every Mac. "Publish my defaults" writes every user setting (the `settings`
/// below minus the `excluded` ones) to snapnow-defaults.json in a folder the user's Macs share (iCloud Drive, a synced or
/// network folder); every other Mac with the switch on applies a publish it has not applied yet, never its own (format and
/// rules: DefaultsFile). With "Publish my changes automatically" on (the default) a change to any published setting on
/// this Mac is published a moment later, and a publish from another Mac is applied within a few seconds (file events, plus
/// a 2 s look at the file for network folders), so every Mac ends up with the same SnapNow. What was just applied is never
/// published back: publishing compares against the values as they stood after the last publish or apply.
final class PublishDefaults {
    static let shared = PublishDefaults()
    /// Defaults from another Mac were applied (Settings rebuilds to show them).
    static let changed = Notification.Name("SnapNowPublishedDefaultsApplied")
    /// The folder, the switch or the status line changed.
    static let statusChanged = Notification.Name("SnapNowPublishedDefaultsStatus")

    // MARK: - What is published

    /// Every user setting the app keeps, with the settings code's own check for its values. ALL OF THEM ARE PUBLISHED, except
    /// the keys in `excluded` below. Dart-owned values are checked for their type here and parsed by the editor exactly as
    /// when it reads them at startup (unknown names fall back to the built-in default there). Paths (`.path`) go as "~/..."
    /// and are applied only where that folder or file exists.
    /// A NEW SETTING MUST BE REGISTERED HERE (one line: its type and rule; it is then published) OR, IF IT CANNOT WORK ON
    /// ANOTHER MAC, ADDED TO `excluded` WITH THE REASON: test/publish_defaults_keys_test.dart finds the keys used in lib/ and
    /// macos/Runner and fails on one that is in neither.
    static let settings: [DefaultsFile.Entry] = [
        // settings-keys:begin
        // Markup tools (editor_page.dart, quick_styles.dart): style per kind (heads, head size, thickness, pattern, tapered,
        // outline, shadow, border, snake skin...), text and callout formats, My Styles, bubble and step shapes, curves
        .json("style.arrow"),
        .json("style.line"),
        .json("style.shape"),
        .json("style.textFormat.text"),
        .json("style.textFormat.callout"),
        .json("myQuickStyles"),
        .text("callout.style"),
        .text("step.style"),
        .bool("followDrag"),
        // Editor window and toolbar: tools shown, toolbar side, inspector, pin on top, hidden built-in logos
        .intArray("toolbarTools") { Tool(rawValue: $0) != nil },
        .bool("toolbar.left"),
        .bool("inspector.hidden"),
        .bool("pinOnTop"),
        .text("logos.hidden"),
        .text("appearance") { AppearanceChoice(rawValue: $0) != nil },
        // Draw mode: on/off, its colour and tool, strip, inspector, glass, closing and closing speed
        .bool("liveDrawMode"),
        .intText("draw.color", 0...0xFFFF_FFFF),
        .text("draw.tool"),
        .text("draw.toolbar"),
        .bool("draw.inspector"),
        .choice("liveDrawGlass", Prefs.glassChoices.map { String($0.value) }),
        .choice("liveDrawClose", DrawClose.allCases.map(\.rawValue)),
        .choice("liveDrawCloseSpeed", DrawCloseSpeed.allCases.map(\.rawValue)),
        .bool("liveDrawCloseAnimation"),                       // read only while liveDrawClose is unset
        // Global keys and gestures (the shortcuts themselves and their on/off flags: `shortcuts` below)
        .text("hotkeys.mode") { Shell.HotkeyMode(rawValue: $0) != nil },
        .bool("matrixRain"),
        .bool("altClickHand"),
        // Effects and output: GIF entrance, size and frame rate, Manim render height, Save As format
        .text("gifEntrance"),
        .bool("gifFourier"),                                   // the older on/off form of gifEntrance
        .intText("gifMaxSide"),
        .choice("gifFps", Prefs.gifFpsChoices),
        .intText("manimRenderH"),
        .text("saveAs.defaultFormat") { name in name.isEmpty || SaveAs.available.contains { $0.name == name } },
        .text("saveAs.format"),                                // the format used last in Save As (an unknown name falls back there)
        // Capture: the panel's settings and presets, what happens after a capture, stamp, corners, crop
        .json("captureConfig", CaptureConfig.decodes),
        .json("capturePresets", CaptureConfig.decodesPresets),
        .bool("openEditorAfterCapture"),
        .bool("copyAfterCapture"),
        .bool("regionCapture.rememberArea"),
        .bool("capture.stampTime"),
        .bool("capture.roundCorners"),
        .bool("capture.openInCrop"),
        // Recording and transcripts
        .bool("recordMicrophone"),
        .bool("recordSystemAudio"),
        .choice("recordingQuality", RecordingQuality.allCases.map(\.rawValue)),
        .bool("transcribeRecordings"),
        .text("transcriptLanguage"),                           // a language this Mac cannot transcribe shows in Settings as chosen
        // Watermark
        .bool("watermark.enabled"),
        .text("watermark.text"),
        .choice("watermark.placement", Prefs.wmPlacements),
        .int("watermark.opacity", 5...100),                    // the Settings slider's range
        .path("watermark.imagePath"),                          // a copy in Application Support: applied where that file exists
        // Scheduled captures
        .number("schedule.interval") { $0 > 0 },
        .path("schedule.folder"),
        // settings-keys:end
    ] + shortcuts

    /// "shortcut.<action>" (the key, JSON {keyCode, modifiers}) and "shortcut.<action>.enabled" for every global shortcut.
    static let shortcuts: [DefaultsFile.Entry] = ShortcutAction.allCases.flatMap { action -> [DefaultsFile.Entry] in
        [.json("shortcut.\(action.rawValue)") { (try? JSONDecoder().decode(Shortcut.self, from: $0)) != nil },
         .bool("shortcut.\(action.rawValue).enabled")]
    }

    /// The only keys never published, each with the reason (they cannot work or make no sense on another Mac).
    static let excluded: [String: String] = [
        // excluded-keys:begin
        "regionCapture.lastArea": "screen coordinates of the last capture area; displays differ from Mac to Mac",
        "schedule.running": "whether a scheduled capture is running on this Mac right now (run state; it resumes at launch)",
        "screenPermission.grantedBuild": "the build Screen Recording was granted to on this Mac (system permission state)",
        "liveDraw.promptedAccessibility": "the Accessibility prompt was shown on this Mac (first-run state)",
        "liveDraw.promptedInputMonitoring": "the Input Monitoring prompt was shown on this Mac (first-run state)",
        "sharedDefaults.folder": "this feature's shared folder: each Mac picks its own way to reach it",
        "sharedDefaults.autoApply": "this feature's switch: each Mac decides whether it follows the others",
        "sharedDefaults.autoPublish": "this feature's switch: each Mac decides whether its changes go out by themselves",
        "sharedDefaults.installId": "identifies this app install so that its own publish is never applied here",
        "sharedDefaults.lastAppliedId": "bookkeeping: the publish applied last on this Mac",
        "sharedDefaults.lastApplied": "bookkeeping: when and from which Mac defaults were applied here",
        "sharedDefaults.lastPublished": "bookkeeping: the newest publish seen in the folder",
        // excluded-keys:end
    ]

    /// What goes into the file and what is taken from it.
    static var published: [DefaultsFile.Entry] { settings.filter { excluded[$0.key] == nil } }

    // MARK: - State (per Mac)

    private static let folderKey = "sharedDefaults.folder"
    private static let autoApplyKey = "sharedDefaults.autoApply"
    private static let autoPublishKey = "sharedDefaults.autoPublish"
    private static let installIdKey = "sharedDefaults.installId"           // random, made once per install
    private static let lastAppliedIdKey = "sharedDefaults.lastAppliedId"
    private static let lastAppliedKey = "sharedDefaults.lastApplied"       // ["at": Date, "mac": String]
    private static let lastPublishedKey = "sharedDefaults.lastPublished"   // the newest publish seen: ["at", "mac", "own"]

    private let defaults = UserDefaults.standard
    /// Every file access: a network volume that stops answering blocks this queue, never the app.
    private let io = DispatchQueue(label: "snapnow.publish-defaults", qos: .utility)
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var checkWork: DispatchWorkItem?
    private var reading = false
    private var readAgain = false
    /// Why the last look at the folder applied nothing (or not everything), for the status line; nil when all is well.
    private(set) var problem: String?
    /// The published values as they stood after the last publish or apply (DefaultsFile.canonical); nil until the first
    /// look at the folder is done, so a Mac that starts up never overwrites a newer publish with its older state.
    private var baseline: Data?
    private var publishWork: DispatchWorkItem?
    private var quietUntil = Date.distantPast          // just applied: the app's own follow-up writes are not "my changes"
    private var pollTimer: Timer?
    private var polling = false
    private var lastStamp: String?                      // the file's modification time and size at the last poll
    private var lastToast = Date.distantPast
    private var napGuard: NSObjectProtocol?

    /// Empty = the feature is off.
    var folder: URL? {
        get { defaults.string(forKey: Self.folderKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            if let newValue { defaults.set(newValue.path, forKey: Self.folderKey) } else { defaults.removeObject(forKey: Self.folderKey) }
            problem = nil
            baseline = nil
            watch()
            postStatus()
            scheduleCheck(after: 0.2)
        }
    }

    /// On by default: a change to a published setting on this Mac is published by itself.
    var autoPublish: Bool {
        get { Prefs.onByDefault(Self.autoPublishKey) }
        set {
            defaults.set(newValue, forKey: Self.autoPublishKey)
            if newValue { rebaseline() }               // only changes made from now on go out
            postStatus()
        }
    }

    /// On by default once a folder is set.
    var autoApply: Bool {
        get { Prefs.onByDefault(Self.autoApplyKey) }
        set {
            defaults.set(newValue, forKey: Self.autoApplyKey)
            postStatus()
            startPolling()
            if newValue { scheduleCheck(after: 0.2) }
        }
    }

    private var installId: String {
        if let id = defaults.string(forKey: Self.installIdKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.installIdKey)
        return id
    }

    /// The computer name the system reports (System Settings › General › Sharing).
    static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return (info?["CFBundleVersion"] as? String).map { "\(short)+\($0)" } ?? short
    }

    // MARK: - Start, watch

    /// At launch: watch the folder and look at it once the editor's side is up; again whenever SnapNow becomes active and
    /// when draw mode has closed (a publish that came in while drawing).
    func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleCheck()
        }
        NotificationCenter.default.addObserver(forName: LiveDraw.ended, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleCheck()
        }
        // any write to a setting, from Swift or the editor: published a moment after the last one (a slider drag = one publish)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.watch()
            self?.scheduleCheck(after: 0)
        }
    }

    // MARK: - Automatic publish

    private func currentValues() -> [String: Any] { DefaultsFile.snapshot(defaults, entries: Self.published) }

    private func rebaseline() { baseline = DefaultsFile.canonical(currentValues()) }

    private func settingsChanged() {
        guard folder != nil, autoPublish, baseline != nil else { return }
        publishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publishIfChanged() }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func publishIfChanged() {
        guard folder != nil, autoPublish, let baseline else { return }
        if Date() < quietUntil {                         // settling after an apply: look again when it is over
            let wait = quietUntil.timeIntervalSinceNow + 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.settingsChanged() }
            return
        }
        guard DefaultsFile.canonical(currentValues()) != baseline else { return }
        publish(automatic: true)
    }

    // MARK: - Poll (network folders report no file events for other Macs' writes)

    /// Every 2 s, while a folder is set and applying is on: the file's modification time and size, read off the main
    /// thread (a volume that stops answering holds up only that read; the next ones are skipped until it returns).
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let napGuard { ProcessInfo.processInfo.endActivity(napGuard); self.napGuard = nil }
        guard folder != nil, autoApply else { return }
        // a menu bar app in the background is napped by macOS and its timers stretched to many seconds: keep this one on time
        napGuard = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Applying published defaults from other Macs promptly")
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func poll() {
        guard let folder, autoApply, !polling else { return }
        polling = true
        let path = folder.appendingPathComponent(DefaultsFile.name).path
        io.async {
            let a = try? FileManager.default.attributesOfItem(atPath: path)
            let stamp = a.map { "\(($0[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\($0[.size] as? Int ?? 0)" }
            DispatchQueue.main.async {
                self.polling = false
                guard stamp != self.lastStamp else { return }
                let first = self.lastStamp == nil
                self.lastStamp = stamp
                if !first || self.stream == nil { self.scheduleCheck(after: 0.1) }
            }
        }
    }

    /// File system events for the folder (FSEvents also reports a file replaced by a rename, and the folder going away).
    /// A network volume does not report other Macs' writes: those are picked up at launch and when SnapNow becomes active.
    private func watch() {
        stopWatching()
        startPolling()
        guard let path = folder?.path else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<PublishDefaults>.fromOpaque(info).takeUnretainedValue().scheduleCheck()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
        watchedPath = path
    }

    private func stopWatching() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        watchedPath = nil
    }

    /// Bursts of events (the temp file, the rename, a sync client's own steps) end in one look.
    private func scheduleCheck(after delay: TimeInterval = 0.3) {
        checkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Publish

    /// "Publish my defaults" (and every automatic publish): the settings, written whole into the folder, with the folders
    /// and files the path settings point to (DefaultsFile.publishAssets). [automatic] failures only show in the status line.
    func publish(automatic: Bool = false) {
        guard let folder else { return }
        publishWork?.cancel()
        let values = currentValues()
        let snapshot = DefaultsFile.canonical(values)
        var p = DefaultsFile.Publish(publishedAt: Date(), publishId: UUID().uuidString, mac: Self.macName, installId: installId,
                                     appVersion: Self.appVersion, values: values)
        io.async {
            var failure: String?
            let extra = DefaultsFile.publishAssets(values, entries: Self.published, to: folder)
            p.folders = extra.folders
            p.assets = extra.assets
            do { try DefaultsFile.write(try DefaultsFile.encode(p), to: folder) } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                if let failure {
                    self.problem = "Could not publish: \(failure)"
                    if !automatic { Toast.show("Could not publish the defaults", symbol: "exclamationmark.triangle.fill", detail: failure) }
                } else {
                    self.problem = nil
                    self.baseline = snapshot             // what the other Macs have now; a failed publish is tried again on the next change
                    self.noteSeen(p)
                }
                self.postStatus()
            }
        }
    }

    // MARK: - Apply

    /// Looks at the folder and applies a publish from another Mac that was not applied yet. [force] = "Apply now": works with
    /// the switch off and applies the file again even if it was applied before (never this Mac's own publish).
    func check(force: Bool = false) {
        guard let folder, force || autoApply else {
            if folder != nil, baseline == nil { rebaseline() }   // not following the others: this Mac's changes still go out
            return
        }
        if reading { readAgain = true; return }
        reading = true
        io.async {
            let result = DefaultsFile.read(folder: folder)
            DispatchQueue.main.async {
                self.reading = false
                self.handle(result, force: force)
                if self.readAgain { self.readAgain = false; self.scheduleCheck() }
            }
        }
    }

    private func handle(_ result: DefaultsFile.ReadResult, force: Bool) {
        if case .unreachable = result { stopWatching() } else if stream == nil || watchedPath != folder?.path { watch() }
        switch result {
        case .unreachable: problem = "The shared folder cannot be reached (not mounted or removed)"
        case .missing: problem = force ? "Nothing has been published to the folder yet" : nil
        case .downloading: problem = "Waiting for iCloud Drive to download the file"
        case .malformed: problem = "The published file could not be read (half written or damaged); skipped"
        case .newer(let v): problem = "Published by a newer SnapNow (file format \(v)); update this Mac to apply it"
        case .ok(let p):
            noteSeen(p)
            switch DefaultsFile.decide(p, installId: installId, lastAppliedId: defaults.string(forKey: Self.lastAppliedIdKey), force: force) {
            case .own: problem = force ? "The file holds this Mac's own publish; nothing to apply" : nil
            case .alreadyApplied: problem = nil
            case .apply: applyWhenNotDrawing(p, force: force)
            }
        }
        // the first look is done (a newer publish, if any, is applied or waiting for drawing to end): from here on this Mac's
        // own changes are published
        if baseline == nil { rebaseline() }
        postStatus()
    }

    /// Never in the middle of drawing: a stroke, drag or text edit under way in the editor or on the glass (asked again
    /// shortly), or the glass being lifted.
    private func applyWhenNotDrawing(_ p: DefaultsFile.Publish, force: Bool) {
        // only while the glass is being lifted and saved (LiveDraw.ended follows and looks again); draw mode merely being
        // open does not hold the other Macs' settings back - a stroke under way does (the editor's answer below)
        if LiveDraw.shared.closing {
            problem = "Defaults from \(p.mac) wait until draw mode has closed"
            return
        }
        editorIsDrawing { [weak self] drawing in
            guard let self else { return }
            if drawing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.check(force: force) }
            } else {
                self.apply(p)
            }
        }
    }

    /// The editor's answer to "defaultsBusy"; no answer within half a second (no editor yet, an older Dart side) = not drawing.
    private func editorIsDrawing(_ done: @escaping (Bool) -> Void) {
        guard let native = SnapLiteNative.shared else { return done(false) }
        var answered = false
        native.invoke("defaultsBusy", nil) { result in
            guard !answered else { return }
            answered = true
            done((result as? Bool) ?? false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !answered else { return }
            answered = true
            done(false)
        }
    }

    private func apply(_ p: DefaultsFile.Publish) {
        quietUntil = Date().addingTimeInterval(2)
        let r = DefaultsFile.apply(p.values, to: defaults, entries: Self.published, folders: p.folders, assets: p.assets,
                                   sharedFolder: folder)
        var kept: [String] = []
        if !r.missing.isEmpty { kept.append("Skipped \(r.missing.joined(separator: ", ")): that folder or file is not on this Mac") }
        if !r.rejected.isEmpty { kept.append("Kept this Mac's own \(r.rejected.joined(separator: ", ")): not valid here") }
        defaults.set(p.publishId, forKey: Self.lastAppliedIdKey)
        defaults.set(["at": Date(), "mac": p.mac, "note": kept.joined(separator: ". ")] as [String: Any], forKey: Self.lastAppliedKey)
        problem = nil
        // Live: the global keys are registered again (Shell) and Settings rebuilt; the theme everywhere; the toolbar list
        let touched = Set(r.applied)
        if touched.contains(where: { $0.hasPrefix("shortcut.") }) || touched.contains("hotkeys.mode") || touched.contains("matrixRain") {
            NotificationCenter.default.post(name: Shortcuts.changed, object: nil)
        }
        if touched.contains("appearance") { Theme.choice = Theme.choice }   // sets NSApp.appearance and posts Theme.changed
        if touched.contains("toolbarTools") { NotificationCenter.default.post(name: ToolbarPrefs.changed, object: nil) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        SnapLiteNative.shared?.invoke("defaultsChanged", r.applied)   // the editor reads its settings again
        // one toast for a run of publishes (someone adjusting settings on the other Mac), not one per change
        if Date().timeIntervalSince(lastToast) > 20 {
            Toast.show("Defaults updated from \(p.mac)", symbol: "arrow.triangle.2.circlepath")
        }
        lastToast = Date()
        // what this Mac holds now is what was published: not a change of its own. Again once the editor has settled.
        rebaseline()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in self?.rebaseline() }
        postStatus()
    }

    // MARK: - Status line

    private func noteSeen(_ p: DefaultsFile.Publish) {
        defaults.set(["at": p.publishedAt, "mac": p.mac, "own": p.installId == installId] as [String: Any], forKey: Self.lastPublishedKey)
    }

    private func postStatus() {
        NotificationCenter.default.post(name: Self.statusChanged, object: nil)
    }

    /// Last published: when and from which Mac; last applied: when and from which Mac; and what went wrong, if anything.
    var statusLine: String {
        guard folder != nil else { return "Off: choose a shared folder to publish or receive defaults." }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        var line: String
        let mode = autoPublish ? "Automatic. " : ""
        if let seen = defaults.dictionary(forKey: Self.lastPublishedKey), let at = seen["at"] as? Date {
            let own = (seen["own"] as? Bool) == true ? " (this Mac)" : ""
            line = "Last published \(f.string(from: at)) from \(seen["mac"] as? String ?? "a Mac")\(own)"
        } else {
            line = "Nothing published yet"
        }
        if let done = defaults.dictionary(forKey: Self.lastAppliedKey), let at = done["at"] as? Date {
            line += "; last applied \(f.string(from: at)) from \(done["mac"] as? String ?? "a Mac")."
            if let note = done["note"] as? String, !note.isEmpty { line += " \(note)." }   // keys skipped or kept then
        } else {
            line += "; nothing applied here yet."
        }
        if let problem { line += " \(problem)." }
        return mode + line
    }
}
