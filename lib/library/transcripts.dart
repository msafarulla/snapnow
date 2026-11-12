import 'dart:io';

/// A screen recording's transcript as the native side reports it (macos/Runner/Shell/TranscriptJobs.swift): made on this
/// Mac only, in the background, and saved next to the movie as .txt ([mm:ss] lines) and .srt (captions).
enum TranscriptState { none, queued, running, done, failed }

class TranscriptInfo {
  final TranscriptState state;
  final double progress; // 0…1 while running
  final bool hasText;
  final String? message; // why the last try failed

  const TranscriptInfo({this.state = TranscriptState.none, this.progress = 0, this.hasText = false, this.message});

  factory TranscriptInfo.fromMap(Map<Object?, Object?> m) => TranscriptInfo(
        state: TranscriptState.values.firstWhere((s) => s.name == m['state'], orElse: () => TranscriptState.none),
        progress: ((m['progress'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
        hasText: m['hasText'] == true,
        message: m['message'] as String?,
      );

  bool get busy => state == TranscriptState.queued || state == TranscriptState.running;

  /// The tile's tooltip, and the context menu's line while it is being made.
  String get label => switch (state) {
        TranscriptState.queued => 'Waiting to transcribe',
        TranscriptState.running => progress > 0 ? 'Transcribing… ${(progress * 100).floor()}%' : 'Transcribing…',
        TranscriptState.done => 'Transcript',
        TranscriptState.failed => 'No transcript: ${message ?? 'it could not be made'}',
        TranscriptState.none => '',
      };
}

/// The transcript files next to a movie: the movie's own name with .txt and .srt.
class TranscriptFiles {
  static String _base(String movie) {
    final slash = movie.lastIndexOf('/'), dot = movie.lastIndexOf('.');
    return dot > slash + 1 ? movie.substring(0, dot) : movie;
  }

  static String textPath(String movie) => '${_base(movie)}.txt';
  static String captionsPath(String movie) => '${_base(movie)}.srt';
  static bool hasText(String movie) => File(textPath(movie)).existsSync();
}
