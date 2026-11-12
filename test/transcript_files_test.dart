import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/library/transcripts.dart';

void main() {
  test('sidecar files take the movie\'s name', () {
    const movie = '/Users/x/Pictures/SnapNow/SnapNow Recording 2026-11-11 at 10.00.00.mov';
    expect(TranscriptFiles.textPath(movie), '/Users/x/Pictures/SnapNow/SnapNow Recording 2026-11-11 at 10.00.00.txt');
    expect(TranscriptFiles.captionsPath(movie), '/Users/x/Pictures/SnapNow/SnapNow Recording 2026-11-11 at 10.00.00.srt');
    expect(TranscriptFiles.textPath('/a.b/clip.v2.mp4'), '/a.b/clip.v2.txt');
    expect(TranscriptFiles.textPath('/a.b/noextension'), '/a.b/noextension.txt');
  });

  test('state from the native side', () {
    final running = TranscriptInfo.fromMap({'path': '/m.mov', 'state': 'running', 'progress': 0.426, 'hasText': false});
    expect(running.state, TranscriptState.running);
    expect(running.busy, isTrue);
    expect(running.label, 'Transcribing… 42%');
    final done = TranscriptInfo.fromMap({'state': 'done', 'progress': 0, 'hasText': true});
    expect(done.busy, isFalse);
    expect(done.hasText, isTrue);
    final failed = TranscriptInfo.fromMap({'state': 'failed', 'message': 'This recording has no sound'});
    expect(failed.label, 'No transcript: This recording has no sound');
    expect(TranscriptInfo.fromMap({'state': 'queued'}).label, 'Waiting to transcribe');
    expect(TranscriptInfo.fromMap({'state': 'odd', 'progress': 7}).state, TranscriptState.none);
    expect(TranscriptInfo.fromMap({'state': 'running', 'progress': 7}).progress, 1.0);
    expect(TranscriptInfo.fromMap({'state': 'running'}).label, 'Transcribing…');
  });
}
