import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// How much detail a screen recording keeps (Settings › Capture › Recording quality, pref `recordingQuality`). Standard is
/// the default: screen text stays sharp at about a gigabyte an hour or less. Each level caps the movie's longest side
/// (never below one pixel per point, see MovieWriter.outputScale) and sets the bit rate per pixel (MovieWriter.bitRate).
enum RecordingQuality: String, CaseIterable {
    case high, standard, small

    static let prefKey = "recordingQuality"
    static var current: RecordingQuality { RecordingQuality(rawValue: UserDefaults.standard.string(forKey: prefKey) ?? "") ?? .standard }

    var title: String {
        switch self {
        case .high: return "High (sharpest, larger files)"
        case .standard: return "Standard"
        case .small: return "Small (smallest files)"
        }
    }

    /// The movie's longest side in pixels, unless that would go below one pixel per point.
    var longestSide: CGFloat {
        switch self {
        case .high: return 2560
        case .standard: return 1920
        case .small: return 1440
        }
    }

    /// HEVC bits per pixel per second (at 30 frames a second: 0.033 / 0.033 / 0.02 bits per pixel per frame); High gets
    /// its extra sharpness from its extra pixels.
    var bitsPerPixel: Double {
        switch self {
        case .high: return 1.0
        case .standard: return 1.0
        case .small: return 0.6
        }
    }

    /// The most per second, whatever the size (HEVC; H.264 gets half as much again).
    var ceiling: Double {
        switch self {
        case .high: return 6_000_000
        case .standard: return 4_500_000
        case .small: return 2_500_000
        }
    }
}

/// The movie file of a screen recording: a fragmented QuickTime movie (a fragment lands every 2 s, so whatever happens to
/// the app the file plays up to its last fragment) with the picture, the computer's sound and the microphone on separate
/// tracks. It runs from the first picture to the moment Stop is pressed, whatever the screen does: ScreenCaptureKit sends
/// no picture while the screen is still and no sound while it is silent, so `tick` writes the last picture again twice a
/// second and fills a sound track that has gone quiet with silence, and `finish` ends the movie at the Stop time with the
/// picture held. Nothing is dropped because the writer is momentarily busy (samples wait in a short queue) and no sound is
/// trimmed to the last picture.
///
/// Every sound track starts with the movie (a moment of silence) and stays continuous: a track that only starts later, when
/// someone first speaks, makes AVAssetWriter stop putting the picture into the fragments from then on, so a kill lost all
/// the video since (tools/recorder_still_test). Sound is converted to one fixed format per track so the silence matches it.
///
/// Used from one queue only. No AppKit or ScreenCaptureKit here: tools/recorder_still_test drives it with made-up media.
final class MovieWriter {
    enum Track: String, CaseIterable { case system, microphone }

    static let repeatAfter = 0.2        // seconds without a new picture before the last one is written again (tick runs 4 times a second)
    static let silenceAfter = 1.0       // seconds a started sound track may go quiet before silence is filled in
    static let silenceLag = 0.5         // silence stops this far behind now (plus the track's own lag), so late sound never overlaps it

    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private var audio: [Track: AVAssetWriterInput] = [:]
    private var audioFormat: [Track: CMAudioFormatDescription] = [:]
    private var trackFormat: [Track: AVAudioFormat] = [:]
    private var converters: [Track: (source: AVAudioFormat, converter: AVAudioConverter)] = [:]
    private var audioEnd: [Track: CMTime] = [:]          // end of the sound queued so far, per track
    private var audioLag: [Track: Double] = [:]          // the longest a track's sound has arrived after its own time
    private var waiting: [Track: [CMSampleBuffer]] = [:]
    private var waitingPicture: (image: CVImageBuffer, time: CMTime, kind: String)?
    private var lastImage: CVImageBuffer?
    private var imageFormat: CMVideoFormatDescription?

    private(set) var started = false
    private(set) var firstTime = CMTime.invalid
    private(set) var videoEnd = CMTime.invalid           // time of the latest picture written
    private(set) var failure: String?
    private(set) var lastWrite = Date.distantPast        // wall clock of the latest sample the writer took
    /// Counts for diagnostics (test control status.json): what went in, what was repeated or filled, what had to wait.
    private(set) var stats: [String: Double] = [:]
    /// How the picture is encoded, e.g. "HEVC 1920×1246 2.4 Mbit/s (standard)" (logged, and in status.json).
    let encoder: String

    // MARK: Encoding

    enum Codec: String { case hevc = "HEVC", h264 = "H.264" }

    /// Whether this Mac encodes HEVC in hardware (Apple silicon and most Intel Macs from 2017 on). Recordings use HEVC then
    /// (about 40 % smaller than H.264 for the same picture), else H.264.
    static let hevcInHardware: Bool = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
        return encoders.contains {
            ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_HEVC
                && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
        }
    }()

    /// Pixels per point for the movie of an area `points` in size on a display with `backing` pixels per point: at most
    /// `backing` (every Retina pixel), at least 1 (text never smaller than on a plain screen) and, between those, no more
    /// than the quality's longest side. ScreenCaptureKit scales the captured picture to this size itself.
    static func outputScale(points: CGSize, backing: CGFloat, quality: RecordingQuality) -> CGFloat {
        let most = max(1, backing)
        let longest = max(points.width, points.height)
        guard longest > 0 else { return most }
        return min(most, max(1, quality.longestSide / longest))
    }

    /// Average bit rate: the movie's pixels × the quality's bits per pixel per second (H.264 half as much again for the
    /// same picture), at least 0.5 Mbit/s, at most the quality's ceiling. Screen content is mostly still, so the encoder
    /// spends little on unchanged frames; the bits go to what moves.
    static func bitRate(width: Int, height: Int, quality: RecordingQuality, codec: Codec) -> Int {
        let factor = codec == .hevc ? 1.0 : 1.5
        let wanted = Double(width * height) * quality.bitsPerPixel * factor
        return Int(min(quality.ceiling * factor, max(500_000, wanted)))
    }

    static func videoSettings(width: Int, height: Int, quality: RecordingQuality, codec: Codec) -> [String: Any] {
        [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(width: width, height: height, quality: quality, codec: codec),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,   // a key frame at least every two seconds: seeking, and a still screen
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
    }

    init(url: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool, quality: RecordingQuality = .standard) throws {
        self.url = url
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        w.shouldOptimizeForNetworkUse = false
        // HEVC when this Mac encodes it in hardware and the writer takes the settings; H.264 otherwise
        var codec: Codec = Self.hevcInHardware ? .hevc : .h264
        var settings = Self.videoSettings(width: width, height: height, quality: quality, codec: codec)
        if codec == .hevc && !w.canApply(outputSettings: settings, forMediaType: .video) {
            codec = .h264
            settings = Self.videoSettings(width: width, height: height, quality: quality, codec: codec)
        }
        let rate = Self.bitRate(width: width, height: height, quality: quality, codec: codec)
        encoder = "\(codec.rawValue) \(width)×\(height) \(String(format: "%.1f", Double(rate) / 1_000_000)) Mbit/s (\(quality.rawValue))"
        NSLog("SnapNow recorder: the picture is encoded as \(encoder)")
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        v.expectsMediaDataInRealTime = true
        w.add(v)
        // Two separate sound tracks (the computer's sound, then the microphone), not mixed while recording: each keeps its
        // own level, players play both, and the transcript reads both mixed (TranscriptAudio).
        if systemAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 160_000,
            ])
            a.expectsMediaDataInRealTime = true
            w.add(a)
            audio[.system] = a
        }
        if microphone {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 96_000,
            ])
            a.expectsMediaDataInRealTime = true
            w.add(a)
            audio[.microphone] = a
        }
        for track in audio.keys {
            let format = Self.trackFormat(track)
            trackFormat[track] = format
            audioFormat[track] = format.formatDescription
        }
        guard w.startWriting() else {
            throw NSError(domain: "SnapNow", code: 1, userInfo: [NSLocalizedDescriptionKey: w.error?.localizedDescription ?? "the movie file could not be created"])
        }
        writer = w
        video = v
    }

    var isWriting: Bool { failure == nil && writer.status == .writing }

    /// The one format a sound track is written from: 48 kHz float, stereo for the computer's sound, mono for the microphone.
    static func trackFormat(_ track: Track) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: track == .system ? 2 : 1, interleaved: false)!
    }

    /// The movie's length so far: from the first picture to the latest picture or sound.
    var seconds: Double {
        guard firstTime.isValid else { return 0 }
        return max(0, CMTimeGetSeconds(CMTimeSubtract(mediaEnd, firstTime)))
    }

    private var mediaEnd: CMTime {
        var end = videoEnd.isValid ? videoEnd : firstTime
        for e in audioEnd.values where e > end { end = e }
        return end
    }

    private func count(_ key: String, _ n: Double = 1) { stats[key, default: 0] += n }

    private func fail(_ why: String) {
        if failure == nil { failure = writer.error?.localizedDescription ?? why }
    }

    // MARK: Picture

    /// A captured picture. A newer picture that arrives timed at or before one already written (a repeat went in first) is
    /// moved just after it, never dropped, so the latest change always shows.
    func appendVideo(_ sample: CMSampleBuffer) {
        guard isWriting, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        var time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid else { return }
        if !started {
            writer.startSession(atSourceTime: time)
            started = true
            firstTime = time
            // Every sound track starts here, with a tenth of a second of silence (see the type's comment)
            for track in audio.keys {
                audioEnd[track] = time
                fillSilence(track, until: CMTimeAdd(time, CMTime(value: 1, timescale: 10)))
            }
        } else if videoEnd.isValid, time <= videoEnd {
            time = CMTimeAdd(videoEnd, CMTime(value: 1, timescale: 1000))
            count("video.shifted")
        }
        picture(image, at: time, kind: "video")
    }

    /// The picture goes in as a fresh sample (none of the capture's own attachments), or waits for the next tick when the
    /// writer is busy (a newer picture replaces a waiting one).
    @discardableResult
    private func picture(_ image: CVImageBuffer, at time: CMTime, kind: String) -> Bool {
        lastImage = image
        guard video.isReadyForMoreMediaData else {
            if waitingPicture != nil { count("video.replacedWhileWaiting") }
            waitingPicture = (image, time, kind)
            count("video.waited")
            return false
        }
        if imageFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(imageFormat!, imageBuffer: image) {
            var made: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &made)
            imageFormat = made
        }
        guard let format = imageFormat else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return false }
        guard video.append(sample) else { fail("the movie file could not be written"); return false }
        videoEnd = time
        lastWrite = Date()
        count(kind)
        return true
    }

    // MARK: Sound

    /// Captured sound for a track, arriving at `now`. Sound timed before the movie's start, or inside what is already
    /// written (silence filled in while the track was quiet), is left out; everything else goes in, waiting if the writer
    /// is busy.
    func appendAudio(_ sample: CMSampleBuffer, track: Track, now: CMTime) {
        guard isWriting, started, audio[track] != nil else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, time >= firstTime else { count("\(track.rawValue).beforeStart"); return }
        let lag = CMTimeGetSeconds(CMTimeSubtract(now, time))
        if lag.isFinite, lag > audioLag[track] ?? 0 {
            audioLag[track] = min(lag, 5)
            stats["\(track.rawValue).lagMax"] = min(lag, 5)
        }
        if let end = audioEnd[track], time < CMTimeSubtract(end, CMTime(value: 1, timescale: 1000)) {
            count("\(track.rawValue).overlap")
            return
        }
        guard let sample = conformed(sample, track: track) else { count("\(track.rawValue).unreadable"); return }
        // A hole before this sound is filled with silence first: AVAssetWriter packs sound back to back, so a hole would
        // slide everything after it earlier (out of step with the picture) and end the track early
        if let end = audioEnd[track], CMTimeGetSeconds(CMTimeSubtract(time, end)) > 0.001 { fillSilence(track, until: time) }
        audioEnd[track] = CMTimeAdd(time, Self.duration(of: sample))
        waiting[track, default: []].append(sample)
        count("\(track.rawValue).samples")
        drain(track)
    }

    /// The sound in the track's own format (already so: unchanged; else converted, the converter kept per source format so
    /// a resampled stream stays continuous). Same start time.
    private func conformed(_ sample: CMSampleBuffer, track: Track) -> CMSampleBuffer? {
        guard let target = trackFormat[track], let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let source = AVAudioFormat(cmAudioFormatDescription: description)
        if source == target { return sample }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr else { return nil }
        if converters[track]?.source != source {
            guard let c = AVAudioConverter(from: source, to: target) else { return nil }
            converters[track] = (source, c)
            count("\(track.rawValue).converted")
        }
        guard let converter = converters[track]?.converter,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(frames) * target.sampleRate / source.sampleRate) + 64) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return Self.sample(output, format: description == target.formatDescription ? description : target.formatDescription,
                           at: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// A sound sample from a buffer, starting at `time`.
    private static func sample(_ buffer: AVAudioPCMBuffer, format: CMAudioFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var made: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                             sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &made)
        guard let made, CMSampleBufferSetDataBufferFromAudioBufferList(made, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                       flags: 0, bufferList: buffer.audioBufferList) == noErr else { return nil }
        return made
    }

    private static func duration(of sample: CMSampleBuffer) -> CMTime {
        if let format = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mSampleRate > 0 {
            return CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sample)), timescale: CMTimeScale(asbd.mSampleRate))
        }
        return CMSampleBufferGetDuration(sample)
    }

    private func drain(_ track: Track) {
        guard let input = audio[track] else { return }
        while let first = waiting[track]?.first, input.isReadyForMoreMediaData {
            waiting[track]?.removeFirst()
            guard input.append(first) else { fail("the movie file could not be written"); return }
            lastWrite = Date()
        }
        if let n = waiting[track]?.count, n > 0 { count("\(track.rawValue).waited") }
        // A writer that refuses sound for a long time: the oldest goes rather than memory growing without end
        while let n = waiting[track]?.count, n > 2000 {
            waiting[track]?.removeFirst()
            count("\(track.rawValue).dropped")
        }
    }

    /// Silence from where a started track's sound ends up to `until`, in the track's own format.
    private func fillSilence(_ track: Track, until: CMTime) {
        guard let start = audioEnd[track], until > start, let format = audioFormat[track],
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0 else { return }
        let pcm = AVAudioFormat(cmAudioFormatDescription: format)
        let rate = asbd.mSampleRate
        var t = start
        while t < until {
            let frames = min(4800, max(1, Int((CMTimeGetSeconds(CMTimeSubtract(until, t)) * rate).rounded(.up))))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
            }
            guard let sample = Self.sample(buffer, format: format, at: t) else { return }
            waiting[track, default: []].append(sample)
            t = CMTimeAdd(t, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
            count("\(track.rawValue).silenceSeconds", Double(frames) / rate)
        }
        audioEnd[track] = t
        drain(track)
    }

    // MARK: Keeping it going

    /// Four times a second from the recorder (only while the capture is alive): waiting samples go in, a still screen's picture
    /// is written again, and a started sound track that has gone quiet gets silence up to just behind `now`.
    func tick(now: CMTime) {
        guard isWriting, started else { return }
        if let w = waitingPicture, video.isReadyForMoreMediaData {
            waitingPicture = nil
            picture(w.image, at: w.time, kind: w.kind)
        }
        for track in audio.keys { drain(track) }
        if waitingPicture == nil, let image = lastImage, CMTimeGetSeconds(CMTimeSubtract(now, videoEnd)) >= Self.repeatAfter {
            picture(image, at: now, kind: "video.repeat")
        }
        for track in audio.keys {
            // Quiet for a while: silence up to just behind now, further behind for a track whose sound arrives late
            let lag = audioLag[track] ?? 0
            if let end = audioEnd[track], CMTimeGetSeconds(CMTimeSubtract(now, end)) >= Self.silenceAfter + lag {
                fillSilence(track, until: CMTimeSubtract(now, CMTime(seconds: Self.silenceLag + lag, preferredTimescale: 600)))
            }
        }
    }

    // MARK: Ending

    private var anythingWaiting: Bool { waitingPicture != nil || audio.keys.contains { !(waiting[$0]?.isEmpty ?? true) } }

    /// The writer takes what still waits (it may be busy for a moment; at most until `deadline`).
    private func settle(by deadline: Date) {
        while anythingWaiting, isWriting, Date() < deadline {
            if let w = waitingPicture, video.isReadyForMoreMediaData {
                waitingPicture = nil
                picture(w.image, at: w.time, kind: w.kind)
            }
            for track in audio.keys { drain(track) }
            if anythingWaiting { usleep(5_000) }
        }
    }

    /// Stop: what waits goes in, started sound tracks are filled with silence and the picture is held up to `stop` (the
    /// moment Stop was pressed, or later if media was captured past it; zero = the media's own end), the session ends there
    /// and the movie is closed. No picture at all: nothing was recorded and the file is removed. `done` may run on any thread.
    func finish(at stop: CMTime, done: @escaping () -> Void) {
        guard writer.status == .writing, started else {
            if writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
            done()
            return
        }
        let end = max(stop, mediaEnd)
        let deadline = Date().addingTimeInterval(2)
        settle(by: deadline)
        for track in audio.keys where audioEnd[track] != nil { fillSilence(track, until: end) }
        if let image = lastImage, end > videoEnd {
            while Date() < deadline, !video.isReadyForMoreMediaData { usleep(5_000) }
            picture(image, at: end, kind: "video.final")
        }
        settle(by: deadline)
        guard isWriting else { done(); return }   // a failed writer: the fragments already on disk stay as they are, playable
        writer.endSession(atSourceTime: end)
        video.markAsFinished()
        audio.values.forEach { $0.markAsFinished() }
        writer.finishWriting { done() }
    }

    /// A start that never got going: nothing is kept.
    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
