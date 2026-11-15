import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// A tiny freehand arrow on a 2x display (10 px line, a 50 px head at full size): a 60 px arch over a 15 px circle, as
/// draw mode fits it (Bezier pieces of a true arc, ends on the circle). Its head must stay in proportion and point the way
/// the stroke ended, plain or with an effect.
void main() {
  const c = Offset(200, 120), r = 15.0, sweep = 4.0; // 60 px of arc, up, over and down to the right
  const a0 = math.pi + (math.pi - sweep) / 2;
  final pieces = (sweep / (math.pi / 2)).ceil(), step = sweep / pieces, len = 4 * r * math.tan(step / 4);
  Offset on(double a) => c + Offset(math.cos(a), math.sin(a)) * r;
  final pts = [for (var i = 0; i <= pieces; i++) on(a0 + step * i)];
  final tangents = <Offset?>[for (var i = 0; i <= pieces; i++) Offset(-math.sin(a0 + step * i), math.cos(a0 + step * i)) * len];
  final shape = ArrowShape(pts.first, pts.last, points: pts.sublist(1, pts.length - 1), tangents: tangents);
  final tip = pts.last;

  Future<Uint32List> paint(ArrowStyle style) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 400, 240), Paint()..color = const Color(0xFF203040));
    CanvasPainter.drawAnnotation(canvas, Annotation(id: 1, color: Colors.cyan, scale: 2, arrowStyle: style, shape: shape));
    final img = await rec.endRecording().toImage(400, 240);
    return (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint32List();
  }

  for (final e in [ArrowEffect.none, ArrowEffect.flow]) {
    test('${e.label}: a tiny curled arrow keeps a small head pointing along the end of the stroke', () async {
      final headed = await paint(ArrowStyle(end: ArrowHead.swept, shadow: false, effect: e));
      final bare = await paint(ArrowStyle(end: ArrowHead.none, shadow: false, effect: e));
      // Where the head is: its wings, i.e. what it covers clear of the line (the line thins to 5 px here: more than 4 px off the curve)
      final bg = headed[0];
      // Clearly painted, not the faint, slightly shifting edge of an effect's blurred shadow
      bool painted(int a, int b) => [0, 8, 16].any((sh) => (((a >> sh) & 255) - ((b >> sh) & 255)).abs() > 40);
      final curve = CanvasPainter.curveSamples([shape.from, ...shape.points, shape.to], tangents: tangents, perSegment: 100);
      var minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9, sum = Offset.zero, n = 0;
      for (var i = 0; i < headed.length; i++) {
        if (!painted(headed[i], bg) || painted(bare[i], bg)) continue;
        final p = Offset((i % 400).toDouble(), (i ~/ 400).toDouble());
        if (curve.any((q) => (q - p).distance <= 4)) continue;
        minX = math.min(minX, p.dx); maxX = math.max(maxX, p.dx); minY = math.min(minY, p.dy); maxY = math.max(maxY, p.dy);
        sum += p;
        n++;
      }
      expect(n, greaterThan(8));
      final extent = Offset(maxX - minX, maxY - minY).distance;
      expect(extent, lessThan(36), reason: 'the head is about a third of a 60 px arrow, not bigger than the arrow (1.86.1: 70-100)');
      // The head lies back from the tip along the stroke's last stretch (the chord from 20 px of arc back), not along
      // the curl's own end tangent, which is 38 degrees away from it
      final back = on(a0 + sweep - 20 / r);
      final chord = (back - tip) / (back - tip).distance, toCentre = (sum / n.toDouble() - tip);
      final angle = math.acos((chord.dx * toCentre.dx + chord.dy * toCentre.dy) / toCentre.distance) * 180 / math.pi;
      expect(angle, lessThan(20), reason: 'the head points the way the stroke was going at its end');
    });
  }
}
