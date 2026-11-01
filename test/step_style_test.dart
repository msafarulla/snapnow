import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/model/annotation.dart';
import 'package:snaplite_flutter/model/markup_file.dart';

/// Steps can sit in different markers (circle, rounded square, square, diamond, hexagon, pin): the Step tool
/// remembers the choice, a selected step can be changed, every marker draws, and the choice survives a save.
void main() {
  Future<ui.Image> blank(int w, int h) async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    return rec.endRecording().toImage(w, h);
  }

  test('every marker style draws a number without throwing', () async {
    for (final style in StepMarker.values) {
      final rec = ui.PictureRecorder();
      final a = Annotation(id: 1, shape: StepShape(const Offset(50, 50), style: style), color: Colors.red);
      CanvasPainter.drawAnnotation(Canvas(rec), a, number: 3);
      final img = await rec.endRecording().toImage(100, 120);
      expect(img.width, 100);
      final b = CanvasPainter.stepBounds(const Offset(50, 50), a.stepDiameter, style);
      expect(b.contains(const Offset(50, 50)), isTrue, reason: '${style.name} bounds hold the centre');
    }
    final pin = CanvasPainter.stepBounds(Offset.zero, 34, StepMarker.pin);
    expect(pin.bottom, greaterThan(17), reason: 'the pin hangs below its disc');
  });

  test('the marker style round-trips through the saved PNG', () async {
    final state = CanvasState(image: await blank(200, 120), annotations: [
      Annotation(id: 1, shape: const StepShape(Offset(40, 40), style: StepMarker.hexagon)),
      Annotation(id: 2, shape: const StepShape(Offset(90, 40))),
    ]);
    final flat = (await state.image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final png = await MarkupFile.embed(flat, state);
    final back = (await MarkupFile.read(png))!;
    expect((back.annotations[0].shape as StepShape).style, StepMarker.hexagon);
    expect((back.annotations[1].shape as StepShape).style, StepMarker.circle);
  });

  testWidgets('the Step tool offers markers; a selected step changes to the picked one', (tester) async {
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
    await tester.tap(find.text('Step'));
    await tester.pump();
    expect(find.text('Marker'), findsOneWidget, reason: 'the Step tool shows the marker picker');

    await tester.tap(find.byTooltip('Diamond'));
    await tester.pump();
    expect(saved['step.style'], 'diamond', reason: 'the choice is remembered');

    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    await tester.tapAt(area.topLeft + const Offset(300, 300));
    await tester.pump();
    final steps = key.currentState!.state!.annotations.whereType<Annotation>().toList();
    expect((steps.single.shape as StepShape).style, StepMarker.diamond, reason: 'new steps use the chosen marker');

    // Select it and switch to a pin
    await tester.tap(find.text('Select'));
    await tester.pump();
    await tester.tapAt(area.topLeft + const Offset(300, 300));
    await tester.pump();
    expect(key.currentState!.selected, isNotNull);
    await tester.tap(find.byTooltip('Pin'));
    await tester.pump();
    expect((key.currentState!.state!.annotations.single.shape as StepShape).style, StepMarker.pin);
  });
}
