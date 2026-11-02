import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/model/annotation.dart';
import 'package:snaplite_flutter/model/markup_file.dart';

/// Callouts come in several bubbles (rounded, square, pill, ellipse, thought cloud): every one draws with its
/// pointer, the choice survives a save, the Callout tool remembers it and a selected callout can be changed.
void main() {
  Future<ui.Image> blank(int w, int h) async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    return rec.endRecording().toImage(w, h);
  }

  test('every bubble style draws, reaches its tail, and keeps the text inside', () async {
    for (final style in CalloutStyle.values) {
      final a = Annotation(id: 1, shape: CalloutShape('Hello there', const Offset(60, 40), tail: const Offset(20, 140), style: style), color: Colors.blue);
      final rec = ui.PictureRecorder();
      CanvasPainter.drawAnnotation(Canvas(rec), a);
      await rec.endRecording().toImage(240, 180);
      final box = CanvasPainter.calloutRect('Hello there', const Offset(60, 40), a);
      final path = CanvasPainter.calloutPath(box, const Offset(20, 140), a.fontSize, style: style);
      final b = path.getBounds();
      // (a cloud's last puff is centred just short of the tip, so it reaches a little less far)
      expect(b.bottom, closeTo(140, style == CalloutStyle.cloud ? 6 : 1.5), reason: '${style.name}: the pointer ends at the tail');
      expect(box.contains(const Offset(60, 40)), isTrue, reason: '${style.name}: the text corner is inside the box');
      final text = CanvasPainter.textLayout('Hello there', a, Colors.black);
      // The text's box fits inside the body for every style (the curvy ones get a roomier box)
      final body = CanvasPainter.calloutPath(box, null, a.fontSize, style: style);
      for (final corner in [Offset(60, 40), Offset(60 + text.width, 40), Offset(60, 40 + text.height), Offset(60 + text.width, 40 + text.height)]) {
        expect(body.contains(corner), isTrue, reason: '${style.name}: text corner $corner inside the bubble');
      }
    }
  });

  test('the bubble style round-trips through the saved PNG', () async {
    final state = CanvasState(image: await blank(200, 120), annotations: [
      Annotation(id: 1, shape: const CalloutShape('a', Offset(40, 40), tail: Offset(10, 90), style: CalloutStyle.cloud)),
      Annotation(id: 2, shape: const CalloutShape('b', Offset(90, 40))),
    ]);
    final flat = (await state.image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final back = (await MarkupFile.read(await MarkupFile.embed(flat, state)))!;
    expect((back.annotations[0].shape as CalloutShape).style, CalloutStyle.cloud);
    expect((back.annotations[1].shape as CalloutShape).style, CalloutStyle.rounded);
    // Moving keeps the style
    expect((back.annotations[0].movedBy(const Offset(5, 5)).shape as CalloutShape).style, CalloutStyle.cloud);
  });

  testWidgets('the Callout tool offers bubbles; a selected callout changes to the picked one', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final saved = <String, Object?>{};
    for (final ch in ['window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      if (call.method == 'setString') saved[call.arguments['key'] as String] = call.arguments['value'];
      return null;
    });
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) { if (!d.exceptionAsString().contains('overflowed')) original?.call(d); };
    addTearDown(() => FlutterError.onError = original);

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await tester.tap(find.text('Callout'));
    await tester.pump();
    expect(find.text('Bubble'), findsOneWidget, reason: 'the Callout tool shows the bubble picker');
    await tester.tap(find.byTooltip('Thought cloud'));
    await tester.pump();
    expect(saved['callout.style'], 'cloud');

    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    await tester.tapAt(area.topLeft + const Offset(400, 400));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('snaplite-inline-text')), 'Hi');
    await tester.pump();
    final editor = key.currentState!;
    expect((editor.state!.annotations.single.shape as CalloutShape).style, CalloutStyle.cloud, reason: 'new callouts use the chosen bubble');

    await tester.tap(find.byTooltip('Pill'));
    await tester.pump();
    expect((editor.state!.annotations.single.shape as CalloutShape).style, CalloutStyle.pill, reason: 'the selected callout changes');
    expect((editor.state!.annotations.single.shape as CalloutShape).string, 'Hi', reason: 'its text stays');
  });
}
