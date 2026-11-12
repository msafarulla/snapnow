// Drives the app's MovieWriter (macos/Runner/Shell/MovieWriter.swift) the way a recording does, in real time, with made-up
// pictures and sound: a screen that changes for a second and then stays still while someone talks, a busy screen, and a
// recording killed with SIGKILL during a still screen. The movie must run from the first picture to Stop (or, killed, to
// within a fragment of the kill), its sound never trimmed to the last picture.
// Run: tools/recorder_still_test/run.sh   (about 40 s)
import AVFoundation
import CoreMedia
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if ok { print("ok: \(what)") } else { failures += 1; print("FAIL: \(what)") } }

let clock = CMClockGetHostTimeClock()
func now() -> CMTime { CMClockGetTime(clock) }

// ---- made-up media ----
var pool: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferWidthKey: 1280, kCVPixelBufferHeightKey: 800, kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
func picture(_ n: Int, at t: CMTime) -> CMSampleBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!), Int32(n * 7 & 255), CVPixelBufferGetDataSize(pb!))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    var fd: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fd)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: t, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fd!, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb!
}
// As the capture delivers the computer's sound: 48 kHz stereo float, separate channels
var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                       mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
var afd: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &afd)
var phase = 0.0
func sound(at t: CMTime, frames: Int) -> CMSampleBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: afd!), frameCapacity: AVAudioFrameCount(frames))!
    b.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { let v = Float(sin(phase) * 0.3); phase += 2 * .pi * 440 / 48_000; b.floatChannelData![0][i] = v; b.floatChannelData![1][i] = v }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: t, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: afd!,
                         sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
    CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: b.audioBufferList)
    return sb!
}

/// One recording: pictures change for `busyFor` seconds (then the screen is still), sound plays from 3.5 to 9.5 s and
/// arrives 20 ms late, the writer ticks four times a second; at `stopAt` it is finished (or, with `kill`, the process dies).
func record(_ url: URL, busyFor: Double, stopAt: Double, mic: Bool, kill: Bool = false) -> (MovieWriter, Double) {
    try? FileManager.default.removeItem(at: url)
    let m = try! MovieWriter(url: url, width: 1280, height: 800, systemAudio: true, microphone: mic)
    let q = DispatchQueue(label: "writer")
    let t0 = now()
    func rel(_ t: CMTime) -> Double { CMTimeGetSeconds(CMTimeSubtract(t, t0)) }
    var n = 0, soundNext = CMTime.invalid
    let frames = DispatchSource.makeTimerSource(queue: q)
    frames.schedule(deadline: .now(), repeating: 1.0 / 30)
    frames.setEventHandler {
        let t = now()
        if rel(t) < busyFor || n == 0 { m.appendVideo(picture(n, at: t)); n += 1 }
    }
    let sounds = DispatchSource.makeTimerSource(queue: q)
    sounds.schedule(deadline: .now(), repeating: 0.01)
    sounds.setEventHandler {
        let t = now(), r = rel(t)
        guard r >= 3.5, r < 9.5 else { return }
        if !soundNext.isValid { soundNext = CMTimeSubtract(t, CMTime(value: 20, timescale: 1000)) }
        while CMTimeCompare(CMTimeAdd(soundNext, CMTime(value: 20, timescale: 1000)), t) < 0 {   // 20 ms late
            m.appendAudio(sound(at: soundNext, frames: 480), track: .system, now: t)
            soundNext = CMTimeAdd(soundNext, CMTime(value: 480, timescale: 48_000))
        }
    }
    let ticks = DispatchSource.makeTimerSource(queue: q)
    ticks.schedule(deadline: .now() + 0.25, repeating: 0.25)
    ticks.setEventHandler { m.tick(now: now()) }
    frames.resume(); sounds.resume(); ticks.resume()
    Thread.sleep(forTimeInterval: stopAt)
    if kill { Darwin.kill(getpid(), SIGKILL) }
    let done = DispatchSemaphore(value: 0)
    var stoppedAt = 0.0
    q.sync {
        frames.cancel(); sounds.cancel(); ticks.cancel()
        let stop = now()
        stoppedAt = rel(stop)
        m.finish(at: stop) { done.signal() }
    }
    done.wait()
    return (m, stoppedAt)
}

struct Track { let kind: String; let start: Double; let end: Double }
func tracks(_ url: URL) -> (duration: Double, tracks: [Track]) {
    let sem = DispatchSemaphore(value: 0)
    var out: (Double, [Track]) = (0, [])
    Task {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        var list: [Track] = []
        for t in (try? await asset.load(.tracks)) ?? [] {
            // Where the media really is: the first and last sample times of the track
            guard let r = try? await t.load(.timeRange) else { continue }
            let segments = (try? await t.load(.segments)) ?? []
            let filled = segments.filter { !$0.isEmpty }
            let start = filled.first.map { CMTimeGetSeconds($0.timeMapping.target.start) } ?? CMTimeGetSeconds(r.start)
            let end = filled.last.map { CMTimeGetSeconds($0.timeMapping.target.end) } ?? CMTimeGetSeconds(r.end)
            list.append(Track(kind: t.mediaType.rawValue, start: start, end: end))
        }
        out = (d, list)
        sem.signal()
    }
    sem.wait()
    return out
}
/// When the first sound that is not silence is heard in a movie's first sound track (seconds), or nil.
func firstSound(_ url: URL) -> Double? {
    let sem = DispatchSemaphore(value: 0)
    var found: Double?
    Task {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { sem.signal(); return }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                                                           AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                                                           AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        reader.startReading()
        var position = 0
        search: while let sb = out.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sb)
            var length = 0, pointer: UnsafeMutablePointer<Int8>?
            if let block = CMSampleBufferGetDataBuffer(sb), CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer {
                let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                for i in 0..<min(n, length / 4) where abs(samples[i]) > 0.05 { found = Double(position + i) / 48_000; break search }
            }
            position += n
        }
        sem.signal()
    }
    sem.wait()
    return found
}

/// The codec of a movie's picture track.
func videoCodec(_ url: URL) -> FourCharCode? {
    let sem = DispatchSemaphore(value: 0)
    var codec: FourCharCode?
    Task {
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let format = try? await track.load(.formatDescriptions).first {
            codec = CMFormatDescriptionGetMediaSubType(format)
        }
        sem.signal()
    }
    sem.wait()
    return codec
}

func show(_ name: String, _ r: (duration: Double, tracks: [Track])) {
    print(String(format: "%@: movie %.2f s; ", name, r.duration) + r.tracks.map { String(format: "%@ %.2f-%.2f s", $0.kind, $0.start, $0.end) }.joined(separator: ", "))
}

let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/tools-tmp/still-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

// The child of the kill test: records a still screen and dies at 8 s
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--killed" {
    _ = record(URL(fileURLWithPath: CommandLine.arguments[2]), busyFor: Double(CommandLine.arguments[3]) ?? 1, stopAt: 8, mic: false, kill: true)
    exit(0)
}

// Encoder settings (no real time needed)
do {
    func s(_ w: CGFloat, _ h: CGFloat, _ b: CGFloat, _ q: RecordingQuality) -> CGFloat { MovieWriter.outputScale(points: CGSize(width: w, height: h), backing: b, quality: q) }
    check(abs(s(1512, 982, 2, .standard) - 1920.0 / 1512) < 0.001, "14-inch full screen, Standard: 1920 px wide (1.27 px/pt)")
    check(abs(s(1512, 982, 2, .high) - 2560.0 / 1512) < 0.001, "14-inch full screen, High: 2560 px wide")
    check(s(1512, 982, 2, .small) == 1, "14-inch full screen, Small: 1 px/pt (never below)")
    check(s(640, 400, 2, .standard) == 2, "a small area keeps every Retina pixel")
    check(s(2560, 1440, 2, .standard) == 1, "a display wider than the cap in points: 1 px/pt, not blurrier")
    check(s(1920, 1080, 1, .high) == 1, "a plain (1x) display stays 1x")
    check(MovieWriter.bitRate(width: 1920, height: 1246, quality: .standard, codec: .hevc) == 2_392_320, "Standard HEVC at 1920x1246: 2.4 Mbit/s")
    check(MovieWriter.bitRate(width: 1920, height: 1246, quality: .standard, codec: .h264) == 3_588_480, "the H.264 fallback gets half as much again")
    check(MovieWriter.bitRate(width: 2560, height: 1662, quality: .high, codec: .hevc) == 4_254_720, "High HEVC at 2560x1662: 4.3 Mbit/s")
    check(MovieWriter.bitRate(width: 320, height: 200, quality: .standard, codec: .hevc) == 500_000, "a tiny area gets the floor")
    check(MovieWriter.bitRate(width: 3840, height: 2160, quality: .standard, codec: .hevc) == 4_500_000, "a huge area is held to the ceiling")
    print("  this Mac encodes HEVC in hardware: \(MovieWriter.hevcInHardware)")
}

// 0. A late picture after a repeat is moved just after it, not dropped (no real time needed)
do {
    let url = dir.appendingPathComponent("shift.mov")
    let m = try! MovieWriter(url: url, width: 1280, height: 800, systemAudio: false, microphone: false)
    let t = now()
    m.appendVideo(picture(1, at: t))
    m.tick(now: CMTimeAdd(t, CMTime(value: 600, timescale: 1000)))                   // a repeat at +0.6 s
    m.appendVideo(picture(2, at: CMTimeAdd(t, CMTime(value: 550, timescale: 1000))))  // the newer picture, timed before it
    check(m.stats["video.repeat"] == 1 && m.stats["video.shifted"] == 1 && m.stats["video"] == 2, "a late picture is shifted, not dropped \(m.stats)")
    let sem = DispatchSemaphore(value: 0)
    m.finish(at: CMTimeAdd(t, CMTime(value: 2, timescale: 1))) { sem.signal() }
    sem.wait()
    check(abs(tracks(url).duration - 2) < 0.05, "finish holds the picture to the stop time")
}

// 1. Still screen, someone talks from 3.5 to 9.5 s, an empty microphone track, Stop at 12 s
do {
    let url = dir.appendingPathComponent("still.mov")
    let (m, stop) = record(url, busyFor: 1, stopAt: 12, mic: true)
    let r = tracks(url)
    show("still", r)
    print("  writer: \(m.stats)")
    check(abs(r.duration - stop) < 0.15, String(format: "still: the movie runs to Stop (%.2f s of %.2f)", r.duration, stop))
    let v = r.tracks.first { $0.kind == "vide" }, a = r.tracks.first { $0.kind == "soun" }
    check(v != nil && abs(v!.end - stop) < 0.15, "still: the picture lasts to Stop")
    check(a != nil && a!.start < 0.05 && abs(a!.end - stop) < 0.15, "still: the sound track runs from the start to Stop (silence where nothing played)")
    check((m.stats["system.overlap"] ?? 0) == 0 && (m.stats["system.dropped"] ?? 0) == 0, "still: no sound lost")
    let heard = firstSound(url)
    check(heard.map { abs($0 - 3.48) < 0.06 } ?? false, String(format: "still: the talk is heard when it was said, in step with the picture (%.3f s, said at 3.48 s)", heard ?? -1))
    check((m.stats["video.repeat"] ?? 0) >= 30, "still: the picture was repeated while the screen was still")
    check(m.seconds > stop - 0.2, String(format: "still: the length the pill shows follows the movie (%.2f s)", m.seconds))
    print("  encoder: \(m.encoder)")
    check(m.encoder.hasPrefix(MovieWriter.hevcInHardware ? "HEVC" : "H.264"), "still: HEVC where the Mac has it in hardware, else H.264")
    check(videoCodec(url) == (MovieWriter.hevcInHardware ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264), "still: the file's picture track is in that codec")
}

// 2. Busy screen (pictures all the time), same sound
do {
    let url = dir.appendingPathComponent("busy.mov")
    let (_, stop) = record(url, busyFor: 99, stopAt: 12, mic: false)
    let r = tracks(url)
    show("busy", r)
    check(abs(r.duration - stop) < 0.15, "busy: the movie runs to Stop")
}

// 3. Killed during a still screen at 8 s: the file keeps all but the last fragment
do {
    let url = dir.appendingPathComponent("killed.mov")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--killed", url.path, ProcessInfo.processInfo.environment["BUSY"] ?? "1"]
    try! child.run()
    child.waitUntilExit()
    let r = tracks(url)
    show("killed", r)
    check(child.terminationReason == .uncaughtSignal, "killed: the child died by SIGKILL")
    check(r.duration >= 8 - 2.6, String(format: "killed at 8 s during a still screen: %.2f s kept (a fragment is 2 s)", r.duration))
    check(r.tracks.contains { $0.kind == "soun" && $0.end >= 8 - 2.6 }, "killed: the sound is kept up to the last fragment")
    check(r.tracks.contains { $0.kind == "vide" && $0.end >= 8 - 2.6 }, "killed: the picture is kept up to the last fragment, though the talk began late")
}

if ProcessInfo.processInfo.environment["KEEP"] == nil { try? FileManager.default.removeItem(at: dir) }
print(failures == 0 ? "recorder_still_test: all passed" : "recorder_still_test: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
