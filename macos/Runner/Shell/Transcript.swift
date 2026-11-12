import AVFoundation
import Foundation
import Speech

// The transcript of a screen recording, made ON THIS MAC ONLY: the sound is read from the movie file and recognised
// on-device (Speech's SpeechAnalyzer on macOS 26, else SFSpeechRecognizer with on-device recognition required). Nothing is
// ever sent to a server; a language without an on-device recogniser is reported, never sent elsewhere. No AppKit here:
// tools/transcript_test compiles this file on its own.

// MARK: - Lines and files

/// One line of a transcript: what was said between `start` and `end` (seconds from the start of the movie).
struct TranscriptLine: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// The transcript files next to a movie, with the movie's own name: "SnapNow Recording ….txt" ([mm:ss] lines) and
/// "….srt" (captions, which players such as IINA and VLC load with the movie).
enum TranscriptFormat {
    static func sidecars(for movie: URL) -> (text: URL, captions: URL) {
        let base = movie.deletingPathExtension()
        return (base.appendingPathExtension("txt"), base.appendingPathExtension("srt"))
    }

    /// [mm:ss]; [h:mm:ss] on every line of a transcript that reaches an hour, so the column stays even.
    static func stamp(_ seconds: Double, hours: Bool) -> String {
        let s = max(0, Int(seconds))
        return hours ? String(format: "[%d:%02d:%02d]", s / 3600, s % 3600 / 60, s % 60) : String(format: "[%02d:%02d]", s / 60, s % 60)
    }

    static let noSpeech = "(No speech was recognised in this recording.)"

    /// The .txt: one "[mm:ss] what was said" line per spoken line.
    static func text(_ lines: [TranscriptLine]) -> String {
        guard !lines.isEmpty else { return noSpeech + "\n" }
        let hours = (lines.map(\.start).max() ?? 0) >= 3600
        return lines.map { "\(stamp($0.start, hours: hours)) \($0.text)" }.joined(separator: "\n") + "\n"
    }

    /// 00:01:02,345
    static func srtTime(_ seconds: Double) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// The .srt: numbered cues, each on screen while it is said.
    static func srt(_ lines: [TranscriptLine]) -> String {
        captions(lines).enumerated()
            .map { i, c in "\(i + 1)\n\(srtTime(c.start)) --> \(srtTime(c.end))\n\(c.text)\n" }
            .joined(separator: "\n")
    }

    static let cueChars = 84

    /// Lines cut into caption-sized cues (at most two rows of about 42 characters), the time shared out by length; each
    /// cue stays at least 0.8 s unless the next one starts sooner, and never overlaps it.
    static func captions(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var cues: [TranscriptLine] = []
        for line in lines {
            var groups: [[String]] = [[]]
            for word in line.text.split(whereSeparator: \.isWhitespace).map(String.init) {
                let current = groups[groups.count - 1].joined(separator: " ")
                if !groups[groups.count - 1].isEmpty && current.count + 1 + word.count > cueChars {
                    groups.append([word])
                } else {
                    groups[groups.count - 1].append(word)
                }
            }
            let texts = groups.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }
            let total = Double(texts.reduce(0) { $0 + $1.count })
            let span = max(0, line.end - line.start)
            var t = line.start
            for text in texts {
                let d = total > 0 ? span * Double(text.count) / total : span
                cues.append(TranscriptLine(start: t, end: t + d, text: wrap(text)))
                t += d
            }
        }
        for i in cues.indices {
            var end = max(cues[i].end, cues[i].start + 0.8)
            if i + 1 < cues.count { end = min(end, max(cues[i + 1].start, cues[i].start + 0.01)) }
            cues[i].end = end
        }
        return cues
    }

    /// At most two rows: a cue longer than 42 characters breaks at the space nearest its middle.
    static func wrap(_ text: String) -> String {
        guard text.count > 42 else { return text }
        let chars = Array(text)
        let middle = chars.count / 2
        guard let cut = chars.indices.filter({ chars[$0] == " " }).min(by: { abs($0 - middle) < abs($1 - middle) }) else { return text }
        return String(chars[..<cut]) + "\n" + String(chars[(cut + 1)...])
    }

    /// Timed words (the older recogniser gives words, not sentences) grouped into lines: a new line after a pause of a
    /// second or more, after a sentence once the line has some length, or when it gets long.
    static func lines(fromWords words: [TranscriptLine]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        var current: TranscriptLine?
        for w in words {
            let text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if var c = current, w.start - c.end < 1.0, c.text.count + 1 + text.count <= 160 {
                c.text += " " + text
                c.end = w.end
                current = c
            } else {
                if let c = current { out.append(c) }
                current = TranscriptLine(start: w.start, end: w.end, text: text)
            }
            if let c = current, c.text.count >= 60, let last = c.text.last, ".?!".contains(last) {
                out.append(c)
                current = nil
            }
        }
        if let c = current { out.append(c) }
        return out
    }
}

// MARK: - Errors

enum TranscriptError: LocalizedError {
    case unavailable(String)     // no on-device recogniser for this language on this Mac
    case noAudio                 // the movie has no sound
    case notAllowed              // Speech Recognition is turned off for SnapNow
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let language): return "On-device transcription is not available for \(language) on this Mac"
        case .noAudio: return "This recording has no sound"
        case .notAllowed: return "Speech Recognition is not allowed for SnapNow"
        case .failed(let why): return why
        }
    }
}

// MARK: - Audio

/// The movie's sound (every audio track mixed: the computer's sound and the microphone) in the recogniser's format, from
/// `from` seconds on, one buffer at a time: an hour-long recording is read as it is transcribed, never held in memory.
final class TranscriptAudio: @unchecked Sendable {
    let format: AVAudioFormat
    let duration: Double
    /// Where the first buffer begins (seconds into the movie); results are counted from here.
    private(set) var startTime: Double = 0
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let readFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var pending: AVAudioPCMBuffer?
    private let lock = NSLock()
    private var reached = 0.0
    private var stopped = false
    private(set) var failure: Error?

    init(movie: URL, format: AVAudioFormat, from: Double) async throws {
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TranscriptError.noAudio }
        duration = CMTimeGetSeconds(try await asset.load(.duration))
        let reader = try AVAssetReader(asset: asset)
        if from > 0 { reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), duration: .positiveInfinity) }
        // Read as interleaved samples of the target's kind; converted only if the target wants separate channels
        let read = AVAudioFormat(commonFormat: format.commonFormat, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: true) ?? format
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        switch format.commonFormat {
        case .pcmFormatInt16: settings[AVLinearPCMBitDepthKey] = 16; settings[AVLinearPCMIsFloatKey] = false
        case .pcmFormatInt32: settings[AVLinearPCMBitDepthKey] = 32; settings[AVLinearPCMIsFloatKey] = false
        case .pcmFormatFloat64: settings[AVLinearPCMBitDepthKey] = 64; settings[AVLinearPCMIsFloatKey] = true
        default: settings[AVLinearPCMBitDepthKey] = 32; settings[AVLinearPCMIsFloatKey] = true
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscriptError.failed("The recording's sound cannot be read") }
        reader.add(output)
        guard reader.startReading() else { throw TranscriptError.failed(reader.error?.localizedDescription ?? "The recording's sound cannot be read") }
        self.format = format
        self.reader = reader
        self.output = output
        readFormat = read
        converter = read == format ? nil : AVAudioConverter(from: read, to: format)
        startTime = from
        reached = from
        if let (buffer, time) = readOne() {
            pending = buffer
            startTime = time
            reached = time + Double(buffer.frameLength) / format.sampleRate
        }
    }

    /// Seconds into the movie read so far.
    var position: Double { lock.lock(); defer { lock.unlock() }; return reached }

    /// Ends the reading early (the movie was deleted, or the app is going away): next() returns nil from now on.
    func stop() { lock.lock(); stopped = true; lock.unlock() }

    /// The next buffer, or nil at the end.
    func next() -> AVAudioPCMBuffer? {
        lock.lock(); let halt = stopped; lock.unlock()
        if halt { reader.cancelReading(); return nil }
        if let p = pending { pending = nil; return p }
        guard let (buffer, time) = readOne() else {
            if reader.status == .failed { failure = reader.error ?? TranscriptError.failed("The recording's sound could not be read") }
            return nil
        }
        lock.lock(); reached = time + Double(buffer.frameLength) / format.sampleRate; lock.unlock()
        return buffer
    }

    private func readOne() -> (AVAudioPCMBuffer, Double)? {
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let raw = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            raw.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: raw.mutableAudioBufferList) == noErr else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let converter else { return (raw, time) }
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: raw.frameLength), (try? converter.convert(to: out, from: raw)) != nil else { continue }
            return (out, time)
        }
        return nil
    }
}

// MARK: - Engine

enum TranscriptEngine {
    /// The language a transcript is made in when none is chosen: the system's first preferred language.
    static var systemLanguage: String { Locale.preferredLanguages.first ?? Locale.current.identifier }

    static func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Languages this Mac can transcribe on-device (identifiers).
    static func supportedLanguages() async -> [String] {
        var ids = Set<String>()
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            for l in await SpeechTranscriber.supportedLocales { ids.insert(l.identifier) }
        }
        for l in SFSpeechRecognizer.supportedLocales() where SFSpeechRecognizer(locale: l)?.supportsOnDeviceRecognition == true {
            ids.insert(l.identifier)
        }
        return ids.sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    /// Transcribes `movie` from `from` seconds on, on this Mac only. `line` gets each finished line (times in movie
    /// seconds) in order; `progress` how far the reading has got (0…1); `audio` the reader, so the caller can stop it.
    static func run(movie: URL, language: String, from: Double, started: @escaping (TranscriptAudio) -> Void = { _ in },
                    line: @escaping (TranscriptLine) -> Void, progress: @escaping (Double) -> Void) async throws {
        let locale = Locale(identifier: language)
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable, let found = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            try await analyzer(movie: movie, locale: found, from: from, started: started, line: line, progress: progress)
        } else {
            try await recognizer(movie: movie, locale: locale, from: from, started: started, line: line, progress: progress)
        }
    }

    /// macOS 26 and later: SpeechAnalyzer with a SpeechTranscriber, fed the whole sound as one stream (sentences keep
    /// their context across what would be chunk boundaries); results carry their time range.
    @available(macOS 26.0, *)
    private static func analyzer(movie: URL, locale: Locale, from: Double, started: (TranscriptAudio) -> Void,
                                 line: @escaping (TranscriptLine) -> Void, progress: @escaping (Double) -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .installed: break
        case .unsupported: throw TranscriptError.unavailable(displayName(locale.identifier))
        default:
            // The language's speech model comes from Apple once; the recording itself never leaves the Mac
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) { try await request.downloadAndInstall() }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw TranscriptError.failed("The speech recogniser offered no audio format")
        }
        let audio = try await TranscriptAudio(movie: movie, format: format, from: from)
        started(audio)
        let offset = audio.startTime
        let analyzer = SpeechAnalyzer(modules: modules)
        let collect = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    line(TranscriptLine(start: offset + result.range.start.seconds, end: offset + result.range.end.seconds, text: text))
                }
            }
        }
        let input = AsyncStream<AnalyzerInput>(unfolding: {
            guard let buffer = audio.next() else { return nil }
            progress(audio.duration > 0 ? min(1, audio.position / audio.duration) : 0)
            return AnalyzerInput(buffer: buffer)
        })
        do {
            if let end = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try await collect.value
        } catch {
            collect.cancel()
            throw error
        }
        if let failure = audio.failure { throw failure }
    }

    /// Before macOS 26: SFSpeechRecognizer with on-device recognition required, a minute of sound per request.
    private static func recognizer(movie: URL, locale: Locale, from: Double, started: (TranscriptAudio) -> Void,
                                   line: @escaping (TranscriptLine) -> Void, progress: @escaping (Double) -> Void) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptError.unavailable(displayName(locale.identifier))
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw TranscriptError.notAllowed }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw TranscriptError.failed("No audio format for the speech recogniser")
        }
        let audio = try await TranscriptAudio(movie: movie, format: format, from: from)
        started(audio)
        var chunkStart = audio.startTime
        while true {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true      // never the network
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            var fed = 0.0
            while fed < 60, let buffer = audio.next() {
                request.append(buffer)
                fed += Double(buffer.frameLength) / format.sampleRate
            }
            if fed == 0 { break }
            request.endAudio()
            progress(audio.duration > 0 ? min(1, audio.position / audio.duration) : 0)
            let words = try await recognize(recognizer, request)
            let start = chunkStart
            TranscriptFormat.lines(fromWords: words.map { TranscriptLine(start: start + $0.start, end: start + $0.end, text: $0.text) })
                .forEach(line)
            chunkStart += fed
        }
        if let failure = audio.failure { throw failure }
    }

    private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest) async throws -> [TranscriptLine] {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { c in
            recognizer.recognitionTask(with: request) { result, error in
                guard !once.done else { return }
                if let result, result.isFinal {
                    once.done = true
                    c.resume(returning: result.bestTranscription.segments.map {
                        TranscriptLine(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                    })
                } else if let error {
                    once.done = true
                    let e = error as NSError
                    // "No speech detected" is a silent minute, not a failure
                    if e.domain == "kAFAssistantErrorDomain" && e.code == 1110 { c.resume(returning: []) } else { c.resume(throwing: error) }
                }
            }
        }
    }
}
