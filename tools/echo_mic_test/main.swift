import AVFoundation
import Foundation

// Checks EchoCancelledMic (macos/Runner/Shell/EchoCancelledMic.swift): the voice it hands to the movie writer is channel 0 of
// whatever the voice-processing input delivers (interleaved or not, any number of channels), mono, on the time it was given.
// With --live it also starts the real thing on this Mac's microphone for a moment (needs the microphone permission; says
// SKIP when it is not allowed) and checks what arrives. The echo cancellation itself needs speakers and a room: see snaplite.md.
//   tools/echo_mic_test/run.sh [--live]

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok:   \(what)") }
}

func floats(_ sample: CMSampleBuffer) -> [Float] {
    guard let format = CMSampleBufferGetFormatDescription(sample) else { return [] }
    let n = CMSampleBufferGetNumSamples(sample)
    guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: format), frameCapacity: AVAudioFrameCount(n)) else { return [] }
    buffer.frameLength = AVAudioFrameCount(n)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(n), into: buffer.mutableAudioBufferList) == noErr,
          let data = buffer.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: data[0], count: n))
}

func channelCount(_ sample: CMSampleBuffer) -> Int {
    guard let format = CMSampleBufferGetFormatDescription(sample) else { return 0 }
    return Int(AVAudioFormat(cmAudioFormatDescription: format).channelCount)
}

// 1. a nine-channel, non-interleaved buffer (what voice processing gives on a MacBook Pro): channel 0 is taken
do {
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9)!   // more than two channels need a layout
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    for ch in 0..<9 { for i in 0..<480 { buffer.floatChannelData![ch][i] = ch == 0 ? Float(i) / 480 : Float(ch) } }
    let time = CMTime(value: 123_456_789, timescale: 1_000_000_000)
    let sample = EchoCancelledMic.voice(from: buffer, at: time)
    check(sample != nil, "9-channel buffer gives a sample buffer")
    if let sample {
        check(channelCount(sample) == 1, "mono")
        check(CMSampleBufferGetNumSamples(sample) == 480, "every frame")
        check(CMSampleBufferGetPresentationTimeStamp(sample) == time, "on the given time")
        let x = floats(sample)
        check(x.count == 480 && (0..<480).allSatisfy { x[$0] == Float($0) / 480 }, "the samples of channel 0, unchanged")
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample)!)!.pointee
        check(asbd.mSampleRate == 48000, "the input's own sample rate (the movie writer converts)")
    }
}

// 2. an interleaved stereo buffer: the left channel
do {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
    buffer.frameLength = 100
    for i in 0..<100 { buffer.floatChannelData![0][2 * i] = Float(i); buffer.floatChannelData![0][2 * i + 1] = -1 }
    if let sample = EchoCancelledMic.voice(from: buffer, at: .zero) {
        let x = floats(sample)
        check(x.count == 100 && (0..<100).allSatisfy { x[$0] == Float($0) }, "interleaved stereo: the left channel")
    } else { check(false, "interleaved buffer gives a sample buffer") }
}

// 3. nothing in, nothing out
do {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!
    buffer.frameLength = 0
    check(EchoCancelledMic.voice(from: buffer, at: .zero) == nil, "an empty buffer gives nothing")
}

// 4. live: the real voice-processing input
if CommandLine.arguments.contains("--live") {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: break
    case .notDetermined:
        let gate = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { _ in gate.signal() }
        gate.wait()
    default: break
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        print("SKIP live: the microphone is not allowed for this process")
        print(failures == 0 ? "echo_mic_test: all passed (live skipped)" : "echo_mic_test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
    let lock = NSLock()
    var buffers = [(frames: Int, channels: Int, pts: Double, rate: Double)]()
    let mic = EchoCancelledMic { sample in
        let d = CMSampleBufferGetFormatDescription(sample).map { AVAudioFormat(cmAudioFormatDescription: $0) }
        lock.lock(); buffers.append((CMSampleBufferGetNumSamples(sample), Int(d?.channelCount ?? 0),
                                     CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), d?.sampleRate ?? 0)); lock.unlock()
    }
    let began = Date()
    do { try mic.start() } catch { check(false, "voice processing starts on this Mac (\(error))"); exit(1) }
    print(String(format: "      started in %.2f s, voice-processing input: %d channels at %.0f Hz", Date().timeIntervalSince(began),
                 Int(mic.inputFormat?.channelCount ?? 0), mic.inputFormat?.sampleRate ?? 0))
    check(mic.isRunning, "running after start")
    Thread.sleep(forTimeInterval: 2.5)
    let nowSeconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    mic.stop()
    check(!mic.isRunning, "stopped")
    lock.lock(); let got = buffers; lock.unlock()
    check(got.count >= 5, "buffers arrive (\(got.count) in 2.5 s)")
    check(got.allSatisfy { $0.channels == 1 }, "every buffer mono")
    check(zip(got, got.dropFirst()).allSatisfy { $1.pts > $0.pts }, "times only go forward")
    check(got.allSatisfy { abs(nowSeconds - $0.pts) < 5 }, "times are on the host clock (within 5 s of now)")
    let frames = got.reduce(0) { $0 + $1.frames }
    let rate = got.first?.rate ?? 48000
    check(Double(frames) / rate > 1.8, String(format: "about 2.5 s of sound (%.2f s)", Double(frames) / rate))
    // and again: a second recording starts as well as the first
    do { try mic.start(); check(mic.isRunning, "starts again after a stop"); mic.stop() } catch { check(false, "starts again (\(error))") }
}

print(failures == 0 ? "echo_mic_test: all passed" : "echo_mic_test: \(failures) failed")
exit(failures == 0 ? 0 : 1)
