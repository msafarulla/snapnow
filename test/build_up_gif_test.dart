import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/app/app_controller.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/export/gif_encoder.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The build-up GIF: original capture, then each annotation appearing in turn, decoded back by the engine.
void main() {
  Future<List<(Uint32List, Duration)>> decode(Uint8List gif) async {
    final codec = await ui.instantiateImageCodec(gif);
    final out = <(Uint32List, Duration)>[];
    for (var i = 0; i < codec.frameCount; i++) {
      final f = await codec.getNextFrame();
      final data = await f.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      out.add((data!.buffer.asUint32List(), f.duration));
    }
    return out;
  }

  int rgba(int r, int g, int b) => 0xFF000000 | (b << 16) | (g << 8) | r; // little-endian RGBA bytes

  test('encoder: sub-frames draw over the last frame, transparent pixels keep it, delays survive', () async {
    final red = Uint32List(4 * 3)..fillRange(0, 12, rgba(255, 0, 0));
    final patch = Uint32List.fromList([0, rgba(0, 0, 255), rgba(0, 0, 255), 0]); // 2×2, two kept pixels
    final gif = encodeGif(4, 3, [
      GifFrame(0, 0, 4, 3, red.buffer.asUint8List(), 1000),
      GifFrame(1, 1, 2, 2, patch.buffer.asUint8List(), 250),
    ]);
    final frames = await decode(gif);
    expect(frames.length, 2);
    expect(frames[0].$2, const Duration(milliseconds: 1000));
    expect(frames[1].$2, const Duration(milliseconds: 250));
    final last = frames[1].$1;
    expect(last[1 * 4 + 1], rgba(255, 0, 0), reason: 'transparent pixel shows the frame before');
    expect(last[1 * 4 + 2], rgba(0, 0, 255));
    expect(last[2 * 4 + 1], rgba(0, 0, 255));
    expect(last[0], rgba(255, 0, 0), reason: 'outside the patch is untouched');
  });

  test('encoder: a busy picture (thousands of colours, LZW table resets) comes back close', () async {
    const w = 320, h = 200;
    final px = Uint32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        px[y * w + x] = rgba(x * 255 ~/ w, y * 255 ~/ h, (x * y) % 256);
      }
    }
    final frames = await decode(encodeGif(w, h, [GifFrame(0, 0, w, h, px.buffer.asUint8List(), 100)]));
    final back = frames.single.$1;
    var worst = 0;
    for (var i = 0; i < px.length; i++) {
      for (var c = 0; c < 3; c++) {
        final d = ((px[i] >> (8 * c)) & 0xFF) - ((back[i] >> (8 * c)) & 0xFF);
        if (d.abs() > worst) worst = d.abs();
      }
    }
    expect(worst, lessThan(64), reason: '255 colours for a full gradient: banding, but no garbage');
  });

  test('build-up GIF focuses on the markup, not the whole capture', () async {
    int u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8); // GIF logical screen size (little-endian)
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 800, 400), Paint()..color = Colors.white);
    final base = await rec.endRecording().toImage(800, 400);
    // One small box in the lower-right: markup covers a tiny fraction of the big capture.
    final s = CanvasState(image: base, annotations: const [
      Annotation(id: 1, shape: RectShape(Rect.fromLTWH(600, 300, 80, 50)), color: Color(0xFFFF0000)),
    ]);

    BuildUpGif.focusOnMarkup = true;
    final cropped = await BuildUpGif.render(s);
    final cw = u16(cropped, 6), ch = u16(cropped, 8);
    expect(cw, lessThan(200), reason: 'cropped tight to the 80px-wide markup, not 800');
    expect(ch, lessThan(200));
    expect(cw, greaterThan(60), reason: 'markup plus its margin is still there');

    BuildUpGif.focusOnMarkup = false;
    final full = await BuildUpGif.render(s);
    expect(u16(full, 6), 800, reason: 'off = the whole capture');
    expect(u16(full, 8), 400);
    BuildUpGif.focusOnMarkup = true; // restore the default
  });

  testWidgets('painter: an arrow half-way through appearing is drawn from its tail only', (tester) async {
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 200, 60), Paint()..color = Colors.white);
      final base = await rec.endRecording().toImage(200, 60);
      final state = CanvasState(image: base, annotations: const [
        Annotation(id: 1, shape: ArrowShape(Offset(20, 30), Offset(180, 30))),
      ]);
      Future<Uint32List> shot(Map<int, double>? p) async {
        final r = ui.PictureRecorder();
        CanvasPainter(state: state, selectionId: null, scale: 1, progress: p).paint(Canvas(r), const Size(200, 60));
        final img = await r.endRecording().toImage(200, 60);
        return (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint32List();
      }

      final hidden = await shot({}), half = await shot({1: 0.5}), full = await shot(null);
      final white = rgba(255, 255, 255);
      int at(Uint32List p, int x) => p[30 * 200 + x];
      expect(at(hidden, 100), white, reason: 'progress 0 hides it');
      expect(at(half, 40), isNot(white), reason: 'the tail end is drawn');
      expect(at(half, 170), white, reason: 'the head end is not there yet');
      expect(at(full, 170), isNot(white));
    });
  });

  testWidgets('Save as Animated GIF: original first, one appearance per addition, finished picture held', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final toasts = <String>[];
    for (final ch in ['window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      if (call.method == 'toast') toasts.add((call.arguments as Map)['message'] as String);
      return null;
    });
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    final dir = Directory.systemTemp.createTempSync('snaplite_gif');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/Shot.gif';
    EditorPageState.pickGifPath = (name) async => out.replaceFirst('Shot.gif', name);
    addTearDown(() => EditorPageState.pickGifPath = (_) async => null);

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));

    await tester.runAsync(() => key.currentState!.saveAnimatedGif());
    expect(toasts.last, 'Add some markup first');

    await tester.tap(find.text('Shape'));
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(200, 150), const Offset(150, 100));
    await tester.pump();
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(500, 400), const Offset(200, -120));
    await tester.pump();

    EditorPageState.pickGifPath = (_) async => throw PlatformException(code: 'ENTITLEMENT_NOT_FOUND');
    await tester.runAsync(() => key.currentState!.saveAnimatedGif());
    expect(toasts.last, "Couldn't make the GIF", reason: 'a panel that fails to open says so instead of doing nothing');

    EditorPageState.pickGifPath = (name) async => out.replaceFirst('Shot.gif', name);
    await tester.runAsync(() => key.currentState!.saveAnimatedGif());
    expect(toasts.last, 'Saved SnapNow.gif');
    final frames = await tester.runAsync(() async => decode(await File('${dir.path}/SnapNow.gif').readAsBytes()));
    final white = rgba(255, 255, 255);
    expect(frames!.first.$1.every((p) => p == white), isTrue, reason: 'starts on the original (blank) capture');
    expect(frames.first.$2, BuildUpGif.openingHold);
    final ms = BuildUpGif.lineDraw.inMilliseconds, perShape = ms * BuildUpGif.fps ~/ 1000;
    expect(frames.length, inInclusiveRange(2 * perShape - 1, 1 + 2 * perShape),
        reason: 'a frame per step (a line\'s first sliver can be too thin to change a pixel, so it merges)');
    expect(frames.last.$2, BuildUpGif.finalHold + Duration(milliseconds: ms ~/ perShape));
  });

  testWidgets('⇧⌘C copies the build-up GIF, ⌘C still copies the still image', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final toasts = <String>[], copiedGifs = <String>[];
    var pngCopies = 0, hides = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
      if (call.method == 'hide') hides++;
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), (call) async {
      if (call.method == 'writeImage') pngCopies++;
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'toast') toasts.add(args!['message'] as String);
      if (call.method == 'copyGif') copiedGifs.add(args!['path'] as String);
      if (call.method == 'getString' && args!['key'] == 'gifFps') return '15'; // Settings › GIF frame rate
      return null;
    });
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);

    await tester.runAsync(() async {
      // Esc bound window-wide the way the Library binds it (save and close)
      await tester.pumpWidget(MaterialApp(
          home: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): AppController.instance.saveAndClose},
              child: EditorPage(key: AppController.instance.editorKey))));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));

    Future<void> press({required bool shift}) => tester.runAsync(() async {
          if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await Future<void>.delayed(const Duration(seconds: 3)); // the GIF renders off the test clock
        });

    await press(shift: true);
    expect(toasts.last, 'Add some markup first');
    expect(copiedGifs, isEmpty);

    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(300, 300), const Offset(250, -150));
    await tester.pump();

    await press(shift: true);
    expect(toasts.last, 'Copied GIF');
    expect(copiedGifs.single, endsWith('/SnapNow GIFs/SnapNow.gif'));
    final frames = await tester.runAsync(() async => decode(await File(copiedGifs.single).readAsBytes()));
    expect(frames!.length, greaterThan(2), reason: 'animated, not a still');
    expect(pngCopies, 0);
    expect(BuildUpGif.fps, 15, reason: 'the frame rate chosen in Settings');
    addTearDown(() => BuildUpGif.fps = 50);
    await tester.pump();
    // ⇧⌘C only copies: no preview card or banner over the canvas, no file outside the temp folder
    expect(find.byKey(const ValueKey('snaplite-gif-preview')), findsNothing, reason: 'no banner over the canvas');
    expect(find.textContaining('Copied as animated GIF'), findsNothing);
    expect(copiedGifs.single, startsWith(Directory.systemTemp.path), reason: 'the GIF file is a temp file, never a capture');
    expect(copiedGifs.single, isNot(contains('/Pictures/')));
    expect(find.byKey(const ValueKey('snaplite-canvas')), findsOneWidget);

    await press(shift: true);
    expect(copiedGifs.length, 2);
    expect(hides, 0, reason: 'copying leaves the editor open');

    await press(shift: false);
    expect(pngCopies, 1, reason: '⌘C is unchanged');
    expect(copiedGifs.length, 2);
  });
}
