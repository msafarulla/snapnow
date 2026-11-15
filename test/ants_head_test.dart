import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Marching patterns on an arrow: the moving dashes stop at the back of each head, so nothing moves inside a head.
void main() {
  const w = 400, h = 120, tail = 30.0, tip = 370.0;

  Future<Uint32List> frame(ArrowStyle style, double march) async {
    final rec0 = ui.PictureRecorder();
    Canvas(rec0).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    final base = await rec0.endRecording().toImage(w, h);
    final state = CanvasState(image: base, annotations: [
      Annotation(id: 1, shape: const ArrowShape(Offset(tail, 60), Offset(tip, 60)), color: const Color(0xFFE8332A),
          size: StrokeSize.large, arrowStyle: style),
    ]);
    final r = ui.PictureRecorder();
    CanvasPainter(state: state, selectionId: null, scale: 1, march: ValueNotifier(march))
        .paint(Canvas(r), Size(w.toDouble(), h.toDouble()));
    final img = await r.endRecording().toImage(w, h);
    return (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint32List();
  }

  /// How many pixels differ between two frames in the columns [from, to).
  int moved(Uint32List a, Uint32List b, int from, int to) {
    var n = 0;
    for (var y = 0; y < h; y++) {
      for (var x = from; x < to; x++) {
        if (a[y * w + x] != b[y * w + x]) n++;
      }
    }
    return n;
  }

  // How far behind its tip each of these heads reaches (line 8 wide, medium head: 40 long)
  const line = 8.0, length = 40.0;
  final thin = math.max(1.5, line * 0.6), circle = math.max(5.0, line * 1.8);
  final backs = {
    ArrowHead.swept: length * 1.1,
    ArrowHead.triangleOutline: length + thin / 2,
    ArrowHead.open: length * 0.75,
    ArrowHead.circle: circle + thin / 2,
  };

  for (final MapEntry(key: head, value: back) in backs.entries) {
    for (final pattern in [LinePattern.ants, LinePattern.antsDotted, LinePattern.antsLongDash]) {
      test('${pattern.label} never moves inside a ${head.label} head, at either end', () async {
        final style = ArrowStyle(start: head, end: head, pattern: pattern, shadow: false);
        final frames = [for (final m in [0.0, 0.2, 0.4, 0.6, 0.8]) await frame(style, m)];
        final endFrom = (tip - back).ceil() + 1, startTo = (tail + back).floor() - 1;
        for (final f in frames.skip(1)) {
          expect(moved(frames.first, f, endFrom, w), 0, reason: 'the head at the end stays as it is');
          expect(moved(frames.first, f, 0, startTo), 0, reason: 'the head at the start stays as it is');
        }
        expect(moved(frames[0], frames[2], startTo, endFrom), greaterThan(200), reason: 'the dashes still march between');
      });
    }
  }

  test('a still dashed arrow and a solid one are drawn as before (the body runs under the head)', () async {
    // Dashed (not marching) keeps its body reaching into the swept head's notch: painted there, on the axis
    final dashed = await frame(const ArrowStyle(end: ArrowHead.swept, pattern: LinePattern.longDash, shadow: false), 0);
    final solid = await frame(const ArrowStyle(end: ArrowHead.swept, shadow: false), 0);
    final inNotch = 60 * w + (tip - length * 0.9).round();
    expect(solid[inNotch], isNot(0xFFFFFFFF));
    final marching = await frame(const ArrowStyle(end: ArrowHead.swept, pattern: LinePattern.antsLongDash, shadow: false), 0);
    expect(marching[inNotch], 0xFFFFFFFF, reason: 'a marching body leaves the notch empty');
    expect(moved(dashed, solid, 0, w), greaterThan(0));
  });
}
