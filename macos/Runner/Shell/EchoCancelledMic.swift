import AVFoundation
import CoreMedia

/// The microphone with the computer's own sound taken out of it, for a recording that has the system audio and the
/// microphone both: a speaker that plays what is being recorded is heard by the microphone a moment later, and without this
/// the voice track carries that echo. macOS's voice processing (the VoiceProcessingIO audio unit behind
/// `AVAudioInputNode.setVoiceProcessingEnabled`) is an acoustic echo canceller whose reference signal is the sound the Mac
/// itself is playing, so what it hands over is the room without the speaker.
///
/// It replaces ScreenCaptureKit's own microphone capture for that case (that one is the raw microphone); with just one of
/// the two sources nothing here runs. The sound goes to `sink` as mono 32-bit float buffers stamped on the host clock, as
/// ScreenCaptureKit's are, so MovieWriter takes it as it takes theirs (it converts to the track's format).
final class EchoCancelledMic: @unchecked Sendable {   // its state is touched from one place at a time (start and stop, then the audio thread)
    private let engine = AVAudioEngine()
    private let sink: (CMSampleBuffer) -> Void
    private var configObserver: NSObjectProtocol?
    private(set) var isRunning = false
    /// The format voice processing delivers (several channels on some Macs; the first is the processed voice), for diagnostics.
    private(set) var inputFormat: AVAudioFormat?

    init(sink: @escaping (CMSampleBuffer) -> Void) {
        self.sink = sink
    }

    /// Starts the echo-cancelled capture of the default input. Throws if this Mac cannot (no input, voice processing
    /// refused, the engine would not start); the caller then records the plain microphone instead.
    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingBypassed = false
        // Voice processing lowers the other apps' sound while it runs (so a call is heard over music). `.min` is the least macOS
        // offers: measured here, the speakers and the system-audio track are still about 9 dB quieter (the default ducks ~31 dB,
        // advanced ducking no less). That is the price of the canceller; Prefs.echoCancel turns it off.
        if #available(macOS 14.0, *) {
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: ObjCBool(false), duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EchoError.noInput }
        inputFormat = format
        // Nothing is connected to the input: the tap alone reads it, and the voice goes nowhere near the speakers (connecting it
        // to the mixer fails to start on a Mac whose voice-processing input has more channels than its output, error -10875)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.deliver(buffer, at: when)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            throw error
        }
        isRunning = true
        // A new default microphone or a changed sample rate stops the engine: start it again
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isRunning, !self.engine.isRunning else { return }
            try? self.engine.start()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    enum EchoError: Error { case noInput }

    private func deliver(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        let time = when.isHostTimeValid ? CMClockMakeHostTimeFromSystemUnits(when.hostTime) : CMClockGetTime(CMClockGetHostTimeClock())
        if let sample = Self.voice(from: buffer, at: time) { sink(sample) }
    }

    /// The processed voice, channel 0 (voice processing hands over several channels on some Macs, all carrying it), as a mono
    /// sample buffer starting at `time`.
    static func voice(from buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)),
              let target = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        if buffer.format.isInterleaved {
            let stride = Int(buffer.format.channelCount)
            for i in 0..<frames { target[0][i] = channels[0][i * stride] }
        } else {
            target[0].update(from: channels[0], count: frames)
        }
        return sample(out, at: time)
    }

    static func sample(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var made: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: buffer.format.formatDescription, sampleCount: CMItemCount(buffer.frameLength),
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &made)
        guard let made, CMSampleBufferSetDataBufferFromAudioBufferList(made, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                       flags: 0, bufferList: buffer.audioBufferList) == noErr else { return nil }
        return made
    }
}
