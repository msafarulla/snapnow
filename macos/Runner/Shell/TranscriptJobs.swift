import AppKit
import CryptoKit

/// Transcripts of screen recordings (TranscriptEngine, on this Mac only), made one at a time in the background after a
/// recording ends, for a recovered unfinished one, or from the Library's Make Transcript. A job file in Application
/// Support keeps the lines so far and where the reading got to, saved every few seconds, so a quit or crash continues
/// there on the next launch. When done the .txt and .srt land next to the movie (TranscriptFormat.sidecars) and the job
/// file goes. The Library hears every change ("transcriptChanged") and asks with "transcriptStates".
final class Transcripts {
    static let shared = Transcripts()

    struct Job: Codable {
        var movie: String
        var language: String
        var lines: [TranscriptLine]
        var resumeAt: Double
        var manual: Bool
    }

    enum State: String { case none, queued, running, done, failed }

    // Main thread
    private var queue: [String] = []
    private var running: String?
    private var progress: [String: Double] = [:]
    private var messages: [String: String] = [:]      // why the last attempt failed, per movie
    private var lastNotice: [String: Date] = [:]
    private var current: RunningJob?
    /// The transcript stopped because a recording began: it goes on from where it was once the recording has ended.
    private var pausing: String?

    private init() {
        NotificationCenter.default.addObserver(forName: Recorder.recordingChanged, object: nil, queue: .main) { [weak self] _ in
            self?.recordingChanged()
        }
    }

    /// Transcripts never run while a screen is being recorded (nothing of them may touch a recording): a running one stops
    /// and keeps its place; all of them go on when the recording has been closed.
    private func recordingChanged() {
        if Recorder.shared.isRecording || Recorder.shared.isFinishing {
            if let movie = running, pausing == nil {
                pausing = movie
                current?.cancel()
            }
        } else {
            runNext()
        }
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapNow/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func jobURL(_ movie: String) -> URL {
        let digest = SHA256.hash(data: Data(movie.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(digest.prefix(24)) + ".json")
    }

    private static func load(_ url: URL) -> Job? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Job.self, from: $0) }
    }

    fileprivate static func save(_ job: Job) {
        if let data = try? JSONEncoder().encode(job) { try? data.write(to: jobURL(job.movie), options: .atomic) }
    }

    /// The language transcripts are made in: the one chosen in Settings, else the system language.
    static var language: String {
        let chosen = UserDefaults.standard.string(forKey: Prefs.transcriptLanguage) ?? ""
        return chosen.isEmpty ? TranscriptEngine.systemLanguage : chosen
    }

    // MARK: Starting

    /// At launch: transcripts a quit or crash cut short go on where they stopped.
    func resumeUnfinished() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let job = Self.load(file), FileManager.default.fileExists(atPath: job.movie) else { try? FileManager.default.removeItem(at: file); continue }
            if running != job.movie && !queue.contains(job.movie) { queue.append(job.movie) }
        }
        runNext()
    }

    /// After a recording (`manual` false: only with Transcribe Recordings on, and a movie without sound is skipped quietly)
    /// or from the Library's Make Transcript (`manual`: says what happened either way).
    func make(_ movie: URL, manual: Bool) {
        let path = movie.path
        guard manual || Prefs.onByDefault(Prefs.transcribe) else { return }
        guard running != path, !queue.contains(path), FileManager.default.fileExists(atPath: path) else { return }
        messages[path] = nil
        Self.save(Job(movie: path, language: Self.language, lines: [], resumeAt: 0, manual: manual))
        queue.append(path)
        notify(path)
        runNext()
    }

    /// The movie went to the Trash: its transcript is not made.
    func forget(_ movie: String) {
        queue.removeAll { $0 == movie }
        if running == movie { current?.cancel() }
        try? FileManager.default.removeItem(at: Self.jobURL(movie))
        progress[movie] = nil
        messages[movie] = nil
    }

    /// The movie was renamed: an unfinished transcript follows it and goes on from where it was.
    func moved(from old: String, to new: String) {
        let wasRunning = running == old
        if wasRunning { current?.cancel() }
        let queued = queue.contains(old)
        queue.removeAll { $0 == old }
        if var job = Self.load(Self.jobURL(old)) {
            if wasRunning, let c = current { job = c.snapshot }
            try? FileManager.default.removeItem(at: Self.jobURL(old))
            job.movie = new
            Self.save(job)
            if wasRunning || queued { queue.append(new) }
        }
        messages[new] = messages.removeValue(forKey: old)
        progress[old] = nil
        if !wasRunning { runNext() }   // a cancelled run starts the next one when it has wound down
    }

    // MARK: State

    /// What the Library shows for a movie: state, progress 0…1, the sidecar paths, and the reason of a failure.
    func state(_ movie: String) -> [String: Any] {
        let files = TranscriptFormat.sidecars(for: URL(fileURLWithPath: movie))
        let hasText = FileManager.default.fileExists(atPath: files.text.path)
        let s: State = running == movie ? .running : queue.contains(movie) ? .queued : messages[movie] != nil ? .failed : hasText ? .done : .none
        var info: [String: Any] = ["path": movie, "state": s.rawValue, "progress": progress[movie] ?? 0, "text": files.text.path,
                                   "captions": files.captions.path, "hasText": hasText,
                                   "hasCaptions": FileManager.default.fileExists(atPath: files.captions.path)]
        if let m = messages[movie] { info["message"] = m }
        return info
    }

    private func notify(_ movie: String) {
        SnapLiteNative.shared?.invoke("transcriptChanged", state(movie))
    }

    private func progressed(_ movie: String, _ value: Double) {
        guard running == movie else { return }
        progress[movie] = value
        // The Library hears about it twice a second at most
        if Date().timeIntervalSince(lastNotice[movie] ?? .distantPast) >= 0.5 {
            lastNotice[movie] = Date()
            notify(movie)
        }
    }

    // MARK: Running

    private func runNext() {
        guard running == nil, !queue.isEmpty, !Recorder.shared.isRecording, !Recorder.shared.isFinishing else { return }
        let path = queue.removeFirst()
        guard let job = Self.load(Self.jobURL(path)), FileManager.default.fileExists(atPath: path) else {
            try? FileManager.default.removeItem(at: Self.jobURL(path))
            runNext()
            return
        }
        running = path
        progress[path] = 0
        notify(path)
        let run = RunningJob(job)
        current = run
        Task.detached(priority: .utility) { [weak self] in
            var failure: Error?
            do {
                try await TranscriptEngine.run(
                    movie: URL(fileURLWithPath: path), language: job.language, from: job.resumeAt,
                    started: { run.attach($0) },
                    line: { run.add($0) },
                    progress: { p in DispatchQueue.main.async { self?.progressed(path, p) } })
            } catch {
                failure = error
            }
            let finished = run.finish()
            DispatchQueue.main.async { self?.ended(path, job: finished, cancelled: run.cancelled, failure: failure) }
        }
    }

    private func ended(_ movie: String, job: Job, cancelled: Bool, failure: Error?) {
        running = nil
        current = nil
        progress[movie] = nil
        lastNotice[movie] = nil
        let name = URL(fileURLWithPath: movie).deletingPathExtension().lastPathComponent
        if cancelled {
            // paused for a recording: kept with its lines and goes first again; trashed (job gone) or renamed (job saved
            // under the new name): nothing to write
            if pausing == movie {
                pausing = nil
                Self.save(job)
                queue.insert(movie, at: 0)
            }
        } else if let failure {
            try? FileManager.default.removeItem(at: Self.jobURL(movie))   // no endless retries; Make Transcript tries again
            switch failure as? TranscriptError {
            case .noAudio? where !job.manual:
                break   // a recording without sound: nothing to transcribe, nothing to say
            case .unavailable(let language)?:
                messages[movie] = failure.localizedDescription
                Toast.show("No transcript: \(language) can't be transcribed on this Mac", symbol: "captions.bubble",
                           footnote: "Transcripts are made on this Mac only; nothing was sent anywhere. Choose another language in Settings.",
                           lasting: true)
            case .notAllowed?:
                messages[movie] = failure.localizedDescription
                Toast.show("No transcript: Speech Recognition is off for SnapNow", symbol: "captions.bubble",
                           footnote: "System Settings › Privacy & Security › Speech Recognition", lasting: true)
            default:
                messages[movie] = failure.localizedDescription
                Toast.show("No transcript for \(name)", symbol: "exclamationmark.triangle.fill", footnote: failure.localizedDescription, lasting: true)
            }
        } else {
            let files = TranscriptFormat.sidecars(for: URL(fileURLWithPath: movie))
            do {
                try TranscriptFormat.text(job.lines).write(to: files.text, atomically: true, encoding: .utf8)
                if job.lines.isEmpty {
                    try? FileManager.default.removeItem(at: files.captions)   // no captions without speech
                } else {
                    try TranscriptFormat.srt(job.lines).write(to: files.captions, atomically: true, encoding: .utf8)
                }
                try? FileManager.default.removeItem(at: Self.jobURL(movie))
                messages[movie] = nil
                Toast.show(job.lines.isEmpty ? "No speech found in \(name)" : "Transcript ready", symbol: "captions.bubble.fill",
                           footnote: job.lines.isEmpty ? nil : "\(name).txt and .srt are next to the movie.")
            } catch {
                messages[movie] = error.localizedDescription
                Toast.show("The transcript could not be saved", symbol: "exclamationmark.triangle.fill", footnote: error.localizedDescription)
            }
        }
        notify(movie)
        runNext()
    }
}

/// One transcript in progress: lines come in on the engine's thread; the job file is rewritten at most every 3 s, so a
/// quit loses only the last few seconds of work.
private final class RunningJob: @unchecked Sendable {
    private let lock = NSLock()
    private var job: Transcripts.Job
    private var savedAt = Date.distantPast
    private var audio: TranscriptAudio?
    private(set) var cancelled = false

    init(_ job: Transcripts.Job) { self.job = job }

    func attach(_ audio: TranscriptAudio) {
        lock.lock(); self.audio = audio; let stop = cancelled; lock.unlock()
        if stop { audio.stop() }
    }

    func add(_ line: TranscriptLine) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        job.lines.append(line)
        job.resumeAt = max(job.resumeAt, line.end)
        let due = Date().timeIntervalSince(savedAt) >= 3
        if due { savedAt = Date() }
        let copy = job
        lock.unlock()
        if due { Transcripts.save(copy) }
    }

    var snapshot: Transcripts.Job { lock.lock(); defer { lock.unlock() }; return job }

    func cancel() {
        lock.lock(); cancelled = true; let a = audio; lock.unlock()
        a?.stop()
    }

    func finish() -> Transcripts.Job { snapshot }
}
