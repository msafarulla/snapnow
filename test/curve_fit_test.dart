import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/curve_fit.dart';

/// How far the drag strays from the fitted curve, at worst.
double worst(List<Offset> drag, List<Offset> points, List<Offset?> tangents) {
  final samples = CanvasPainter.curveSamples(points, tangents: tangents, perSegment: 64);
  var w = 0.0;
  for (final p in drag) {
    var best = double.infinity;
    for (final q in samples) {
      best = math.min(best, (p - q).distance);
    }
    w = math.max(w, best);
  }
  return w;
}

/// A drag as the editor hands it to the fit: sampled every few points, shaken by ±jitter/2, then smoothed.
List<Offset> drag(Offset Function(double) f, {double jitter = 0, int seed = 3}) {
  final rnd = math.Random(seed);
  return CurveFit.smoothed(
      [for (var i = 0; i <= 100; i++) f(i / 100) + Offset(rnd.nextDouble() * jitter - jitter / 2, rnd.nextDouble() * jitter - jitter / 2)]);
}

void main() {
  test('a bowed drag is one smooth piece with no bends, within tolerance', () {
    final d = drag((t) => Offset(300 * t, -80 * math.sin(t * math.pi)));
    final f = CurveFit.fit(d, 4);
    expect(f.points.length, 2);
    expect(f.points.first, d.first);
    expect(f.points.last, d.last);
    expect(worst(d, f.points, f.tangents), lessThan(4.5)); // the polyline measure adds a little
  });

  test('an S needs a bend, stays within tolerance, and ends stay put', () {
    final d = drag((t) => Offset(320 * t, 60 * math.sin(t * 2 * math.pi)), jitter: 4);
    CurveFit.debugTrace = true;
    final f = CurveFit.fit(d, 5);
    CurveFit.debugTrace = false;
    expect(f.points.length - 2, inInclusiveRange(1, 3));
    expect(f.points.first, d.first);
    expect(f.points.last, d.last);
    expect(worst(d, f.points, f.tangents), lessThan(6)); // jitter itself is ±2
    expect(f.tangents.length, f.points.length);
    expect(f.tangents.every((t) => t != null), isTrue);
  });

  test('never more than maxBends bends, even for a wild drag', () {
    final d = drag((t) => Offset(400 * t, 50 * math.sin(t * 8 * math.pi)));
    final f = CurveFit.fit(d, 1, maxBends: 4);
    expect(f.points.length - 2, lessThanOrEqualTo(4));
  });

  test('smoothing keeps the ends and flattens shake', () {
    final rnd = math.Random(1);
    final raw = [for (var i = 0; i <= 60; i++) Offset(i * 4.0, rnd.nextDouble() * 6 - 3)];
    final s = CurveFit.smoothed(raw);
    expect(s.first, raw.first);
    expect(s.last, raw.last);
    expect(s.sublist(5, 55).every((p) => p.dy.abs() < 2), isTrue);
  });

  test('tangents point forward along the drag', () {
    final d = drag((t) => Offset(300 * t, -80 * math.sin(t * math.pi)));
    final f = CurveFit.fit(d, 4);
    final t0 = f.tangents.first!, t1 = f.tangents.last!;
    expect(t0.dx, greaterThan(0));
    expect(t0.dy, lessThan(0)); // the bow rises at the start
    expect(t1.dx, greaterThan(0));
    expect(t1.dy, greaterThan(0)); // and comes back down at the end
  });
}
