import AppKit
import AVFoundation
import ScreenCaptureKit

// MARK: - Results and events

/// What a finished (or recovered) recording looks like to the rest of the app.
struct RecordingSummary {
    let url: URL
    let seconds: Double
    let bytes: Int64

    var text: String { "\(Recorder.clock(seconds)) · \(Recorder.sizeText(bytes))" }
}

enum RecorderHealth {
    case idle
    case starting     // the window is up, no frame has been written yet
    case recording    // frames are being written
    case stalled      // nothing new has been written for a few seconds
    case stopped      // ended unexpectedly; the pill stays up until it is dismissed
}

enum RecorderEvent {
    case started
    case stalled
    case resumed
    case finished(RecordingSummary, Recorder.EndReason)
    case failed(RecordingSummary?, String)    // ended unexpectedly; the movie so far is kept
}

// MARK: - Recorder

/// Screen recording with ScreenCaptureKit and an AVAssetWriter that writes a FRAGMENTED movie straight into the
/// Library folder: a new fragment lands on disk every two seconds, so whatever happens to the app (kill, crash,
/// reinstall, power loss) the file already there plays up to its last fragment. A marker file names the recording
/// in progress; on the next launch an unfinished one is kept and announced.
///
/// What is shown while recording is driven by what has really been written (frames appended, bytes on disk), not
/// by a flag: the timer is the length of the movie so far, and when nothing new is written for a few seconds the
/// pill says so.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = Recorder()

    enum EndReason { case user, quit, sleep }

    /// Called on the main thread.
    var onEvent: ((RecorderEvent) -> Void)?

    /// Posted (main thread) when a recording starts or ends, for windows whose sharing depends on it.
    static let recordingChanged = Notification.Name("SnapNowRecordingChanged")

    // Main thread
    private(set) var health: RecorderHealth = .idle {
        didSet {
            let was = oldValue == .starting || oldValue == .recording || oldValue == .stalled
            if was != isRecording { NotificationCenter.default.post(name: Self.recordingChanged, object: nil) }
        }
    }
    private(set) var startedAt: Date?
    private var hud: RecordingHUD?
    private var uiTimer: Timer?
    private var stopRequested = false
    private var pendingStop: (reason: EndReason, source: String, done: (() -> Void)?)?
    /// How the last recording ended and who or what ended it (status.json "lastEndReason"; see noteEnd).
    private(set) var lastEnd: [String: Any]?
    private var appliedExclusions = Set<CGWindowID>()
    private var exclusionBusy = false
    private var microphoneOn = false
    private var finalizing = false                 // the movie is being closed; no new recording until it is done
    private var waiters: [() -> Void] = []
    private var stillsHidingOverlays = 0

    var isRecording: Bool { health == .starting || health == .recording || health == .stalled }
    var isFinishing: Bool { finalizing }

    // Capture queue
    private let queue = DispatchQueue(label: "snapnow.recorder")
    private var stream: SCStream?
    private var display: SCDisplay?
    private var movieWriter: MovieWriter?
    private var url: URL?
    private var callbacks: [String: Int] = [:]      // what the capture delivered, by kind (diagnostics)
    private var lastCallback = Date.distantPast      // the capture's latest delivery of any kind, an unchanged frame included
    private var sawIdleFrames = false                // this Mac reports an unchanged screen with "idle" frames
    private var beat: DispatchSourceTimer?
    private var syntheticTimer: DispatchSourceTimer?   // tests only
    private var closing = false
    private var frozen = false          // diagnostics: drop everything, as a hung capture would
    private var lastSize: Int64 = 0

    // Progress, written on the queue, read on the main thread
    private struct Progress {
        var seconds = 0.0
        var bytes: Int64 = 0
        var firstFrame = false
        var lastAppend = Date.distantPast
        var lastGrowth = Date.distantPast
        var failure: String?
        var failureDetail: String?     // the capture's error domain and code, for the end's record
    }
    private let lock = NSLock()
    private var progress = Progress()

    private func snapshot() -> Progress { lock.lock(); defer { lock.unlock() }; return progress }
    private func update(_ change: (inout Progress) -> Void) { lock.lock(); change(&progress); lock.unlock() }

    /// Seconds of movie written so far (not wall-clock time).
    var elapsed: TimeInterval { snapshot().seconds }
    var bytesWritten: Int64 { snapshot().bytes }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    // MARK: Start

    /// `rect` is in Cocoa global coordinates. `completion` (main thread) tells whether capture began; the first
    /// written frame is announced separately with `.started`.
    func start(rect: CGRect, microphone: Bool, showClicks: Bool, synthetic: Bool = false, systemAudio: Bool? = nil,
               completion: @escaping (Bool) -> Void) {
        guard !isRecording, !finalizing else { completion(false); return }
        dismissEndedPill()
        guard let screen = NSScreen.screens.max(by: { overlap($0.frame, rect) < overlap($1.frame, rect) }),
              case let area = rect.intersection(screen.frame), area.width >= 16, area.height >= 16,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            completion(false); return
        }
        let full = abs(area.width - screen.frame.width) < 2 && abs(area.height - screen.frame.height) < 2
        var movie = CaptureFiles.newCaptureURL(prefix: "SnapNow Recording", ext: "mov")
        if synthetic, let folder = RecorderTestControl.folder {   // generated test movies stay out of the Library
            movie = folder.appendingPathComponent(movie.lastPathComponent)
        }

        health = .starting
        startedAt = Date()
        stopRequested = false
        pendingStop = nil
        microphoneOn = microphone
        lock.lock(); progress = Progress(); lock.unlock()
        appliedExclusions = []
        let pill = RecordingHUD(area: area, screen: screen, fullScreen: full, microphone: microphone) { [weak self] in
            self?.stop(source: "the Stop button on the recording's bar")
        }
        pill.show()
        hud = pill
        startUITimer()

        Task { @MainActor in
            do {
                try await self.begin(area: area, screen: screen, displayID: displayID, movie: movie,
                                     microphone: microphone, systemAudio: systemAudio ?? Prefs.onByDefault(Prefs.systemAudio),
                                     showClicks: showClicks, synthetic: synthetic)
                completion(true)
                if self.stopRequested, let p = self.pendingStop { self.finish(reason: p.reason, source: p.source, done: p.done) }
            } catch {
                NSLog("SnapNow recorder: could not start: \(Self.describe(error)) [\(error)]")
                self.abandon(movie)
                self.pendingStop?.done?()
                self.pendingStop = nil
                Toast.show("Recording could not start: \(Self.describe(error))", symbol: "exclamationmark.triangle.fill")
                completion(false)
            }
        }
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    private static func describe(_ error: Error) -> String {
        (error as? RecorderError)?.text ?? error.localizedDescription
    }

    private struct RecorderError: Error {
        let text: String
    }

    @MainActor
    private func begin(area: CGRect, screen: NSScreen, displayID: CGDirectDisplayID, movie: URL,
                       microphone: Bool, systemAudio: Bool, showClicks: Bool, synthetic: Bool) async throws {
        // `synthetic` (tests only, see RecorderTestControl) feeds generated pictures through the same writer
        // and health check, for a Mac whose display cannot be captured at the moment.
        var display: SCDisplay?
        var filter: SCContentFilter?
        var scale = screen.backingScaleFactor
        if !synthetic {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let found = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError(text: "the display is not available")
            }
            let hidden = overlayWindowIDs
            let f = SCContentFilter(display: found, excludingWindows: content.windows.filter { hidden.contains($0.windowID) })
            appliedExclusions = Set(content.windows.map(\.windowID)).intersection(hidden)
            display = found
            filter = f
            scale = max(1, CGFloat(f.pointPixelScale))
        }
        // Not every Retina pixel: a size that keeps text crisp (at least a pixel per point) without doubling the file
        let quality = RecordingQuality.current
        scale = MovieWriter.outputScale(points: area.size, backing: scale, quality: quality)

        let width = Int(area.width * scale) & ~1
        let height = Int(area.height * scale) & ~1
        var withMic = false
        var withSystem = false
        var config: SCStreamConfiguration?
        if filter != nil {
            let c = SCStreamConfiguration()
            // sourceRect is in points from the top-left of the display
            c.sourceRect = CGRect(x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY,
                                  width: area.width, height: area.height)
            c.width = width
            c.height = height
            c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            c.queueDepth = 6
            c.showsCursor = true
            c.pixelFormat = kCVPixelFormatType_32BGRA
            c.captureResolution = .best   // sampled from every Retina pixel and scaled down by the capture, so text stays crisp
            // The computer's sound (what the apps play: a call, a video) on its own track; SnapNow's own sounds stay out
            if systemAudio {
                c.capturesAudio = true
                c.excludesCurrentProcessAudio = true
                c.sampleRate = 48_000
                c.channelCount = 2
                withSystem = true
            }
            if #available(macOS 15.0, *) {
                c.showMouseClicks = showClicks
                if microphone { c.captureMicrophone = true; withMic = true }
            }
            config = c
        }

        // The file itself (tracks, fragments, keeping it going on a still screen): MovieWriter
        let w = try MovieWriter(url: movie, width: width, height: height, systemAudio: withSystem, microphone: withMic, quality: quality)
        RecordingMarker.write(movie, started: startedAt ?? Date())

        var s: SCStream?
        if let filter, let config {
            let made = SCStream(filter: filter, configuration: config, delegate: self)
            try made.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if withSystem { try made.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if withMic, #available(macOS 15.0, *) { try made.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
            s = made
        }

        queue.sync {
            self.stream = s; self.display = display; self.movieWriter = w; self.url = movie
            self.callbacks = [:]; self.lastCallback = Date(); self.sawIdleFrames = false
            self.closing = false; self.frozen = false; self.lastSize = 0
            self.startHeartbeat()
            if synthetic { self.startSyntheticFrames(width: width, height: height) }
        }
        try await s?.startCapture()
    }

    /// Tests only: a moving picture, 30 times a second, delivered like captured frames.
    private func startSyntheticFrames(width: Int, height: Int) {
        var n = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in
            guard let self, !self.closing, !self.frozen else { return }
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
            guard let buffer = made else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                for y in Swift.stride(from: 0, to: height, by: 4) {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in Swift.stride(from: 0, to: width * 4, by: 16) { row[x] = UInt8((x / 16 + n * 3) & 255); row[x + 1] = UInt8((y / 4 + n) & 255); row[x + 2] = 90; row[x + 3] = 255 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            n += 1
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            if let format { CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) }
            if let sample { self.lastCallback = Date(); self.movieWriter?.appendVideo(sample) }
        }
        t.resume()
        syntheticTimer = t
    }

    /// Undoes a start that never got going. The empty file is removed; nothing was recorded.
    private func abandon(_ movie: URL) {
        queue.sync {
            beat?.cancel(); beat = nil
            syntheticTimer?.cancel(); syntheticTimer = nil
            movieWriter?.cancel()
            movieWriter = nil; stream = nil; url = nil
        }
        try? FileManager.default.removeItem(at: movie)
        RecordingMarker.clear()
        teardownUI()
        health = .idle
        startedAt = nil
    }

    // MARK: Writing (capture queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !closing, !frozen, let m = movieWriter else { return }
        lastCallback = Date()
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if type == .screen {
            // Only a "complete" frame carries a new picture; an "idle" one says the screen has not changed
            let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
            switch (info?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) {
            case .complete?:
                callbacks["screen.complete", default: 0] += 1
                m.appendVideo(sampleBuffer)
            case .idle?:
                callbacks["screen.idle", default: 0] += 1
                sawIdleFrames = true
            default:
                callbacks["screen.other", default: 0] += 1
            }
        } else if type == .audio {
            callbacks["audio", default: 0] += 1
            m.appendAudio(sampleBuffer, track: .system, now: now)
        } else if #available(macOS 15.0, *), type == .microphone {
            callbacks["microphone", default: 0] += 1
            m.appendAudio(sampleBuffer, track: .microphone, now: now)
        }
    }

    /// Four times a second: the movie is kept going while the capture is alive (MovieWriter.tick: a still screen's picture
    /// again, silence in a quiet sound track, waiting samples in), the file's size is read, and what the pill and the
    /// health check show is taken from what has really been written.
    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.heartbeat() }
        t.resume()
        beat = t
    }

    /// Whether the capture itself still delivers. On a Mac that reports an unchanged screen with idle frames, 5 s without
    /// any delivery means the capture is gone; where it sends nothing for a still screen, a still screen and a dead capture
    /// look the same, and a stream error (didStopWithError) or a writer that stops taking samples is what tells.
    private var captureAlive: Bool { !sawIdleFrames || Date().timeIntervalSince(lastCallback) < 5 }

    private func heartbeat() {
        guard !closing, !frozen, let m = movieWriter else { return }
        if let url, let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
            if size > lastSize { update { $0.lastGrowth = Date() } }
            lastSize = size
            update { $0.bytes = size }
        }
        if captureAlive { m.tick(now: CMClockGetTime(CMClockGetHostTimeClock())) }
        if let why = m.failure { fail(why) }
        let seconds = m.seconds, started = m.started, wrote = m.lastWrite
        update {
            $0.seconds = seconds
            $0.firstFrame = started
            if wrote > $0.lastAppend { $0.lastAppend = wrote }
            if started && $0.lastGrowth == .distantPast { $0.lastGrowth = Date() }
        }
    }

    /// For the test control's status.json: what the capture delivered and what the movie writer did with it.
    var diagnosticsSnapshot: [String: Any] {
        queue.sync {
            var d: [String: Any] = ["callbacks": callbacks, "sawIdleFrames": sawIdleFrames,
                                    "secondsSinceCaptureDelivered": min(Date().timeIntervalSince(lastCallback), 1e9)]
            if let m = movieWriter { d["writer"] = m.stats; d["movieSeconds"] = m.seconds; d["encoder"] = m.encoder }
            return d
        }
    }

    /// The writer or the stream gave up. What is on disk is kept; the main thread is told through `failure`.
    private func fail(_ reason: String) {
        guard snapshot().failure == nil else { return }
        update { $0.failure = reason }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let e = error as NSError
        update { if $0.failureDetail == nil { $0.failureDetail = "\(e.domain) \(e.code)" } }
        fail("the screen capture stopped (\(error.localizedDescription))")
    }

    // MARK: Health and UI (main thread)

    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(uiTimer!, forMode: .common)
    }

    private func isStalled(_ p: Progress) -> Bool {
        let now = Date()
        return now.timeIntervalSince(p.lastAppend) > 5 || now.timeIntervalSince(p.lastGrowth) > 8
    }

    private func tick() {
        guard health == .starting || health == .recording || health == .stalled else { return }
        let p = snapshot()
        if let reason = p.failure { endUnexpectedly(reason); return }
        switch health {
        case .starting:
            if p.firstFrame {
                health = .recording
                hud?.setState(.recording)
                onEvent?(.started)
            } else if let started = startedAt, Date().timeIntervalSince(started) > 8 {
                endUnexpectedly("no picture arrived from the screen")
                return
            }
        case .recording:
            if isStalled(p) {
                health = .stalled
                hud?.setState(.stalled)
                onEvent?(.stalled)
            }
        case .stalled:
            if !isStalled(p) {
                health = .recording
                hud?.setState(.recording)
                onEvent?(.resumed)
            }
        default: break
        }
        hud?.update(seconds: p.seconds, bytes: p.bytes)
        refreshExclusions()
    }

    /// The recording's own two windows, the pill and the border: the only windows left out of the movie. Everything
    /// else on screen is recorded, SnapNow's own windows included (draw mode's glass and drawing, the Matrix rain, the
    /// editor, notices), because a recording is of what you see. ScreenCaptureKit does not reliably honour sharingType,
    /// so the two are listed in the filter by number. Captures taken during a recording leave them out as well.
    var overlayWindowIDs: Set<CGWindowID> { hud?.windowIDs ?? [] }

    /// Called every half second: windows ScreenCaptureKit did not list yet when the recording began are added. Windows
    /// off screen are listed too, so the pill stepping aside for a capture does not change the filter.
    private func refreshExclusions() {
        guard isRecording, !exclusionBusy else { return }
        let wanted = overlayWindowIDs
        guard wanted != appliedExclusions else { return }
        exclusionBusy = true
        Task { @MainActor in
            defer { self.exclusionBusy = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            var s: SCStream?, d: SCDisplay?
            self.queue.sync { s = self.stream; d = self.display }
            guard let s, let d else { return }
            let known = Set(content.windows.map(\.windowID))
            let filter = SCContentFilter(display: d, excludingWindows: content.windows.filter { wanted.contains($0.windowID) })
            try? await s.updateContentFilter(filter)
            // Windows ScreenCaptureKit does not list yet are tried again on the next tick
            self.appliedExclusions = wanted.isSubset(of: known) ? wanted : wanted.intersection(known)
        }
    }

    /// For a capture taken by /usr/sbin/screencapture, which cannot leave single windows out: the pill and the border
    /// step aside until the returned closure is called (main thread). They are not in the movie either way.
    func hideOverlaysForStill() -> () -> Void {
        stillsHidingOverlays += 1
        hud?.setVisible(false)
        var restored = false
        return { [weak self] in
            guard let self, !restored else { return }
            restored = true
            self.stillsHidingOverlays -= 1
            if self.stillsHidingOverlays == 0 { self.hud?.setVisible(true) }
        }
    }

    /// The movie being written, or the last one.
    var moviePath: String? { queue.sync { url?.path } }

    // MARK: Ending

    /// Stops and finalizes the movie, then reports `.finished`. Safe to call repeatedly. `source` says who asked (the Stop
    /// button, the menu, the shortcut, the test control, app quit, system sleep…): every end is recorded (noteEnd).
    func stop(reason: EndReason = .user, source: String, done: (() -> Void)? = nil) {
        if finalizing { if let done { waiters.append(done) }; return }
        if health == .starting && !stopRequested { stopRequested = true; pendingStop = (reason, source, done); return }
        guard isRecording else { done?(); return }
        finish(reason: reason, source: source, done: done)
    }

    /// Every end of a recording with who or what ended it: in the log, in recording-ends.log (kept across launches, so an
    /// end during a quit is still there) and in the test control's status.json at once. An end nobody asked for can then
    /// be traced. `unexpected`: not asked for by the user (a failure, sleep).
    private func noteEnd(source: String, unexpected: Bool, detail: String? = nil) {
        let seconds = snapshot().seconds
        var entry: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "pid": Int(getpid()), "source": source,
                                    "kind": unexpected ? "unexpected" : "stopped", "movieSeconds": (seconds * 100).rounded() / 100]
        if let detail { entry["detail"] = detail }
        if let path = queue.sync(execute: { url?.path }) { entry["movie"] = path }
        lastEnd = entry
        let line = "\(entry["at"]!) pid \(getpid()) \(unexpected ? "UNEXPECTED" : "stopped") after \(String(format: "%.1f", seconds)) s: \(source)"
            + (detail.map { " (\($0))" } ?? "")
        NSLog("SnapNow recorder: recording ended: \(line)")
        Self.appendEndLog(line)
        RecorderTestControl.recordingEnded()
    }

    /// ~/Library/Application Support/SnapNow/recording-ends.log, the last 200 ends.
    static var endsLog: URL { RecordingMarker.file.deletingLastPathComponent().appendingPathComponent("recording-ends.log") }

    static func recentEnds(_ n: Int) -> [String] {
        let text = (try? String(contentsOf: endsLog, encoding: .utf8)) ?? ""
        return Array(text.split(separator: "\n").suffix(n).map(String.init))
    }

    private static func appendEndLog(_ line: String) {
        let lines = recentEnds(199) + [line]
        try? (lines.joined(separator: "\n") + "\n").write(to: endsLog, atomically: true, encoding: .utf8)
    }

    private func finish(reason: EndReason, source: String, done: (() -> Void)?) {
        guard health == .recording || health == .stalled || health == .starting else { done?(); return }
        noteEnd(source: source, unexpected: reason == .sleep)
        uiTimer?.invalidate(); uiTimer = nil
        health = .idle
        finalizing = true
        let stopAt = CMClockGetTime(CMClockGetHostTimeClock())   // the movie runs to this moment, whatever the screen did
        let s = queue.sync { stream }
        Task { @MainActor in
            try? await s?.stopCapture()
            self.close(at: stopAt) {
                DispatchQueue.main.async {
                    let summary = self.summary()
                    RecordingMarker.clear()
                    if reason == .sleep {
                        // Not asked for by the user: the bar stays and says so, as for any other unexpected end
                        self.health = .stopped
                        self.hud?.hideBorder()
                        self.hud?.setEnded(reason: "the Mac went to sleep")
                        if let summary { self.hud?.update(seconds: summary.seconds, bytes: summary.bytes) }
                    } else {
                        self.teardownUI()
                    }
                    self.startedAt = nil
                    self.finalizing = false
                    NotificationCenter.default.post(name: Self.recordingChanged, object: nil)   // transcripts may go on now
                    RecorderTestControl.recordingEnded()   // and once more with the movie closed
                    if let summary { self.onEvent?(.finished(summary, reason)) }
                    done?()
                    let queued = self.waiters
                    self.waiters = []
                    queued.forEach { $0() }
                }
            }
        }
    }

    private func endUnexpectedly(_ reason: String) {
        guard isRecording else { return }
        noteEnd(source: "the recording failed: \(reason)", unexpected: true, detail: snapshot().failureDetail)
        uiTimer?.invalidate(); uiTimer = nil
        health = .stopped
        let s = queue.sync { stream }
        hud?.setEnded(reason: reason)
        Task { @MainActor in
            try? await s?.stopCapture()
            self.close(at: .zero) {   // ended on its own: the movie ends where its media does
                DispatchQueue.main.async {
                    let summary = self.summary()
                    RecordingMarker.clear()
                    self.hud?.hideBorder()
                    if let summary { self.hud?.update(seconds: summary.seconds, bytes: summary.bytes) }
                    self.startedAt = nil
                    self.onEvent?(.failed(summary, reason))
                    RecorderTestControl.recordingEnded()
                }
            }
        }
    }

    /// Finishes the movie at `stop` (MovieWriter.finish: the picture held and the sound filled up to it, then the final
    /// header). With no picture at all the empty file is removed.
    private func close(at stop: CMTime, _ done: @escaping () -> Void) {
        queue.async {
            self.closing = true
            self.beat?.cancel(); self.beat = nil
            self.syntheticTimer?.cancel(); self.syntheticTimer = nil
            guard let m = self.movieWriter else { done(); return }
            m.finish(at: stop) {
                self.queue.async {
                    if !FileManager.default.fileExists(atPath: m.url.path) { self.url = nil }
                    let seconds = m.seconds
                    self.update { $0.seconds = seconds }
                    done()
                }
            }
        }
    }

    private func summary() -> RecordingSummary? {
        guard let url = queue.sync(execute: { self.url }), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value) ?? 0
        return RecordingSummary(url: url, seconds: snapshot().seconds, bytes: bytes)
    }

    /// Last resort at termination: the run loop may already be going away, so wait (briefly) for the writer.
    func finalizeNowIfNeeded() {
        guard isRecording else { return }
        let gate = DispatchSemaphore(value: 0)
        close(at: CMClockGetTime(CMClockGetHostTimeClock())) { gate.signal() }
        _ = gate.wait(timeout: .now() + 4)
        RecordingMarker.clear()
    }

    private func teardownUI() {
        uiTimer?.invalidate(); uiTimer = nil
        hud?.hide(); hud = nil
    }

    /// The warning pill of an unexpected end stays until it is dismissed or the next recording starts.
    func dismissEndedPill() {
        guard health == .stopped else { return }
        health = .idle
        teardownUI()
    }

    // MARK: Diagnostics

    /// Hooks for tests (see RecorderTestControl): "stall" makes the writer see nothing, as a hung capture would;
    /// "resume" lifts that; "drop" ends the capture the way a failed stream does.
    func diagnostic(_ action: String) {
        switch action {
        case "stall": queue.async { self.frozen = true }
        case "resume": queue.async { self.frozen = false }
        case "drop": fail("the screen capture stopped (simulated)")
        default: break
        }
    }

    // MARK: Recovery

    /// On launch: a recording a previous run left unfinished is kept as it is (it already sits in the Library
    /// folder, playable up to its last fragment). Returns what was found.
    static func recoverUnfinished() async -> RecordingSummary? {
        guard let marker = RecordingMarker.read() else { return nil }
        if marker.pid != getpid(), kill(marker.pid, 0) == 0, RecordingMarker.isSnapNow(pid: marker.pid) { return nil }   // still being recorded by another run
        RecordingMarker.clear()
        let url = URL(fileURLWithPath: marker.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value) ?? 0
        let seconds = (try? await AVURLAsset(url: url).load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        return RecordingSummary(url: url, seconds: seconds.isFinite ? seconds : 0, bytes: bytes)
    }
}

// MARK: - Marker file

/// ~/Library/Application Support/SnapNow/recording.active: names the recording in progress. tools/install.sh
/// reads it to leave a running recording alone; the next launch reads it to find an unfinished one.
enum RecordingMarker {
    struct Content: Codable {
        let pid: Int32
        let path: String
        let started: Double
    }

    static var file: URL {
        if let path = ProcessInfo.processInfo.environment["SNAPNOW_RECORDING_MARKER"] { return URL(fileURLWithPath: path) }   // tests
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SnapNow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("recording.active")
    }

    static func write(_ movie: URL, started: Date) {
        let c = Content(pid: getpid(), path: movie.path, started: started.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: file, options: .atomic) }
    }

    static func read() -> Content? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Content.self, from: data)
    }

    static func clear() { try? FileManager.default.removeItem(at: file) }

    static func isSnapNow(pid: Int32) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "comm="]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.contains("SnapNow") ?? false
    }
}

// MARK: - On-screen state

enum HUDState { case recording, stalled }

/// The red border around what is being recorded (inside the screen edge for a full-screen recording) and the
/// pill with the pulsing dot, the movie's length, its size on disk, a microphone mark and Stop. Both windows ask
/// not to be shared and are listed in the capture's filter, so neither is in the movie. The pill is one level above
/// draw mode's glass, so Stop can be clicked while drawing; the border lets every click through.
final class RecordingHUD {
    private let area: CGRect
    private let screen: NSScreen
    private let fullScreen: Bool
    private let stopAction: () -> Void
    private var border: NSWindow?
    private var pill: NSPanel?
    private var borderView: BorderView?
    private let dot = NSView()
    private let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")!)
    private let time = NSTextField(labelWithString: "Starting…")
    private let size = NSTextField(labelWithString: "")
    private let mic = NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone on")!)
    private let button = PillButton(title: "Stop", target: nil, action: nil)
    private var state = HUDState.recording
    private var ended = false
    private let hasMicrophone: Bool

    init(area: CGRect, screen: NSScreen, fullScreen: Bool, microphone: Bool, stop: @escaping () -> Void) {
        self.area = area
        self.screen = screen
        self.fullScreen = fullScreen
        self.hasMicrophone = microphone
        self.stopAction = stop
    }

    private static let amber = NSColor.systemOrange

    func show() {
        buildBorder()
        buildPill()
        setState(.recording, initial: true)
    }

    func hide() {
        border?.orderOut(nil); border = nil
        pill?.orderOut(nil); pill = nil
    }

    func hideBorder() { border?.orderOut(nil); border = nil }

    var windowIDs: Set<CGWindowID> {
        let all: [NSWindow?] = [border, pill]
        return Set(all.compactMap { $0 }.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
    }

    func setVisible(_ visible: Bool) {
        let all: [NSWindow?] = [border, pill]
        for w in all.compactMap({ $0 }) { if visible { w.orderFrontRegardless() } else { w.orderOut(nil) } }
    }

    // MARK: Border

    private func buildBorder() {
        let inset: CGFloat = fullScreen ? 5 : 3
        let frame = fullScreen ? screen.frame : area.insetBy(dx: -inset, dy: -inset)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.sharingType = .none
        w.level = .statusBar
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = BorderView(thickness: inset, inside: fullScreen)
        w.contentView = view
        w.orderFrontRegardless()
        border = w
        borderView = view
    }

    // MARK: Pill

    private func buildPill() {
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10)])
        warn.contentTintColor = Self.amber
        warn.isHidden = true
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        time.textColor = .white
        size.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        size.textColor = NSColor.white.withAlphaComponent(0.7)
        mic.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        mic.isHidden = !hasMicrophone
        // Drawn by hand: a standard button looks disabled in a panel that never becomes key
        button.target = self
        button.action = #selector(buttonClicked)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = NSColor.systemRed.cgColor
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        button.widthAnchor.constraint(equalToConstant: 76).isActive = true
        styleButton("Stop", symbol: "stop.fill")

        let marker = NSView()
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.addSubview(dot)
        marker.addSubview(warn)
        warn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            marker.widthAnchor.constraint(equalToConstant: 16), marker.heightAnchor.constraint(equalToConstant: 16),
            dot.centerXAnchor.constraint(equalTo: marker.centerXAnchor), dot.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            warn.centerXAnchor.constraint(equalTo: marker.centerXAnchor), warn.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
        ])

        let stack = NSStackView(views: [marker, time, size, mic, button])
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        background.layer?.cornerRadius = 18
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        let fit = NSSize(width: max(stack.fittingSize.width, 200), height: 38)
        let panel = NSPanel(contentRect: NSRect(origin: origin(for: fit), size: fit), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true     // drag it out of the way if it covers something
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = background
        panel.orderFrontRegardless()
        self.pill = panel
    }

    /// Below the area when there is room, else above it, else at the bottom of the screen; for a full-screen
    /// recording at the bottom centre, above the Dock.
    private func origin(for size: NSSize) -> NSPoint {
        let visible = screen.visibleFrame
        var o: NSPoint
        if fullScreen {
            o = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 18)
        } else {
            o = NSPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 12)
            if o.y < visible.minY { o.y = area.maxY + 12 }
            if o.y + size.height > visible.maxY { o.y = visible.minY + 18 }
        }
        o.x = min(max(o.x, visible.minX + 8), visible.maxX - size.width - 8)
        return o
    }

    private func styleButton(_ title: String, symbol: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.contentTintColor = .white
        button.attributedTitle = NSAttributedString(string: " \(title)", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
    }

    @objc private func buttonClicked() {
        if ended { hide(); Recorder.shared.dismissEndedPill() } else { stopAction() }
    }

    // MARK: State

    func setState(_ new: HUDState, initial: Bool = false) {
        state = new
        let warning = new == .stalled
        dot.isHidden = warning
        warn.isHidden = !warning
        borderView?.color = warning ? Self.amber : .systemRed
        pill?.contentView?.layer?.borderColor = (warning ? Self.amber : NSColor.white.withAlphaComponent(0.14)).cgColor
        pill?.contentView?.layer?.borderWidth = warning ? 2 : 1
        dot.layer?.removeAnimation(forKey: "pulse")
        if !warning {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
        }
        if warning { time.stringValue = "Not recording" } else if !initial { time.stringValue = Recorder.clock(Recorder.shared.elapsed) }
        resizePill()
    }

    /// The recorder ended on its own: the pill stays, says so, and offers Dismiss.
    func setEnded(reason: String) {
        ended = true
        dot.isHidden = true
        warn.isHidden = false
        dot.layer?.removeAllAnimations()
        borderView?.color = Self.amber
        time.stringValue = "Recording stopped"
        pill?.contentView?.layer?.borderColor = Self.amber.cgColor
        pill?.contentView?.layer?.borderWidth = 2
        styleButton("Dismiss", symbol: "xmark")
        button.layer?.backgroundColor = NSColor(white: 0.32, alpha: 1).cgColor
        resizePill()
    }

    func update(seconds: Double, bytes: Int64) {
        if state == .recording, !ended, !time.stringValue.hasPrefix("Start") || seconds > 0 { time.stringValue = Recorder.clock(seconds) }
        size.stringValue = Recorder.sizeText(bytes)
        resizePill()
    }

    private func resizePill() {
        guard let pill, let stack = pill.contentView?.subviews.first as? NSStackView else { return }
        let width = max(stack.fittingSize.width, 200)
        guard abs(width - pill.frame.width) > 0.5 else { return }
        var f = pill.frame
        f.origin.x -= (width - f.width) / 2
        f.size.width = width
        pill.setFrame(f, display: true)
    }
}

/// The Stop bar is never key, so its button must take the first click.
private final class PillButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class BorderView: NSView {
    private let thickness: CGFloat
    private let inside: Bool
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    init(thickness: CGFloat, inside: Bool) {
        self.thickness = thickness
        self.inside = inside
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: thickness / 2, dy: thickness / 2))
        path.lineWidth = inside ? thickness : thickness - 1
        color.withAlphaComponent(inside ? 0.85 : 1).setStroke()
        path.stroke()
    }
}

// MARK: - Test control

/// Off unless the app is launched with SNAPNOW_TEST_CONTROL=<path of a JSON file>. Then SnapNow reads that file
/// whenever it changes and acts on its "action", so recordings and what runs beside them can be driven and checked
/// without clicking:
///   "start" ("fullScreen": bool, "mic": bool, "systemAudio": bool, "x","y","w","h", "synthetic": bool), "stop", "stall",
///   "resume", "drop"; "transcribe" ("path": a movie: makes its transcript now, as Make Transcript; status.json then has
///   "transcript" with its state, progress and sidecar paths);
///   "open" ("path": an image opened in the editor, as from Recent Captures),
///   "draw" (draw mode on/off, as a double-tap of Option), "matrix" (the rain on/off), "icon" (a left click on the menu
///   bar icon), "region" ("x","y","w","h": a region capture of that area without the picker), "screen" (Capture Full
///   Screen), "scroll" ("x","y","w","h": a scrolling capture of that area), "status" (writes status.json next to the
///   command file: recording, draw mode, rain, panel, editor window, Dock or menu bar app, front app, newest capture).
/// Areas are in points from the bottom-left of the main display. "synthetic" feeds generated pictures instead of the
/// screen (for a Mac whose display cannot be captured right now) and writes the movie next to the command file instead
/// of into the Library. SNAPNOW_RECORDING_MARKER=<path> moves the recording marker, so recovery can be tried on a file
/// outside the Library.
enum RecorderTestControl {
    private static let path = ProcessInfo.processInfo.environment["SNAPNOW_TEST_CONTROL"]
    /// Where generated test movies go: next to the command file.
    static var folder: URL? { path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } }

    private static var seen: Date?
    private static var transcriptPath: String?

    static func install() {
        guard let path else { return }
        NSLog("SnapNow test control on: \(path)")
        seen = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil   // an old command is not replayed
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            guard let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil, stamp != seen else { return }
            seen = stamp
            run(stamp: stamp)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The last commands handled (status.json "commands"), to see what was really acted on.
    private static var handled: [[String: Any]] = []
    private static let launched = Date()

    private static func run(stamp: Date) {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else { NSLog("SnapNow test control: the command file could not be read"); return }
        NSLog("SnapNow test control: \(action)")
        handled.append(["at": ISO8601DateFormatter().string(from: Date()), "action": action, "fileTime": stamp.timeIntervalSince1970])
        if handled.count > 20 { handled.removeFirst(handled.count - 20) }
        // A stop written before the recording now running began is an old command read again: never let it end this one
        if action == "stop", let began = Recorder.shared.startedAt, stamp < began {
            NSLog("SnapNow test control: ignored a stop written before the current recording began")
            handled[handled.count - 1]["ignored"] = "older than the current recording"
            return
        }
        let n = { (key: String, fallback: Double) in json[key] as? Double ?? fallback }
        let area = CGRect(x: n("x", 100), y: n("y", 100), width: n("w", 640), height: n("h", 400))
        switch action {
        case "start":
            let full = json["fullScreen"] as? Bool ?? false
            let rect = full ? NSScreen.screens[0].frame : area
            Recorder.shared.start(rect: rect, microphone: json["mic"] as? Bool ?? false, showClicks: true,
                                  synthetic: json["synthetic"] as? Bool ?? false, systemAudio: json["systemAudio"] as? Bool) { ok in
                NSLog("SnapNow test: start \(ok ? "ok" : "failed")")
            }
        case "stop": Recorder.shared.stop(source: "test control: stop command")
        case "transcribe":
            if let p = json["path"] as? String {
                transcriptPath = p
                Transcripts.shared.make(URL(fileURLWithPath: p), manual: true)
            }
        case "open": if let p = json["path"] as? String { Shell.shared.openEditor(URL(fileURLWithPath: p)) }
        case "draw": LiveDraw.shared.toggle()
        case "matrix": MatrixRain.shared.toggle()
        case "icon": Shell.shared.testIconClick()
        case "region": Shell.shared.testRegionCapture(area)
        case "screen": Shell.shared.capture(.screen)
        case "scroll": Shell.shared.testScrollCapture(area)
        case "status": writeStatus()
        default: Recorder.shared.diagnostic(action)
        }
    }

    /// A recording just ended: status.json at once (with lastEndReason), even if the app is about to quit.
    static func recordingEnded() {
        guard path != nil else { return }
        writeStatus()
    }

    /// status.json next to the command file: what is running right now, for a script to check.
    private static func writeStatus() {
        guard let folder else { return }
        let r = Recorder.shared
        let files = (try? FileManager.default.contentsOfDirectory(at: Capture.folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                   options: .skipsHiddenFiles)) ?? []
        func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var status = Shell.shared.testStatus
        status["recording"] = r.isRecording
        status["health"] = "\(r.health)"
        status["movie"] = r.moviePath ?? NSNull()
        status["overlayWindows"] = r.overlayWindowIDs.sorted().map { Int($0) }
        status["drawMode"] = LiveDraw.shared.active
        status["matrixRain"] = MatrixRain.shared.running
        let editor = NSApp.windows.first { $0 is MainFlutterWindow }
        status["editorVisible"] = editor?.isVisible ?? false
        status["editorParked"] = DockPresence.shared.parked
        status["dockApp"] = NSApp.activationPolicy() == .regular
        status["frontApp"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? NSNull()
        status["newestCapture"] = files.max { modified($0) < modified($1) }?.path ?? NSNull()
        if let p = transcriptPath { status["transcript"] = Transcripts.shared.state(p) }
        status["recorder"] = r.diagnosticsSnapshot
        status["lastEndReason"] = r.lastEnd ?? NSNull()
        status["recentEnds"] = Recorder.recentEnds(10)
        status["commands"] = handled
        status["pid"] = Int(getpid())
        status["launched"] = ISO8601DateFormatter().string(from: launched)
        let me = getpid()
        status["otherInstances"] = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .map(\.processIdentifier).filter { $0 != me }.map { Int($0) }
        status["time"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("status.json"), options: .atomic)
        }
    }
}
