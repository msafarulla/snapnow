import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// A marching (or effect) annotation must not make the editor repaint the whole picture on every march tick: the
/// picture below the first such annotation is one cached layer, the annotations from it up are a second one.
/// (1.87.0 and before: 25 full repaints a second while the editor was the active window.)
void main() {
  const w = 240, h = 160;

  Future<ui.Image> base() async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(const Rect.fromLTWH(0, 0, 240, 160), Paint()..color = const Color(0xFFF2EFE6));
    c.drawRect(const Rect.fromLTWH(30, 20, 120, 90), Paint()..color = const Color(0xFF2F6FDE)); // something for blur / multiply to act on
    c.drawCircle(const Offset(170, 100), 36, Paint()..color = const Color(0xFF22AA55));
    return rec.endRecording().toImage(w, h);
  }

  const ants = ArrowStyle(pattern: LinePattern.ants, shadow: false);
  Annotation arrow(int id, double y, {ArrowStyle style = const ArrowStyle(shadow: false)}) =>
      Annotation(id: id, shape: ArrowShape(Offset(20, y), Offset(220, y)), arrowStyle: style);
  Annotation step(int id, double x) => Annotation(id: id, shape: StepShape(Offset(x, 80)));
  Annotation highlight(int id) =>
      Annotation(id: id, shape: const HighlightShape(Rect.fromLTWH(10, 40, 220, 60)), color: const Color(0xFFFFCC00));
  Annotation blur(int id) => Annotation(id: id, shape: const BlurShape(Rect.fromLTWH(40, 30, 80, 50), null));
  Annotation rect(int id) => Annotation(id: id, shape: const RectShape(Rect.fromLTWH(60, 30, 120, 100)));

  /// Markups with a marching annotation at the bottom, in the middle and on top, with steps on both sides of it, a
  /// highlight (multiply) and an effect arrow (additive) above it, and a blur patch that is listed after it.
  Future<List<CanvasState>> cases() async {
    final img = await base();
    return [
      CanvasState(image: img, annotations: [arrow(1, 50, style: ants), rect(2), step(3, 60)]),
      CanvasState(image: img, annotations: [step(1, 40), rect(2), arrow(3, 70, style: ants), step(4, 120), highlight(5), blur(6)]),
      CanvasState(image: img, annotations: [highlight(1), step(2, 50), arrow(3, 90), arrow(4, 110, style: ants)]),
      CanvasState(image: img, annotations: [
        step(1, 40), arrow(2, 60, style: const ArrowStyle(effect: ArrowEffect.neon, shadow: false)), highlight(3), step(4, 200),
        arrow(5, 120, style: ants),
      ]),
    ];
  }

  Future<Uint32List> pixels(ui.Image img) async =>
      (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint32List();

  test('the still part and the moving part painted in turn are the whole picture', () async {
    for (final state in await cases()) {
      final k = CanvasPainter.firstAnimated(state);
      expect(k, greaterThanOrEqualTo(0));
      for (final phase in [0.0, 0.35, 0.8]) {
        final march = ValueNotifier(phase);
        final whole = ui.PictureRecorder(), parts = ui.PictureRecorder();
        CanvasPainter(state: state, selectionId: null, scale: 1, march: march).paint(Canvas(whole), const Size(240, 160));
        final c = Canvas(parts);
        CanvasPainter(state: state, selectionId: null, scale: 1, march: march, end: k).paint(c, const Size(240, 160));
        CanvasPainter(state: state, selectionId: null, scale: 1, march: march, first: k, under: false).paint(c, const Size(240, 160));
        final a = await pixels(await whole.endRecording().toImage(w, h)), b = await pixels(await parts.endRecording().toImage(w, h));
        expect(b, a, reason: 'first animated at $k of ${state.annotations.length}, phase $phase');
      }
    }
  });

  test('nothing marching: no split', () async {
    final img = await base();
    expect(CanvasPainter.firstAnimated(CanvasState(image: img, annotations: [arrow(1, 50), rect(2), step(3, 60)])), -1);
    expect(CanvasPainter.firstAnimated(CanvasState(image: img, annotations: const [])), -1);
    // a dashed line stands still
    expect(CanvasPainter.animates(arrow(1, 50, style: const ArrowStyle(pattern: LinePattern.dashed))), isFalse);
    expect(CanvasPainter.animates(arrow(1, 50, style: ants)), isTrue);
  });

  testWidgets('as two layers on screen the picture is the same as one layer (multiply and additive marks included)', (tester) async {
    tester.view.physicalSize = const Size(240, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late List<CanvasState> all;
    await tester.runAsync(() async => all = await cases());
    for (final state in all) {
      final k = CanvasPainter.firstAnimated(state);
      final march = ValueNotifier(0.35);
      Widget layer(CanvasPainter p, bool moving) => Positioned.fill(
          child: ClipRect(child: RepaintBoundary(child: CustomPaint(isComplex: !moving, willChange: moving, painter: p))));
      Future<Uint32List> shot(List<Widget> layers) async {
        final key = GlobalKey();
        await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr, child: RepaintBoundary(key: key, child: Stack(children: layers))));
        await tester.pump();
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        late Uint32List px;
        await tester.runAsync(() async => px = await pixels(await boundary.toImage()));
        return px;
      }

      final one = await shot([layer(CanvasPainter(state: state, selectionId: null, scale: 1, march: march, animate: true), true)]);
      final two = await shot([
        layer(CanvasPainter(state: state, selectionId: null, scale: 1, march: march, end: k), false),
        layer(CanvasPainter(state: state, selectionId: null, scale: 1, march: march, first: k, under: false, animate: true), true),
      ]);
      expect(two, one, reason: 'first animated at $k of ${state.annotations.length}');
    }
  });

  group('in the editor', () {
    setUp(() {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
        messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
      }
    });

    Future<EditorPageState> pumpEditor(WidgetTester tester) async {
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
      return key.currentState!;
    }

    /// How often the base picture is painted over 20 march ticks (0.8 s) with this markup.
    Future<int> basePaintsWhileMarching(WidgetTester tester, List<Annotation> Function() markup) async {
      final editor = await pumpEditor(tester);
      editor.debugSetState(editor.state!.copyWith(annotations: markup()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final before = CanvasPainter.underPaints;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      final n = CanvasPainter.underPaints - before;
      await tester.pumpWidget(const SizedBox()); // disposes the editor and its timers
      return n;
    }

    testWidgets('a marching arrow does not repaint the base picture on march ticks', (tester) async {
      final moving = CanvasPainter.overPaints;
      expect(await basePaintsWhileMarching(tester, () => [rect(1), arrow(2, 60, style: ants), step(3, 90)]), 0);
      // ...while the marching part is repainted on every one of the 20 ticks, so the dashes keep running
      expect(CanvasPainter.overPaints - moving, greaterThanOrEqualTo(20));
    });

    testWidgets('an effect arrow under still marks does not either', (tester) async {
      expect(
          await basePaintsWhileMarching(tester,
              () => [arrow(1, 60, style: const ArrowStyle(effect: ArrowEffect.neon, shadow: false)), rect(2), highlight(3)]),
          0);
    });

    testWidgets('a still picture is not repainted at all', (tester) async {
      expect(await basePaintsWhileMarching(tester, () => [rect(1), arrow(2, 60), step(3, 90)]), 0);
    });
  });
}
