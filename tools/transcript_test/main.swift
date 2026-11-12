// Checks the transcript files' formatting (macos/Runner/Shell/Transcript.swift): [mm:ss] / [h:mm:ss] stamps, the .txt,
// SRT times and cues, words grouped into lines, sidecar names. With --live it also transcribes speech made by `say`
// on this Mac (on-device recognition, nothing leaves it) and checks the words come back with sensible times.
// Run: tools/transcript_test/run.sh [--live]
import AVFoundation
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }

// Stamps
check(TranscriptFormat.stamp(0, hours: false) == "[00:00]", "stamp 0")
check(TranscriptFormat.stamp(65.9, hours: false) == "[01:05]", "stamp 65.9 rounds down")
check(TranscriptFormat.stamp(3599, hours: false) == "[59:59]", "stamp 59:59")
check(TranscriptFormat.stamp(3725, hours: true) == "[1:02:05]", "stamp with hours")
check(TranscriptFormat.stamp(5, hours: true) == "[0:00:05]", "short stamp in an hour-long transcript")

// .txt
let lines = [TranscriptLine(start: 1.2, end: 3.4, text: "Hello there."), TranscriptLine(start: 70, end: 72.5, text: "Second line")]
check(TranscriptFormat.text(lines) == "[00:01] Hello there.\n[01:10] Second line\n", "text file")
let long = [TranscriptLine(start: 10, end: 12, text: "a"), TranscriptLine(start: 3700, end: 3701, text: "b")]
check(TranscriptFormat.text(long) == "[0:00:10] a\n[1:01:40] b\n", "hour-long text uses h:mm:ss on every line")
check(TranscriptFormat.text([]) == TranscriptFormat.noSpeech + "\n", "empty transcript says so")

// SRT
check(TranscriptFormat.srtTime(0) == "00:00:00,000", "srt time 0")
check(TranscriptFormat.srtTime(3723.4567) == "01:02:03,457", "srt time rounding")
check(TranscriptFormat.srt(lines) == "1\n00:00:01,200 --> 00:00:03,400\nHello there.\n\n2\n00:01:10,000 --> 00:01:12,500\nSecond line\n", "srt file")
let wordy = TranscriptLine(start: 0, end: 20, text: Array(repeating: "word", count: 40).joined(separator: " "))   // 199 chars
let cues = TranscriptFormat.captions([wordy])
check(cues.count == 3, "a long line becomes several cues (\(cues.count))")
check(cues.allSatisfy { $0.text.split(separator: "\n").allSatisfy { $0.count <= 44 } }, "cue rows stay short")
check(abs((cues.last?.end ?? 0) - 20) < 0.01 && cues.first?.start == 0, "cues cover the line's time")
check(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start + 0.0001 }, "cues never overlap")
let quick = TranscriptFormat.captions([TranscriptLine(start: 5, end: 5.1, text: "Hi"), TranscriptLine(start: 9, end: 9.2, text: "Yo")])
check(abs(quick[0].end - 5.8) < 0.001, "a short cue stays 0.8 s")
check(TranscriptFormat.wrap("short") == "short", "short cue not wrapped")

// Words to lines
let words = [TranscriptLine(start: 0, end: 0.3, text: "one"), TranscriptLine(start: 0.4, end: 0.7, text: "two"),
             TranscriptLine(start: 2.5, end: 2.8, text: "three")]
let grouped = TranscriptFormat.lines(fromWords: words)
check(grouped.count == 2 && grouped[0].text == "one two" && grouped[1].start == 2.5, "a pause starts a new line")

// Sidecars
let movie = URL(fileURLWithPath: "/tmp/x/SnapNow Recording 2026-11-11 at 10.00.00.mov")
let side = TranscriptFormat.sidecars(for: movie)
check(side.text.path == "/tmp/x/SnapNow Recording 2026-11-11 at 10.00.00.txt", "txt sidecar name")
check(side.captions.path == "/tmp/x/SnapNow Recording 2026-11-11 at 10.00.00.srt", "srt sidecar name")

// Live: speech from `say`, recognised on this Mac
if CommandLine.arguments.contains("--live") {
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/tools-tmp/transcript-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sound = dir.appendingPathComponent("speech.aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Samantha", "-o", sound.path,
                     "The quick brown fox jumps over the lazy dog. [[slnc 1500]] Screen recordings now have transcripts."]
    try say.run(); say.waitUntilExit()
    var got: [TranscriptLine] = []
    let started = Date()
    do {
        try await TranscriptEngine.run(movie: sound, language: "en-US", from: 0, line: { got.append($0) }, progress: { _ in })
        print(TranscriptFormat.text(got), terminator: "")
        let all = got.map(\.text).joined(separator: " ").lowercased()
        check(all.contains("fox") && all.contains("transcripts"), "live: the words came back (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        check(got.count >= 1 && got.allSatisfy { $0.end >= $0.start && $0.start >= 0 } && (got.last?.end ?? 0) > 3, "live: lines have times")
        // Resuming part-way: only what comes after is read
        var rest: [TranscriptLine] = []
        try await TranscriptEngine.run(movie: sound, language: "en-US", from: 3.5, line: { rest.append($0) }, progress: { _ in })
        let tail = rest.map(\.text).joined(separator: " ").lowercased()
        check(!tail.contains("fox") && tail.contains("transcripts") && (rest.first?.start ?? 0) >= 3.4, "live: resume from 3.5 s")
    } catch {
        check(false, "live: \(error.localizedDescription) [\(error)]")
    }
    try? FileManager.default.removeItem(at: dir)
}

print(failures == 0 ? "transcript_test: all passed" : "transcript_test: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
