import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../editor/canvas_painter.dart';
import '../model/annotation.dart';

/// Fourier epicycles for the build-up GIF: a chain of spinning circles whose tip traces a stroke as it
/// draws itself on (the Manim Studio effect, without Manim). Arrows, lines, pen strokes, boxes and
/// ellipses qualify.
///
/// The stroke is sampled evenly by length, so the tip at time `along` sits where the drawn-on stroke ends.
/// An open stroke is traced out and back (so the series is continuous) and only the outward half is shown.
class Epicycles {
  final Offset center;
  final List<({double freq, double re, double im})> terms; // largest first
  final bool closed;
  /// A proper open curve is its straight start→end line plus a sine series that is zero at both ends; the
  /// circles ride along that line. Zero for the others.
  final Offset trendFrom, trendTo;
  Epicycles._(this.center, this.terms, this.closed, {this.trendFrom = Offset.zero, this.trendTo = Offset.zero});

  Offset _trend(double along) => trendFrom + (trendTo - trendFrom) * along;

  static const _samples = 128, _maxCircles = 30;
  /// A proper Fourier curve keeps only the lowest harmonics, enough for 99.5% of the shape's energy and at
  /// most [_maxHarmonic], the finer ones softened (Lanczos σ) so nothing ripples: smooth by
  /// construction, so a wobble in the drag can't survive.
  static const _keep = 0.995, _maxHarmonic = 6;
  static final _cache = Expando<Epicycles>(), _properCache = Expando<Epicycles>();

  static bool fits(Annotation a) =>
      a.shape is ArrowShape || a.shape is LineShape || a.shape is PenShape || a.shape is RectShape || a.shape is EllipseShape;

  static Epicycles? of(Annotation a) {
    if (!fits(a)) return null;
    return _cache[a.shape] ??= _build(a);
  }

  /// The band-limited circles Fourier drawing uses: what they trace is the curve you keep.
  static Epicycles? proper(Annotation a) {
    if (!fits(a)) return null;
    if (a.shape is RectShape || a.shape is EllipseShape) return of(a); // kept as drawn, corners and all
    return _properCache[a.shape] ??= _build(a, proper: true);
  }

  static Epicycles? _build(Annotation a, {bool proper = false}) {
    final path = CanvasPainter.outlinePath(a);
    final metric = path.computeMetrics().firstOrNull;
    if (metric == null || metric.length < 4) return null;
    Offset at(double f) => metric.getTangentForOffset(metric.length * f)!.position;
    final start = at(0), end = at(1);
    final closed = a.shape is RectShape || a.shape is EllipseShape || (end - start).distance < metric.length * 0.03;
    // Open and proper: the bend away from the straight start→end line, extended as an odd function, so its
    // series is all sines, zero at both ends, with no overshoot there. Otherwise out and back.
    final detrend = proper && !closed;
    Offset bend(double f) => at(f) - (start + (end - start) * f);
    final pts = closed
        ? [for (var i = 0; i < _samples; i++) at(i / _samples)]
        : detrend
            ? [for (var i = 0; i <= _samples; i++) bend(i / _samples), for (var i = _samples - 1; i > 0; i--) -bend(i / _samples)]
            : [for (var i = 0; i <= _samples; i++) at(i / _samples), for (var i = _samples - 1; i > 0; i--) at(i / _samples)];

    // Discrete Fourier transform of the points as complex numbers
    final n = pts.length;
    final terms = <({double freq, double re, double im})>[];
    for (var k = -n ~/ 2; k < n - n ~/ 2; k++) {
      var re = 0.0, im = 0.0;
      for (var j = 0; j < n; j++) {
        final angle = -2 * math.pi * k * j / n;
        final c = math.cos(angle), s = math.sin(angle);
        re += pts[j].dx * c - pts[j].dy * s;
        im += pts[j].dx * s + pts[j].dy * c;
      }
      terms.add((freq: k.toDouble(), re: re / n, im: im / n));
    }
    final dc = terms.firstWhere((t) => t.freq == 0);
    double power(({double freq, double re, double im}) t) => t.re * t.re + t.im * t.im;
    var rest = terms.where((t) => t.freq != 0).toList();
    if (proper) {
      final total = rest.fold(0.0, (sum, t) => sum + power(t));
      var harmonic = 1, kept = 0.0;
      for (; harmonic < _maxHarmonic; harmonic++) {
        kept += rest.where((t) => t.freq.abs() == harmonic).fold(0.0, (sum, t) => sum + power(t));
        if (total == 0 || kept / total >= _keep) break;
      }
      // The main wave keeps its size (so the shape does); finer ones fade out toward the cut-off
      double sigma(double k) {
        if (k <= 1) return 1;
        final x = math.pi * (k - 1) / harmonic;
        return math.sin(x) / x;
      }
      rest = [
        for (final t in rest)
          if (t.freq.abs() <= harmonic) (freq: t.freq, re: t.re * sigma(t.freq.abs()), im: t.im * sigma(t.freq.abs())),
      ];
    }
    rest.sort((x, y) => power(y).compareTo(power(x)));
    return Epicycles._(detrend ? Offset.zero : Offset(dc.re, dc.im), proper ? rest : rest.take(_maxCircles).toList(), closed,
        trendFrom: detrend ? start : Offset.zero, trendTo: detrend ? end : Offset.zero);
  }

  /// The point the circles trace at `along` (0…1 of the stroke), and its rate of change per unit of `along`.
  ({Offset at, Offset d}) _trace(double along) {
    final s = closed ? along : along / 2, ds = closed ? 1.0 : 0.5;
    var p = center + _trend(along), d = trendTo - trendFrom;
    for (final t in terms) {
      final w = 2 * math.pi * t.freq, c = math.cos(w * s), sn = math.sin(w * s);
      p += Offset(t.re * c - t.im * sn, t.re * sn + t.im * c);
      d += Offset(-t.re * sn - t.im * c, t.re * c - t.im * sn) * (w * ds);
    }
    return (at: p, d: d);
  }

  /// `a` redrawn as the curve its band-limited circles trace: a smooth Fourier curve (Fourier drawing turns
  /// every new arrow, line and pen stroke into one). An open stroke keeps its ends exactly where they were drawn.
  static Annotation fourierized(Annotation a) {
    final e = proper(a);
    if (e == null || a.shape is RectShape || a.shape is EllipseShape) return a;
    final metric = CanvasPainter.outlinePath(a).computeMetrics().first;
    final start = metric.getTangentForOffset(0)!.position, end = metric.getTangentForOffset(metric.length)!.position;
    // Ends pinned: the small gap at each end is shared out linearly along the curve
    final gap0 = e.closed ? Offset.zero : start - e._trace(0).at, gap1 = e.closed ? Offset.zero : end - e._trace(1).at;
    ({Offset at, Offset d}) point(double u) {
      final t = e._trace(u);
      return (at: t.at + gap0 * (1 - u) + gap1 * u, d: t.d + (gap1 - gap0));
    }

    switch (a.shape) {
      case PenShape():
        const n = 160;
        return a.copyWith(shape: PenShape([for (var i = 0; i <= n; i++) point(e.closed ? (i % n) / n : i / n).at]));
      case ArrowShape() || LineShape():
        // A dozen points with the curve's own tangents (|tangent| = 3 × the Bézier handle = rate × spacing)
        const k = 12;
        final pts = [for (var i = 0; i <= k; i++) point(i / k)];
        final from = pts.first.at, to = pts.last.at, mid = [for (final q in pts.sublist(1, k)) q.at];
        final tangents = <Offset?>[for (final q in pts) q.d / k.toDouble()];
        return a.copyWith(shape: a.shape is ArrowShape
            ? ArrowShape(from, to, points: mid, tangents: tangents)
            : LineShape(from, to, points: mid, tangents: tangents));
      default:
        return a;
    }
  }

  /// The circles' centres and the tip at `along` (0…1 of the stroke).
  List<Offset> chain(double along) {
    final s = closed ? along : along / 2;
    var p = center + _trend(along);
    final out = [p];
    for (final t in terms) {
      final angle = 2 * math.pi * t.freq * s;
      final c = math.cos(angle), sn = math.sin(angle);
      p += Offset(t.re * c - t.im * sn, t.re * sn + t.im * c);
      out.add(p);
    }
    return out;
  }

  /// Draws the circles and their arms — all neutral grey, no annotation colour, dim so the stroke being drawn
  /// stands out (`color` is kept for the signature but intentionally unused). `scale` is output pixels per
  /// image point, to keep lines thin.
  /// How much ink the circles, arms and tip get: 1 = the original look; 0.2 = 80% lighter (chosen 2026-11-04).
  static const weight = 0.2;

  void paint(Canvas canvas, double along, Color color, double scale) {
    final c = chain(along);
    final hair = 1.2 / scale;
    final grey = Colors.white.withValues(alpha: 0.15 * weight); // the dim grey, for circles and arms alike
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair
      ..color = grey;
    final arm = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair * 1.4
      ..strokeCap = StrokeCap.round
      ..color = grey;
    final halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair * 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.black.withValues(alpha: 0.18 * weight); // a soft dark backing so the grey reads on light captures
    // The rings get the same dark backing as the arms: without it a 15%-grey ring is lost in the GIF's
    // 256-colour quantisation and frame-differencing (only the haloed arms survived, so the circles vanished
    // when pasted elsewhere, even though they show on screen).
    final ringHalo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair * 2.2
      ..color = Colors.black.withValues(alpha: 0.18 * weight);
    for (var i = 0; i < c.length - 1; i++) {
      final r = (c[i + 1] - c[i]).distance;
      if (r * scale < 1.5) continue; // too small to see
      canvas.drawCircle(c[i], r, ringHalo);
      canvas.drawCircle(c[i], r, ring);
    }
    final arms = Path()..moveTo(c.first.dx, c.first.dy);
    for (final p in c.skip(1)) {
      arms.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(arms, halo);
    canvas.drawPath(arms, arm);
    // The tracing tip: a grey dot marking where the stroke is being drawn — no colour.
    canvas.drawCircle(c.last, 3 / scale, Paint()..color = Colors.white.withValues(alpha: 0.6 * weight));
    canvas.drawCircle(c.last, 3 / scale, Paint()..style = PaintingStyle.stroke..strokeWidth = hair..color = Colors.black.withValues(alpha: 0.3 * weight));
  }
}
