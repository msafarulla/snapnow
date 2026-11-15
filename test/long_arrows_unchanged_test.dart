import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Arrows of normal length (four head lengths or more) must draw exactly as before the tiny-arrow head rules: the golden
/// was recorded with the 1.86.1 painter. Plain, curved freehand-style, both ends, tapered, marching, and every effect.
void main() {
  testWidgets('long arrows draw exactly as in 1.86.1', (tester) async {
    const size = Size(760, 900);
    final anns = <Annotation>[];
    var id = 0;
    final styles = [
      const ArrowStyle(end: ArrowHead.swept),
      const ArrowStyle(end: ArrowHead.triangle, start: ArrowHead.circle),
      const ArrowStyle(end: ArrowHead.swept, tapered: true),
      const ArrowStyle(end: ArrowHead.open, pattern: LinePattern.ants),
      for (final e in ArrowEffect.values)
        if (e != ArrowEffect.none) ArrowStyle(end: ArrowHead.swept, effect: e),
    ];
    for (final (i, s) in styles.indexed) {
      final y = 30.0 + i * 85;
      anns.add(Annotation(id: ++id, color: const Color(0xFFFF2D6F), size: StrokeSize.large, arrowStyle: s,
          shape: ArrowShape(Offset(30, y + 40), Offset(360, y))));
      // freehand-like: a bend and long explicit end tangents, at a 2x display width (10 px line, 50 px head)
      anns.add(Annotation(id: ++id, color: const Color(0xFF35C8FF), scale: 2, arrowStyle: s,
          shape: ArrowShape(Offset(400, y + 50), Offset(730, y + 10), points: [Offset(560, y - 15)],
              tangents: const [Offset(160, -60), null, Offset(120, 90)])));
    }
    final img = (await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1B1D2A));
      final base = await rec.endRecording().toImage(size.width.toInt(), size.height.toInt());
      final r = ui.PictureRecorder();
      CanvasPainter(state: CanvasState(image: base, annotations: anns), selectionId: null, scale: 1, march: ValueNotifier(0.3))
          .paint(Canvas(r), size);
      return r.endRecording().toImage(size.width.toInt(), size.height.toInt());
    }))!;
    await expectLater(img, matchesGoldenFile('goldens/long_arrows_1_86_1.png'));
  });
}
