import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/curve_fit.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The line and the head read as one stroke: the line passes through the middle of the head's back, travelling along the
/// head's axis there. Tiny freehand arrows (S-curls, hooks, arches of 30-80 px at a 2x display's 10 px line, fitted as draw
/// mode fits a drag) and normal arrows alike.
void main() {
  // A drag of `len` px every 2 px, from its heading along the way
  List<Offset> drag(double len, double Function(double s) heading) {
    final out = <Offset>[const Offset(100, 100)];
    var p = out.first;
    for (var d = 0.0; d < len; d += 2) {
      final h = heading((d + 1) / len);
      p += Offset(math.cos(h), math.sin(h)) * 2;
      out.add(p);
    }
    return out;
  }

  // As draw mode fits a drag: smoothed, then a curve within 5 view points (a 2x display: 10 image px)
  ArrowShape fitted(List<Offset> raw) {
    final pts = CurveFit.smoothed(raw);
    final f = CurveFit.fit(pts, math.max(10, (pts.last - pts.first).distance * 0.03));
    return ArrowShape(raw.first, raw.last, points: f.points.sublist(1, f.points.length - 1), tangents: f.tangents);
  }

  // As draw mode's circular-arc fit: Bezier pieces of a true arc (up, over and down to the right)
  ArrowShape arch(double len) {
    final r = (len / 4).clamp(10.0, 20.0), sweep = len / r, a0 = math.pi + (math.pi - sweep) / 2;
    final pieces = (sweep / (math.pi / 2)).ceil(), step = sweep / pieces, h = 4 * r * math.tan(step / 4);
    Offset on(double a) => const Offset(100, 100) + Offset(math.cos(a), math.sin(a)) * r;
    final pts = [for (var i = 0; i <= pieces; i++) on(a0 + step * i)];
    return ArrowShape(pts.first, pts.last, points: pts.sublist(1, pts.length - 1),
        tangents: [for (var i = 0; i <= pieces; i++) Offset(-math.sin(a0 + step * i), math.cos(a0 + step * i)) * h]);
  }

  // Where the line comes closest to the head's back centre: how far off it is there, and how far its direction is from the axis
  (double, double) join(ArrowShape shape, double w, ArrowHead head) {
    final j = CanvasPainter.endJoin([shape.from, ...shape.points, shape.to], ArrowStyle(end: head), w, tangents: shape.tangents);
    final back = j.tip - j.axis * j.entry;
    var best = double.infinity, angle = 0.0;
    for (final m in j.line.computeMetrics()) {
      for (var d = 0.0; d <= m.length; d += 0.05) {
        final t = m.getTangentForOffset(d)!;
        final off = (t.position - back).distance;
        if (off < best) {
          best = off;
          angle = math.acos((t.vector.dx * j.axis.dx + t.vector.dy * j.axis.dy).clamp(-1.0, 1.0)) * 180 / math.pi;
        }
      }
    }
    return (best, angle);
  }

  void check(ArrowShape shape, double w, ArrowHead head, {bool tail = false}) {
    final (off, angle) = join(shape, w, head);
    expect(off, lessThan(0.5), reason: 'distance from the line to the head back centre');
    expect(angle, lessThan(3), reason: 'degrees between the line and the head axis where they meet');
    final j = CanvasPainter.endJoin([shape.from, ...shape.points, shape.to], ArrowStyle(end: head), w, tangents: shape.tangents);
    final curve = [for (final m in j.curve.computeMetrics()) for (var d = 0.0; d <= m.length; d += 0.25) m.getTangentForOffset(d)!.position];
    for (final m in j.line.computeMetrics()) {
      for (var d = 0.0; d <= m.length; d += 0.5) {
        final t = m.getTangentForOffset(d)!, fromTip = m.length - d + j.entry; // about how far back from the tip, along the path
        // Outside the last stretch the line is the drawn stroke
        if (fromTip > j.blendFrom + 0.5) {
          final near = curve.map((q) => (q - t.position).distance).reduce(math.min);
          expect(near, lessThan(1), reason: 'the line leaves the drawn stroke');
        }
        // The head lies over the line only at its own back, never over the tail
        if (tail && fromTip > 1.5 * j.headLength) {
          final n = Offset(-t.vector.dy, t.vector.dx) * (j.lineWidth / 2);
          for (final q in [t.position, t.position + n, t.position - n]) {
            expect(j.head!.contains(q), isFalse, reason: 'the head covers the tail');
          }
        }
      }
    }
  }

  for (final len in [30.0, 45.0, 60.0, 80.0]) {
    final r = (len / 4).clamp(10.0, 20.0);
    final shapes = [
      ('S-curl', fitted(drag(len, (s) => 1.2 * math.sin(2 * math.pi * s) - math.pi / 2 * s))),
      ('hook', fitted(drag(len, (s) => s * len < len - r * 2.2 ? 0 : (s * len - (len - r * 2.2)) / r))),
      ('arch', arch(len)),
    ];
    for (final (name, shape) in shapes) {
      for (final head in [ArrowHead.swept, ArrowHead.triangle]) {
        final title = [name, len.toInt(), 'px,', head.label, '- the line runs into the middle of the head along its axis'].join(' ');
        test(title, () => check(shape, 10, head, tail: len >= 45));
      }
    }
  }

  // Normal (long) arrows keep their 1.86.1 drawing (golden test): a straight one meets its head exactly; a bent one still
  // takes its head along the curve's end tangent, so the line passes up to a few px beside the middle of the head's back
  test('normal straight arrows: the line passes through the middle of the head along its axis', () {
    for (final shape in [
      const ArrowShape(Offset(30, 170), Offset(370, 30)),
      const ArrowShape(Offset(380, 40), Offset(20, 160)),
    ]) {
      for (final head in [ArrowHead.swept, ArrowHead.triangle]) {
        check(shape, 8, head);
      }
    }
  });
}
