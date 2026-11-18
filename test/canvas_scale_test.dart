import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

void main() {
  testWidgets('reducing pixels keeps the on-screen footprint (grainy, not smaller)', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['window_manager', 'pasteboard', 'snaplite/native']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 1400, height: 1000, child: EditorPage(key: key))),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400)); // _makeBlankCanvas(1200,800) completes
    });
    await tester.pump();
    void drain() { while (tester.takeException() != null) {} } // ignore unrelated panel-overflow noise
    drain();

    expect(key.currentState!.debugOriginalSize, const Size(1200, 800), reason: 'original size recorded on create');
    final scaleBefore = key.currentState!.debugViewScale;
    final footprintBefore = 1200 * scaleBefore;

    await tester.runAsync(() => key.currentState!.scaleCanvasTo(480, 320)); // reduce the pixels
    await tester.pump();
    drain();
    final scaleAfter = key.currentState!.debugViewScale;
    final footprintAfter = 480 * scaleAfter;

    expect(scaleAfter, greaterThan(scaleBefore), reason: 'fewer pixels are drawn larger (grainy), not smaller');
    expect(footprintAfter, closeTo(footprintBefore, 1.0),
        reason: 'the image occupies the same on-screen size after reducing pixels');
  });

  testWidgets('a width-only pixel change does not stretch the height', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['window_manager', 'pasteboard', 'snaplite/native']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 1400, height: 1000, child: EditorPage(key: key))),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    void drain() { while (tester.takeException() != null) {} }
    drain();

    final s = key.currentState!;
    final wBefore = 1200 * s.debugViewScale, hBefore = 800 * s.debugViewScaleY;

    await tester.runAsync(() => s.scaleCanvasTo(600, 800)); // halve the WIDTH only, keep the height
    await tester.pump();
    drain();
    final wAfter = 600 * s.debugViewScale, hAfter = 800 * s.debugViewScaleY;

    expect(hAfter, closeTo(hBefore, 1.0), reason: 'height on screen is unchanged (it was being stretched)');
    expect(wAfter, closeTo(wBefore, 1.0), reason: 'width on screen is unchanged too (just grainier)');
  });

  /// A plain picture of w x h pixels as PNG bytes (what a dropped capture is).
  Future<Uint8List> png(int w, int h) async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF3366CC));
    final img = await rec.endRecording().toImage(w, h);
    return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }

  Future<EditorPageState> editor(WidgetTester tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['window_manager', 'pasteboard', 'snaplite/native']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 1400, height: 1000, child: EditorPage(key: key))),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400)); // _makeBlankCanvas(1200,800) completes
    });
    await tester.pump();
    while (tester.takeException() != null) {}
    return key.currentState!;
  }

  testWidgets('an image dropped past the edge grows the canvas and leaves the picture its shape', (tester) async {
    // User, 2026-11-18: "if I drag one image [onto the] other, it is entirely changing the dimensions of the image, it has
    // to remain as is and the canvas has to adapt". The grown canvas was squeezed into the footprint of the file as opened,
    // each axis by itself, so the picture and the dropped image were both distorted.
    final s = await editor(tester);
    expect(s.debugViewScale, closeTo(s.debugViewScaleY, 1e-9));
    // a 900 x 600 image dropped on the canvas centre (600, 400) fits: nothing grows
    await tester.runAsync(() async => s.addOverlayBytes(await png(900, 600)));
    await tester.pump();
    expect((s.state!.image.width, s.state!.image.height), (1200, 800));
    // a 2000 x 400 image is wider than the canvas: it grows sideways only
    await tester.runAsync(() async => s.addOverlayBytes(await png(2000, 400)));
    await tester.pump();
    while (tester.takeException() != null) {}
    expect((s.state!.image.width, s.state!.image.height), (2000, 800), reason: 'the canvas adapts to what was dropped');
    expect(s.debugViewScale, closeTo(s.debugViewScaleY, 1e-9), reason: 'same scale on both axes: nothing is stretched');
    expect(s.debugOriginalSize, const Size(2000, 800), reason: 'the footprint grew with the canvas');
    final dropped = s.state!.annotations.last.rect!;
    expect((dropped.width, dropped.height), (2000.0, 400.0), reason: 'the dropped image keeps its own size');
  });

  testWidgets('a picture with reduced pixels keeps its footprint ratio when the canvas grows, and undo brings both back', (tester) async {
    final s = await editor(tester);
    await tester.runAsync(() => s.scaleCanvasTo(600, 800)); // half the pixels across, same place on screen
    await tester.pump();
    expect(s.debugOriginalSize, const Size(1200, 800));
    final ratio = s.debugViewScale / s.debugViewScaleY;
    expect(ratio, closeTo(2, 1e-6));
    await tester.runAsync(() async => s.addOverlayBytes(await png(900, 300))); // spills 150 px past each side
    await tester.pump();
    while (tester.takeException() != null) {}
    expect((s.state!.image.width, s.state!.image.height), (900, 800));
    expect(s.debugOriginalSize, const Size(1800, 800), reason: '900 reduced pixels across = 1800 on the footprint');
    expect(s.debugViewScale / s.debugViewScaleY, closeTo(ratio, 1e-6), reason: 'what was on the canvas keeps its shape');
    s.runMenu('undo');
    await tester.pump();
    expect(s.debugOriginalSize, const Size(1200, 800), reason: 'undo: the footprint of the state before the drop');
    s.runMenu('undo');
    await tester.pump();
    expect(s.debugOriginalSize, const Size(1200, 800));
    expect(s.debugViewScale, closeTo(s.debugViewScaleY, 1e-9), reason: 'back to the full-pixel picture');
  });
}
