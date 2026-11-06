import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Marching Ants: a dashed line whose dashes run toward the arrowhead in the editor and the GIF's final hold.
void main() {
  int rgba(int r, int g, int b) => 0xFF000000 | (b << 16) | (g << 8) | r; // little-endian RGBA bytes

  Future<CanvasState> canvas(LinePattern pattern) async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 200, 60), Paint()..color = Colors.white);
    final base = await rec.endRecording().toImage(200, 60);
    return CanvasState(image: base, annotations: [
      Annotation(id: 1, shape: const ArrowShape(Offset(20, 30), Offset(180, 30)),
          arrowStyle: ArrowStyle(end: ArrowHead.none, pattern: pattern, shadow: false)),
    ]);
  }

  /// The pixel row through the line, as "is it painted" flags.
  Future<List<bool>> row(CanvasState state, double? march) async {
    final r = ui.PictureRecorder();
    CanvasPainter(state: state, selectionId: null, scale: 1, march: march == null ? null : ValueNotifier(march))
        .paint(Canvas(r), const Size(200, 60));
    final img = await r.endRecording().toImage(200, 60);
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint32List();
    return [for (var x = 30; x < 170; x++) px[30 * 200 + x] != rgba(255, 255, 255)];
  }

  test('Marching Ants is offered as a pattern and dashes like Dashed', () {
    expect(LinePattern.values.indexOf(LinePattern.ants), 5, reason: 'saved by index');
    expect(LinePattern.ants.label, 'Marching Ants');
    expect(LinePattern.ants.dashes(4), LinePattern.dashed.dashes(4));
    expect(LinePattern.ants.marches, isTrue);
    expect(LinePattern.dashed.marches, isFalse);
    // Saved styles keep it (and older files without it still load)
    const style = ArrowStyle(pattern: LinePattern.ants);
    expect(ArrowStyle.fromJson(style.toJson())!.pattern, LinePattern.ants);
  });

  test('the menu has the still patterns; Marching switches each (but solid) to its moving twin', () {
    expect(LinePattern.menu.any((p) => p.marches), isFalse);
    expect(LinePattern.solid.canMarch, isFalse);
    for (final p in LinePattern.menu.skip(1)) {
      final m = p.marching(true);
      expect(m.marches, isTrue);
      expect(m.dashes(4), p.dashes(4));
      expect(m.still, p);
      expect(m.canMarch, isTrue);
      expect(m.marching(false), p);
    }
    expect(LinePattern.solid.marching(true), LinePattern.solid);
  });

  test('dotted and dash-dot have marching versions too', () {
    expect(LinePattern.antsDotted.dashes(4), LinePattern.dotted.dashes(4));
    expect(LinePattern.antsDashDot.dashes(4), LinePattern.dashDot.dashes(4));
    expect(LinePattern.antsDotted.marches && LinePattern.antsDashDot.marches, isTrue);
    expect(LinePattern.dotted.marches || LinePattern.dashDot.marches, isFalse);
    for (final p in [LinePattern.antsDotted, LinePattern.antsDashDot]) {
      expect(ArrowStyle.fromJson(ArrowStyle(pattern: p).toJson())!.pattern, p);
    }
  });

  testWidgets('the dashes move with the march; plain dashes never do', (tester) async {
    await tester.runAsync(() async {
      final ants = await canvas(LinePattern.ants);
      final still = await row(ants, null), start = await row(ants, 0), moved = await row(ants, 0.5);
      expect(still, start, reason: 'no march = the start position, as in a saved PNG');
      expect(start.contains(false) && start.contains(true), isTrue, reason: 'it is dashed');
      expect(moved, isNot(start), reason: 'half a cycle later the dashes have shifted');
      expect(await row(ants, 1 - 1e-9), start, reason: 'a full cycle comes back round');

      final dashed = await canvas(LinePattern.dashed);
      expect(await row(dashed, 0.5), await row(dashed, null), reason: 'Dashed ignores the march');
    });
  });

  testWidgets('the GIF keeps marching through its final hold', (tester) async {
    await tester.runAsync(() async {
      Future<int> frameCount(LinePattern p) async =>
          (await ui.instantiateImageCodec(await BuildUpGif.render(await canvas(p)))).frameCount;
      final dashed = await frameCount(LinePattern.dashed), ants = await frameCount(LinePattern.ants);
      expect(ants, greaterThan(dashed + 10), reason: 'extra frames while the ants run');
    });
  });

  testWidgets('the looping GIF is the finished picture with only the ants moving', (tester) async {
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(await BuildUpGif.renderMarching(await canvas(LinePattern.ants)));
      expect(codec.frameCount, greaterThan(4), reason: 'one dash cycle of frames');
      final first = await codec.getNextFrame();
      final px = (await first.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint32List();
      expect(px.any((p) => p != rgba(255, 255, 255)), isTrue, reason: 'the arrow is there from the first frame');
    });
  });

  testWidgets('⌘C always copies the still PNG, even when an arrow marches; ⇧⌘C makes the GIF', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final copiedGifs = <String>[];
    var pngCopies = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), (call) async {
      if (call.method == 'writeImage') pngCopies++;
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      if (call.method == 'copyGif') copiedGifs.add((call.arguments as Map)['path'] as String);
      if (call.method == 'getString' && (call.arguments as Map)['key'] == 'gifFps') return '15'; // a quick render
      return null;
    });
    addTearDown(() => BuildUpGif.fps = 50);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    Future<void> copy({bool shift = false}) => tester.runAsync(() async {
          if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          // the GIF renders off the test clock: wait for it (up to 20 s), a still is quick
          final gifs = copiedGifs.length;
          for (var i = 0; i < 200 && (shift ? copiedGifs.length == gifs : i < 10); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        });

    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(300, 300), const Offset(250, -150));
    await tester.pump();
    await copy();
    expect((pngCopies, copiedGifs.length), (1, 0), reason: 'a plain arrow copies the still image');

    key.currentState!.setArrowStyle(const ArrowStyle(pattern: LinePattern.ants)); // the Arrow tool's style
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(300, 500), const Offset(250, -100));
    await tester.pump();
    await copy();
    expect((pngCopies, copiedGifs.length), (2, 0), reason: '⌘C is always the still image (1.70.6), ants or not');
    await copy(shift: true);
    expect((pngCopies, copiedGifs.length), (2, 1), reason: '⇧⌘C is the GIF');
    final frames = await tester.runAsync(() async => (await ui.instantiateImageCodec(await File(copiedGifs.single).readAsBytes())).frameCount);
    expect(frames, greaterThan(4), reason: 'the ants keep marching in the GIF');

    await tester.pumpWidget(const SizedBox()); // closes the editor, which stops the ants' timer
  });
}
