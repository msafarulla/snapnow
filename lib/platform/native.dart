import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Bridge to the platform layer (macOS: macos/Runner/SnapLiteNative.swift).
class Native {
  static const _ch = MethodChannel('snaplite/native');
  static void Function(String? path)? onRecordingFinished;
  static void Function(String path)? onOpenEditor;
  static void Function(String path)? onOpenDraw;
  /// Draw mode's glass just became key: send the canvas cursor to macOS again (see EditorPageState.kickCursor).
  static void Function()? onCursorKick;
  /// Draw mode ended: [shot] is the screen as it was behind the glass (null when it could not be taken); the answer is
  /// whether the drawing was kept as a capture.
  static Future<bool> Function(String? shot)? onCloseDraw;
  /// Draw mode is about to lift: is anything drawn on the glass? (picks the closing animation)
  static bool Function()? onDrawHasMarks;
  /// Draw mode is being lifted: what is drawn goes one mark after another, each flying into [flyTo] (the menu bar icon, in
  /// the window's coordinates from the top left) or, without it, fading; true when done, false when nothing was drawn.
  /// Draw mode lifted with "One by one": [flyTo] the menu bar icon (window points, null with Reduce Motion), speed the
  /// chosen pace's name (DrawCloseSpeed.id). Answers true when the last mark is gone.
  static Future<bool> Function(Offset? flyTo, String? speed)? onDrawFadeOut;
  /// Draw mode: how bright the screen is behind the toolbar and the panel (0 black ... 1 white), about every 0.7 s.
  static void Function(List<double> luma)? onGlassLuma;
  static void Function()? onShowLibrary;
  static void Function()? onCapturesChanged;
  static void Function(String choice)? onAppearanceChanged;
  /// A movie's transcript changed (state, progress…; see TranscriptInfo in library/transcripts.dart).
  static void Function(Map<Object?, Object?> info)? onTranscriptChanged;

  static void init() {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'recordingFinished': onRecordingFinished?.call(call.arguments as String?);
        case 'openEditor': onOpenEditor?.call(call.arguments as String);
        case 'openDraw': onOpenDraw?.call(call.arguments as String);
        case 'cursorKick': onCursorKick?.call();
        case 'closeDraw': return await onCloseDraw?.call(call.arguments as String?) ?? false;
        case 'drawHasMarks': return onDrawHasMarks?.call() ?? false;
        case 'drawFadeOut':
          // {"to": [x, y] or null, "speed": name}; before 1.82.9 just [x, y] or null
          final args = call.arguments;
          final raw = args is Map ? args['to'] : args;
          final to = raw is List ? raw.map((e) => (e as num).toDouble()).toList() : null;
          final speed = args is Map ? args['speed'] as String? : null;
          return await onDrawFadeOut?.call(to != null && to.length == 2 ? Offset(to[0], to[1]) : null, speed) ?? false;
        case 'glassLuma': onGlassLuma?.call((call.arguments as List).map((e) => (e as num).toDouble()).toList());
        case 'showLibrary': onShowLibrary?.call();
        case 'capturesChanged': onCapturesChanged?.call();
        case 'colorPicked': onColorPicked?.call(call.arguments as int);
        case 'appearanceChanged': onAppearanceChanged?.call(call.arguments as String);
        case 'transcriptChanged': onTranscriptChanged?.call(call.arguments as Map);
      }
    });
  }

  /// Runs one of the menu bar shell's flows: region, window, screen, text, record, library, openImage, settings.
  static Future<void> shell(String action) => _call('shell', {'action': action});
  /// Clipboard + toast preview, like Copy Text everywhere else.
  static Future<void> copyText(String text) => _call('copyText', {'text': text});
  static Future<void> toast(String message, {String symbol = 'checkmark.circle.fill'}) =>
      _call('toast', {'message': message, 'symbol': symbol});
  /// Draw mode: the rectangles (x, y, w, h, radius in window points) of the floating cards, which the window frosts.
  static Future<void> glassRects(List<List<double>> rects, {required bool dark, required bool frost}) =>
      _call('glassRects', {'rects': rects, 'dark': dark, 'frost': frost});
  static Future<List<int>?> toolbarTools() async => (await _call<List>('toolbarTools'))?.cast<int>();

  static Future<Uint8List?> thumbnail(String path, {double size = 180}) =>
      _call<Uint8List>('thumbnail', {'path': path, 'size': size});
  static Future<void> trash(List<String> paths) => _call('trash', {'paths': paths});
  /// Transcript state per movie path (see TranscriptInfo).
  static Future<Map<String, Map<Object?, Object?>>> transcriptStates(List<String> paths) async {
    final m = await _call<Map>('transcriptStates', {'paths': paths}) ?? const {};
    return {for (final e in m.entries) e.key as String: e.value as Map};
  }
  /// Makes (or makes again) a movie's transcript, on this Mac, in the background.
  static Future<void> makeTranscript(String path) => _call('makeTranscript', {'path': path});
  /// Renames a capture in its folder (a movie's transcript files go along); the new path. Throws with a message if it can't.
  static Future<String?> renameCapture(String path, String name) => _call<String>('renameCapture', {'path': path, 'name': name});
  static Future<void> copyFiles(List<String> paths) => _call('copyFiles', {'paths': paths});
  static Future<void> copyTextOfFile(String path) => _call('copyTextOfFile', {'path': path});
  /// Puts the GIF file on the clipboard as both GIF data and a file, so it pastes animated.
  static Future<void> copyGif(String path) => _call('copyGif', {'path': path});
  /// The macOS share menu (Messages, Mail, AirDrop, Notes…) for a file, shown under [anchor] (window points).
  static Future<void> share(String path, Rect anchor) => _call('share',
      {'path': path, 'x': anchor.left, 'y': anchor.top, 'w': anchor.width, 'h': anchor.height});
  /// The image as a WhatsApp sticker (512×512 WebP) on the clipboard; returns the sticker file's path.
  static Future<String?> copySticker(Uint8List png, {required String name}) =>
      _call<String>('copySticker', {'png': png, 'name': name});
  /// Adds an animated sticker (same-size straight RGBA frames, back to back) to SnapLite's WhatsApp sticker
  /// pack and hands the pack to WhatsApp, which animates stickers only from installed packs.
  static Future<void> addWhatsAppSticker(Uint8List frames, List<int> durationsMs) =>
      _call('addWhatsAppSticker', {'frames': frames, 'durations': durationsMs});
  static Future<String?> exportGif(String path) => _call<String>('exportGIF', {'path': path});
  /// Save panel with a Format menu (PNG, JPEG, HEIC, TIFF, PDF, GIF, BMP); returns the saved path,
  /// null when cancelled, and throws a PlatformException when writing fails.
  static Future<String?> saveAs(Uint8List png, {required String name, double density = 1}) =>
      _call<String>('saveAs', {'png': png, 'name': name, 'density': density});

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (!Platform.isMacOS) return null;
    return _ch.invokeMethod<T>(method, args);
  }

  /// action -> stored JSON {keyCode, modifiers} written by either app version.
  static Future<Map<String, String>> storedShortcuts() async =>
      Map<String, String>.from(await _call<Map>('storedShortcuts') ?? const {});
  static Future<void> setShortcut(String action, String? json) => _call('setShortcut', {'action': action, 'json': json});

  /// UserDefaults Data written by the Swift app's JSONEncoder (style.arrow, myQuickStyles, …) as a string.
  static Future<String?> getDataString(String key) => _call<String>('getDataString', {'key': key});
  static Future<void> setDataString(String key, String json) => _call('setDataString', {'key': key, 'json': json});
  static Future<String?> getString(String key) => _call<String>('getString', {'key': key});
  static Future<void> setString(String key, String value) => _call('setString', {'key': key, 'value': value});

  /// The system color panel; picks arrive (continuously) through [onColorPicked] as 0xRRGGBB.
  static void Function(int rgb)? onColorPicked;
  static Future<void> showColorPanel(int rgb) => _call('showColorPanel', {'color': rgb});

  static Future<bool?> getBool(String key) => _call<bool>('getBool', {'key': key});
  static Future<void> setBool(String key, bool value) => _call('setBool', {'key': key, 'value': value});

  static Future<bool> screenAccess() async => await _call<bool>('screenAccess') ?? true;
  static Future<bool> requestScreenAccess() async => await _call<bool>('requestScreenAccess') ?? true;

  /// Cocoa global rect [x, y, w, h], or null when cancelled.
  static Future<List<double>?> selectRegion(String hint) async =>
      (await _call<List>('selectRegion', {'hint': hint}))?.cast<double>();

  /// "started", "cancelled" or "failed"; the movie arrives through [onRecordingFinished].
  static Future<String> startRecording({required bool microphone, bool showClicks = true}) async =>
      await _call<String>('startRecording', {'microphone': microphone, 'showClicks': showClicks}) ?? 'failed';
  static Future<void> stopRecording() => _call('stopRecording');

  /// Pixels per point from the image's DPI (144 dpi → 2), or null when the file doesn't say.
  static Future<double?> imageDensity(String path) => _call<double>('imageDensity', {'path': path});

  static Future<String> ocr(String path) async => await _call<String>('ocr', {'path': path}) ?? '';
  static Future<int> displayUnderMouse() async => await _call<int>('displayUnderMouse') ?? 1;
  /// Visible size (points) of the display under the mouse; null off macOS or on failure.
  static Future<Size?> screenVisibleSize() async {
    final r = await _call<List<dynamic>>('screenVisibleSize');
    if (r == null || r.length < 2) return null;
    return Size((r[0] as num).toDouble(), (r[1] as num).toDouble());
  }

  static Future<void> reveal(String path) => _call('reveal', {'path': path});
  static Future<void> openUrl(String url) => _call('openUrl', {'url': url});
  static Future<void> openPath(String path) => _call('openPath', {'path': path});
  static Future<void> activate() => _call('activate');
  /// Draw mode: the new session's empty glass is on screen in Flutter; the native side may now fade the window in.
  static Future<void> drawReady() => _call('drawReady');
  static Future<void> beep() => _call('beep');
}
