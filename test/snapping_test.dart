import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/editor/snapping.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Stacking images: a dragged image snaps to the canvas and the other images, with guides.
void main() {
  const canvas = Rect.fromLTWH(0, 0, 800, 600);
  const first = Rect.fromLTWH(100, 50, 300, 200);

  test('stacks edge to edge under another image, lined up on the left', () {
    final (shift, guides) = snapRect(const Rect.fromLTWH(104, 253, 300, 200), [canvas, first], 6);
    expect(shift, const Offset(-4, -3));
    expect(guides, containsAll([const Guide(true, 100, 50, 450), const Guide(false, 250, 100, 400)]));
  });

  test('centres on the canvas', () {
    final (shift, guides) = snapRect(const Rect.fromLTWH(247, 400, 300, 100), [canvas], 6);
    expect(shift.dx, 3); // centre 397 → 400
    expect(guides.where((g) => g.vertical).single.at, 400);
  });

  test('nothing near: no shift, no guides', () {
    final (shift, guides) = snapRect(const Rect.fromLTWH(130, 330, 110, 70), [canvas, first], 6);
    expect(shift, Offset.zero);
    expect(guides, isEmpty);
  });

  test('the nearest line wins, and only what really lines up gets a guide', () {
    final other = const Rect.fromLTWH(500, 300, 100, 100); // left at 500
    final (shift, guides) = snapRect(const Rect.fromLTWH(502, 120, 60, 50), [first, other], 6); // 2 from 500
    expect(shift.dx, -2);
    expect(guides.where((g) => g.vertical).map((g) => g.at), [500]);
  });

  test('guides on the same line merge into one', () {
    final below = const Rect.fromLTWH(100, 400, 200, 100);
    final (_, guides) = snapRect(const Rect.fromLTWH(101, 280, 50, 50), [first, below], 6);
    expect(guides.where((g) => g.vertical && g.at == 100).single, const Guide(true, 100, 50, 500));
  });

  testWidgets('dragging a second image lines it up with the first; ⌘ moves it freely', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final c in ['window_manager', 'snaplite/native']) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (_) async => null);
    }
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
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 60, 40), Paint()..color = Colors.red);
      final png = (await (await rec.endRecording().toImage(60, 40)).toByteData(format: ui.ImageByteFormat.png))!;
      await key.currentState!.addOverlayBytes(png.buffer.asUint8List());
      await key.currentState!.addOverlayBytes(png.buffer.asUint8List());
    });
    await tester.pump();
    List<Rect> images() => [for (final a in key.currentState!.state!.annotations) if (a.shape is ImageShape) a.rect!];
    final firstRect = images()[0];
    expect(images()[1], firstRect, reason: 'both start centred, on top of each other');

    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    final k = key.currentState!.viewScale; // screen points per image point
    final origin = area.topLeft + key.currentState!.viewOrigin; // where the editor put the picture
    Offset onScreen(Offset p) => origin + p * k;

    // Drag the top image so it sits just under the first, 2 screen points off its left edge
    final grab = onScreen(firstRect.center);
    final g = await tester.startGesture(grab);
    await g.moveBy(const Offset(10, 10));
    await g.moveTo(grab + Offset(2, firstRect.height * k + 2));
    await tester.pump();
    final snapped = images()[1];
    expect(snapped.left, closeTo(firstRect.left, 1e-6), reason: 'lined up with the first image');
    expect(snapped.top, closeTo(firstRect.bottom, 1e-6), reason: 'stacked right under it');
    await g.up();
    await tester.pump();

    // Same drag with ⌘ held: no snapping
    final grab2 = onScreen(images()[1].center);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    final g2 = await tester.startGesture(grab2);
    await g2.moveBy(const Offset(10, 10));
    await g2.moveTo(grab2 + const Offset(3, 0));
    await tester.pump();
    expect(images()[1].left, isNot(closeTo(firstRect.left, 1e-3)));
    await g2.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an added image keeps its actual size, so a same-size capture takes the same space', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final c in ['window_manager', 'snaplite/native']) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (_) async => null);
    }
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
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 400, 240), Paint()..color = Colors.blue);
      final png = (await (await rec.endRecording().toImage(400, 240)).toByteData(format: ui.ImageByteFormat.png))!
          .buffer.asUint8List();
      final file = File('${Directory.systemTemp.createTempSync().path}/capture.png')..writeAsBytesSync(png);
      await key.currentState!.openFile(file.path);
      await key.currentState!.addOverlayBytes(png);
    });
    await tester.pump();
    final s = key.currentState!.state!;
    final added = s.annotations.singleWhere((a) => a.shape is ImageShape).rect!;
    expect(added.size, const Size(400, 240), reason: 'not shrunk: the same space as the capture under it');
    await tester.pumpWidget(const SizedBox());
  });
}
