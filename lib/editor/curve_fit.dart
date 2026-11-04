import 'dart:math' as math;
import 'dart:ui';

/// Fits a smooth curve to a dragged path: start and end stay put, and the curve runs through as few extra
/// points as it takes to stay within `tol` of the drag. The result is the model's curve (points through which
/// the cubic spline flows, with a tangent per point: handles sit a third of the tangent away on each side),
/// so the fitted curve is exactly what the painter draws.
///
/// The fit is a linear least squares over the handle lengths, with the direction at each curve point taken
/// from the drag itself; when the worst sample sits too far from the fitted curve, a bend goes there and
/// the fit is run again, up to `maxBends` bends.
class CurveFit {
  CurveFit._();

  /// Prints each fitting round (debug builds only).
  static bool debugTrace = false;

  /// The drag with hand shake taken out: each point averaged with its neighbours (±`reach`), the ends kept.
  static List<Offset> smoothed(List<Offset> raw, {int reach = 5}) => [
        for (var i = 0; i < raw.length; i++)
          if (i == 0 || i == raw.length - 1)
            raw[i]
          else
            () {
              final from = math.max(0, i - reach), to = math.min(raw.length - 1, i + reach);
              var sum = Offset.zero;
              for (var j = from; j <= to; j++) {
                sum += raw[j];
              }
              return sum / (to - from + 1).toDouble();
            }(),
      ];

  static ({List<Offset> points, List<Offset?> tangents}) fit(List<Offset> pts, double tol, {int maxBends = 4}) {
    final n = pts.length;
    assert(n >= 2);
    if (n == 2) return (points: [pts.first, pts.last], tangents: [null, null]);
    // Chord-length parameter along the drag
    final chord = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      chord[i] = chord[i - 1] + (pts[i] - pts[i - 1]).distance;
    }
    if (chord.last <= 0) return (points: [pts.first, pts.last], tangents: [null, null]);

    var knots = [0, n - 1];
    var tangents = <Offset>[];
    while (true) {
      final dirs = [for (final k in knots) _direction(pts, k)];
      final s = [...chord];
      tangents = _solve(pts, s, knots, dirs);
      // Each sample moves to its nearest point on the fit (Newton) and the fit is solved again on those
      // parameters: usually a closer curve for the same knots; kept when it is
      var (worst, err) = _worst(pts, s, knots, tangents, reparameterize: true);
      final again = _solve(pts, s, knots, dirs);
      final (worst2, err2) = _worst(pts, s, knots, again);
      if (err2 < err) {
        tangents = again;
        (worst, err) = (worst2, err2);
      }
      assert(() { if (debugTrace) print('fit: ${knots.length - 2} bends, worst sample $worst at ${err.toStringAsFixed(2)} h=${[for (final t in tangents) (t.distance / 3).toStringAsFixed(1)]}'); return true; }());
      if (err <= tol || knots.length - 2 >= maxBends || worst < 0) break;
      // A bend goes in the middle of the stretch that strays the most (by length along the drag): a bend has
      // one tangent length for both of its sides, so stretches of a like length fit best
      final j = knots.lastIndexWhere((k) => k < worst);
      final k0 = knots[j], k1 = knots[j + 1], midS = (chord[k0] + chord[k1]) / 2;
      var mid = k0;
      while (mid + 1 < k1 && chord[mid + 1] <= midS) {
        mid++;
      }
      if (mid <= k0 || mid >= k1) break;
      knots = [...knots, mid]..sort();
    }
    return (
      points: [for (final k in knots) pts[k]],
      tangents: [for (final t in tangents) t],
    );
  }

  /// The drag's direction at sample `k`: a few samples either side, so hand wobble is ignored.
  static Offset _direction(List<Offset> pts, int k) {
    final n = pts.length;
    final reach = math.max(1, math.min(n ~/ 6, 6));
    final a = pts[math.max(0, k - reach)], b = pts[math.min(n - 1, k + reach)];
    var d = b - a;
    if (d.distance < 1e-6) d = pts[math.min(n - 1, k + 1)] - pts[math.max(0, k - 1)];
    return d.distance < 1e-6 ? const Offset(1, 0) : d / d.distance;
  }

  /// Least-squares handle lengths h (one per knot) for the spline through the knots with unit directions
  /// `dirs`: on segment j, Q(u) = B0 P_j + B1 (P_j + h_j d_j) + B2 (P_{j+1} - h_{j+1} d_{j+1}) + B3 P_{j+1},
  /// u = the sample's chord-length position within the segment. Returns the model tangents (3 h d).
  static List<Offset> _solve(List<Offset> pts, List<double> s, List<int> knots, List<Offset> dirs) {
    final m = knots.length;
    // Normal equations A h = b, A is tridiagonal (each sample touches two neighbouring knots)
    final diag = List<double>.filled(m, 0), off = List<double>.filled(m - 1, 0), rhs = List<double>.filled(m, 0);
    for (var j = 0; j < m - 1; j++) {
      final k0 = knots[j], k1 = knots[j + 1];
      final p0 = pts[k0], p1 = pts[k1];
      final span = s[k1] - s[k0];
      if (span <= 0) continue;
      for (var i = k0; i <= k1; i++) {
        final u = (s[i] - s[k0]) / span, v = 1 - u;
        final b1 = 3 * v * v * u, b2 = 3 * v * u * u;
        // residual = pts[i] - (p0 (b0+b1) + p1 (b2+b3)) - b1 h0 d0 + b2 h1 d1
        final base = p0 * (v * v * v + b1) + p1 * (b2 + u * u * u);
        final r = pts[i] - base;
        final a0 = dirs[j] * b1, a1 = dirs[j + 1] * -b2;
        diag[j] += a0.dx * a0.dx + a0.dy * a0.dy;
        diag[j + 1] += a1.dx * a1.dx + a1.dy * a1.dy;
        off[j] += a0.dx * a1.dx + a0.dy * a1.dy;
        rhs[j] += a0.dx * r.dx + a0.dy * r.dy;
        rhs[j + 1] += a1.dx * r.dx + a1.dy * r.dy;
      }
    }
    // Handle lengths are kept between a twentieth and 0.7 of the shorter neighbouring stretch (a half circle
    // needs 2/3 of its chord; longer handles loop). Any that falls outside is pinned there and the rest are
    // solved again without it, until all fit
    final lo = List<double>.filled(m, 0), hi = List<double>.filled(m, 0);
    for (var j = 0; j < m; j++) {
      final k = knots[j];
      final before = j > 0 ? s[k] - s[knots[j - 1]] : double.infinity;
      final after = j < m - 1 ? s[knots[j + 1]] - s[k] : double.infinity;
      final span = math.min(before, after);
      lo[j] = span * 0.05;
      hi[j] = span * 0.7;
    }
    final pinned = List<double?>.filled(m, null);
    var h = List<double>.filled(m, 0);
    for (var pass = 0; pass <= m; pass++) {
      final free = [for (var j = 0; j < m; j++) if (pinned[j] == null) j];
      if (free.isEmpty) break;
      final d2 = [for (final j in free) diag[j]];
      final r2 = [
        for (final j in free)
          rhs[j] -
              (j > 0 && pinned[j - 1] != null ? off[j - 1] * pinned[j - 1]! : 0) -
              (j < m - 1 && pinned[j + 1] != null ? off[j] * pinned[j + 1]! : 0),
      ];
      final o2 = [for (var i = 0; i < free.length - 1; i++) free[i + 1] == free[i] + 1 ? off[free[i]] : 0.0];
      final x = _thomas(d2, o2, r2);
      var changed = false;
      for (var i = 0; i < free.length; i++) {
        final j = free[i];
        h[j] = x[i];
        if (!h[j].isFinite || h[j] < lo[j] || h[j] > hi[j]) {
          pinned[j] = h[j].isFinite ? h[j].clamp(lo[j], hi[j]) : (lo[j] + hi[j]) / 2;
          changed = true;
        }
      }
      if (!changed) break;
    }
    for (var j = 0; j < m; j++) {
      if (pinned[j] != null) h[j] = pinned[j]!;
    }
    return [for (var j = 0; j < m; j++) dirs[j] * (3 * h[j])];
  }

  /// Solves the symmetric tridiagonal system (diag, off) x = rhs.
  static List<double> _thomas(List<double> diag, List<double> off, List<double> rhs) {
    final m = diag.length;
    final c = List<double>.filled(m, 0), d = List<double>.filled(m, 0), x = List<double>.filled(m, 0);
    var den = diag[0] == 0 ? 1e-12 : diag[0];
    c[0] = m > 1 ? off[0] / den : 0;
    d[0] = rhs[0] / den;
    for (var i = 1; i < m; i++) {
      den = diag[i] - off[i - 1] * c[i - 1];
      if (den.abs() < 1e-12) den = 1e-12;
      c[i] = i < m - 1 ? off[i] / den : 0;
      d[i] = (rhs[i] - off[i - 1] * d[i - 1]) / den;
    }
    x[m - 1] = d[m - 1];
    for (var i = m - 2; i >= 0; i--) {
      x[i] = d[i] - c[i] * x[i + 1];
    }
    return x;
  }

  /// The sample farthest from the fitted curve (index, distance); -1 when no interior sample is left.
  static (int, double) _worst(List<Offset> pts, List<double> s, List<int> knots, List<Offset> tangents,
      {bool reparameterize = false}) {
    var worst = -1, best = 0.0;
    for (var j = 0; j < knots.length - 1; j++) {
      final k0 = knots[j], k1 = knots[j + 1];
      final p0 = pts[k0], p1 = pts[k1];
      final c1 = p0 + tangents[j] / 3, c2 = p1 - tangents[j + 1] / 3;
      final span = s[k1] - s[k0];
      if (span <= 0) continue;
      for (var i = k0 + 1; i < k1; i++) {
        final u = (s[i] - s[k0]) / span;
        // Nearest point on the piece near u (a few Newton steps on the squared distance)
        var t = u;
        for (var it = 0; it < 4; it++) {
          final q = _cubic(p0, c1, c2, p1, t), d1 = _cubicD1(p0, c1, c2, p1, t), d2 = _cubicD2(p0, c1, c2, p1, t);
          final diff = q - pts[i];
          final num = diff.dx * d1.dx + diff.dy * d1.dy;
          final den = d1.dx * d1.dx + d1.dy * d1.dy + diff.dx * d2.dx + diff.dy * d2.dy;
          if (den.abs() < 1e-9) break;
          t = (t - num / den).clamp(0.0, 1.0);
        }
        final e = (_cubic(p0, c1, c2, p1, t) - pts[i]).distance;
        if (e > best) { best = e; worst = i; }
        if (reparameterize) s[i] = s[k0] + t * span;
      }
    }
    if (reparameterize) {
      // Keep the parameters in order along the drag, so every sample stays on its own stretch
      for (var i = 1; i < s.length; i++) {
        if (s[i] < s[i - 1]) s[i] = s[i - 1];
      }
    }
    return (worst, best);
  }

  static Offset _cubic(Offset a, Offset c1, Offset c2, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
  }

  static Offset _cubicD1(Offset a, Offset c1, Offset c2, Offset b, double t) {
    final u = 1 - t;
    return (c1 - a) * (3 * u * u) + (c2 - c1) * (6 * u * t) + (b - c2) * (3 * t * t);
  }

  static Offset _cubicD2(Offset a, Offset c1, Offset c2, Offset b, double t) {
    final u = 1 - t;
    return (c2 - c1 * 2 + a) * (6 * u) + (b - c2 * 2 + c1) * (6 * t);
  }
}
