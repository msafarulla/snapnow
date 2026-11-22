import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show ValueListenable, visibleForTesting;
import 'package:flutter/material.dart';
import '../export/epicycles.dart';
import '../model/annotation.dart';

/// Renders a [CanvasState] (base image + annotations) and the selection chrome.
/// Everything is drawn in image coordinates; the widget wraps it in a FittedBox-style scale.
/// Arrow/line/shape drawing is a port of the Swift app's Renderer (heads, tapering, patterns,
/// outline, shadow), so annotations look the same in both.
class CanvasPainter extends CustomPainter {
  final CanvasState state;
  final int? selectionId;
  final double scale; // view points per image point, for crisp 1px handles
  final double? scaleY; // vertical scale (defaults to [scale]); differs only in the editor after a non-proportional resize
  final int? hiddenTextId; // being typed into: the inline text field draws its text
  /// For the build-up GIF: how far each annotation has appeared (id → 0…1; missing = not yet).
  /// Null draws everything as it is.
  final Map<int, double>? progress;
  /// How far marching-ants lines have run (0…1 of one dash cycle); the editor's timer and the GIF's
  /// final hold move it. Null draws them still.
  final ValueListenable<double>? march;
  /// For the build-up GIF: spinning Fourier circles trace lines, pen strokes and outlines as they draw on.
  final bool epicycles;
  /// For the build-up GIF: lines, strokes and outlines appear as the envelope of their tangent lines (string art).
  final bool envelope;
  /// Draw mode: the base picture is fully transparent (the glass), so it is not drawn at all. On a 5K display that image is
  /// ~15 megapixels, redrawn (mipmapped) on every repaint for nothing.
  final bool clearBase;
  /// Draw mode being lifted: how much of each annotation still shows (id → 0…1; missing = all of it). Only the glass on
  /// screen gets it; what is saved is painted without it. Null draws everything as it is.
  final Map<int, double>? fade;
  /// With [fade]: each annotation leaves by flying from the centre of its box ([flyFrom], id → its bounds in image
  /// coordinates) into [flyTo] (the menu bar icon, image coordinates), shrinking on the way, instead of only fading. The box
  /// also bounds the layer of its final fade, so many marks in flight never mean many display-sized layers. Null: a plain fade.
  final Map<int, Rect>? flyFrom;
  final Offset? flyTo;
  /// Which part of the picture this painter draws, so the editor can keep the costly, unchanging part in one cached layer
  /// and repaint only the rest on every [march] tick: the annotations from index [first] up to (not including) [end]
  /// (null = the last one), and with [under] what lies below all of them: the canvas colour, the base image, blur patches
  /// and the spotlight. The defaults draw everything. Step numbers count every step in the state, whichever part it is in.
  final int first;
  final int? end;
  final bool under;

  /// Whether [a] moves with [march] once it is committed (Marching Ants patterns and the animated effects).
  static bool animates(Annotation a) =>
      a.styleKind != null && (a.arrowStyle.pattern.marches || a.arrowStyle.effect != ArrowEffect.none);

  /// The index of the first annotation that [animates], or -1 when the picture stands still.
  static int firstAnimated(CanvasState s) => s.annotations.indexWhere(animates);

  /// How many times a painter has drawn the [under] part (tests: the base picture must not be redrawn on march ticks).
  @visibleForTesting
  static int underPaints = 0;

  /// How many times a painter has drawn a part without [under] (tests: the marching part must keep repainting).
  @visibleForTesting
  static int overPaints = 0;

  /// [animate] makes the painter repaint on every [march] tick: only wanted when a committed annotation
  /// actually marches, so the editor's cached picture layer isn't re-rasterised 25× a second for nothing.
  CanvasPainter({required this.state, required this.selectionId, required this.scale, this.scaleY, this.hiddenTextId,
      this.progress, this.march, this.epicycles = false, this.envelope = false, this.clearBase = false, this.fade, this.flyFrom, this.flyTo,
      this.first = 0, this.end, this.under = true, bool animate = false})
      : super(repaint: animate ? march : null);

  double get _sy => scaleY ?? scale; // vertical scale, == scale unless a non-proportional editor resize set it

  double _shown(Annotation a) => progress == null ? 1 : progress![a.id] ?? 0;

  double _opacity(Annotation a) => fade == null ? 1 : fade![a.id] ?? 1;

  /// Runs [draw] at [opacity]: through a layer only while the annotation is fading out (draw mode's closing).
  static void _faded(Canvas canvas, double opacity, void Function() draw, {Rect? bounds}) {
    if (opacity >= 1) return draw();
    canvas.saveLayer(bounds, Paint()..color = Colors.black.withValues(alpha: opacity));
    draw();
    canvas.restore();
  }

  /// Runs [draw] for an annotation that is leaving ([opacity] 1 → 0 is its way out): with [flyTo] it shrinks along a slight
  /// arc into that point (the same path, scale and fade as the all-at-once animation: 3% size, fading over the last
  /// third); without, it only fades.
  void _leaving(Canvas canvas, Annotation a, double opacity, void Function() draw) {
    final box = flyFrom?[a.id], to = flyTo;
    if (opacity >= 1 || box == null || to == null) return _faded(canvas, opacity, draw);
    final from = box.center;
    final p = 1 - opacity, q = opacity;
    final bend = Offset(from.dx + (to.dx - from.dx) * 0.2, from.dy + (to.dy - from.dy) * 0.95);
    final at = from * (q * q) + bend * (2 * q * p) + to * (p * p);
    final size = 1 - 0.97 * p;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(size);
    canvas.translate(-from.dx, -from.dy);
    // The layer hugs the mark (generous room for heads, outlines, shadows and halos), in its own, unscaled coordinates
    _faded(canvas, p < 0.65 ? 1 : (1 - p) / 0.35, draw, bounds: box.inflate(48 + a.lineWidth * 8));
    canvas.restore();
  }

  /// How many march loops the slowest animation takes: Neon breathes once per [neonLoops] loops (about 2.4 s in the editor),
  /// everything else once per loop. The [march] phase therefore runs 0…[neonLoops], and each user takes it modulo 1
  /// (a loop) or modulo [neonLoops] (a breath); after [neonLoops] loops every effect is back where it started.
  static const neonLoops = 3;

  /// [march] for the paint in progress (the static draw helpers read it), 0 outside one.
  static double _marchNow = 0;

  /// Runs [draw] with this painter's [march] phase in force, so static draw helpers called from another
  /// painter (the editor's overlay drawing a live stroke) march in step with the picture underneath.
  void withMarch(void Function() draw) {
    final outer = _marchNow; // restored after, so a paint inside another paint can't leak its phase
    _marchNow = march?.value ?? 0;
    draw();
    _marchNow = outer;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save(); // the gesture preview paints after this, so leave the canvas unscaled
    final outer = _marchNow; // restored after, so a paint inside another paint can't leak its phase
    _marchNow = march?.value ?? 0;
    _paintScaled(canvas);
    _marchNow = outer;
    canvas.restore();
  }

  void _paintScaled(Canvas canvas) {
    canvas.scale(scale, _sy); // draw everything in image coordinates (per-axis after a non-proportional resize)
    final img = state.image;
    final imageRect = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    under ? underPaints++ : overPaints++;
    if (under && !clearBase) {
      canvas.drawRect(imageRect, Paint()..color = state.background); // canvas colour behind the image
      // Smoothed when drawn smaller (GIFs at point size, zoomed-out editor): unfiltered drops pixels, jagged text
      canvas.drawImage(img, Offset.zero, Paint()..filterQuality = FilterQuality.medium);
    }

    // Blur patches first, then spotlight dimming, then the rest in order.
    final spotlights = <(Rect, double)>[];
    for (final a in under ? state.annotations : const <Annotation>[]) {
      final t = _shown(a), o = _opacity(a);
      if (t <= 0 || o <= 0) continue;
      switch (a.shape) {
        case BlurShape():
          _faded(canvas, o, () => drawPartial(canvas, a, t, base: img));
        case SpotlightShape(:final rect):
          spotlights.add((rect, t * o));
        default:
          break;
      }
    }
    if (spotlights.isNotEmpty) _drawSpotlight(canvas, spotlights, imageRect);

    var step = 0;
    final last = end ?? state.annotations.length;
    for (var i = 0; i < state.annotations.length; i++) {
      final a = state.annotations[i];
      if (a.shape is StepShape) step += 1; // steps keep their final numbers while the others are still hidden
      if (i < first || i >= last) continue; // another painter's part
      final t = _shown(a), o = _opacity(a);
      if (t <= 0 || o <= 0) continue;
      switch (a.shape) {
        case BlurShape():
        case SpotlightShape():
          continue;
        case StepShape():
          final number = step;
          _leaving(canvas, a, o, () => drawPartial(canvas, a, t, number: number));
        default:
          _leaving(canvas, a, o, () => drawPartial(canvas, a, t, hideText: a.id == hiddenTextId, envelope: envelope));
          if (epicycles && t < 1) Epicycles.of(a)?.paint(canvas, Curves.easeInOut.transform(t), a.color, scale);
      }
    }
  }

  /// The selection's handles (drawn separately so the image clip doesn't cut off handles on its edge).
  void paintSelection(Canvas canvas) {
    final sel = state.annotations.where((a) => a.id == selectionId).firstOrNull;
    if (sel == null) return;
    canvas.save();
    canvas.scale(scale, _sy);
    _drawSelection(canvas, sel);
    canvas.restore();
  }

  /// Draws one annotation (also used for Quick Style tiles and previews).
  static void drawAnnotation(Canvas canvas, Annotation a, {int number = 0, ui.Image? base, bool hideText = false}) {
    final w = a.lineWidth;
    switch (a.shape) {
      case ArrowShape() || LineShape():
        if (a.arrowStyle.snake) {
          drawSnake(canvas, a.curve!, a.arrowStyle, a.color, w, tangents: a.curveTangents);
        } else if (a.arrowStyle.effect != ArrowEffect.none) {
          drawEffect(canvas, a.curve!, a.arrowStyle, a.color, w, tangents: a.curveTangents);
        } else {
          drawArrow(canvas, a.curve!, a.arrowStyle, a.color, w, tangents: a.curveTangents);
        }
      case RectShape(:final rect):
        strokeStyled(canvas, Path()..addRRect(RRect.fromRectXY(rect, 2, 2)), a.arrowStyle, a.color, w);
      case EllipseShape(:final rect):
        strokeStyled(canvas, Path()..addOval(rect), a.arrowStyle, a.color, w);
      case HighlightShape(:final rect):
        canvas.drawRect(rect, Paint()..color = a.color.withValues(alpha: 0.45)..blendMode = BlendMode.multiply);
      case PenShape(:final points):
        strokeStyled(canvas, _smooth(points), a.arrowStyle, a.color, w);
      case TextShape(:final string, :final at):
        if (!hideText) textLayout(string, a, a.color, halo: true).paint(canvas, at);
      case CalloutShape(:final string, :final at, :final tail):
        _callout(canvas, string, at, tail, a, hideText: hideText);
      case StepShape(:final center):
        _step(canvas, center, number, a);
      case BlurShape(:final rect):
        if (base == null) break;
        // Live blur of the base image within the rect (no precomputed patch needed).
        canvas.save();
        canvas.clipRRect(RRect.fromRectXY(rect, 2, 2));
        canvas.drawImageRect(base, rect, rect,
            Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14, tileMode: TileMode.clamp));
        canvas.restore();
      case ImageShape(:final rect, :final image):
        canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), rect,
            Paint()..filterQuality = FilterQuality.high);
      case SpotlightShape():
        break;
    }
  }

  /// An annotation part-way through appearing (`t` 0…1, for the build-up GIF): lines and outlines draw
  /// themselves on, highlights wipe across, steps and callouts pop in, everything else fades in.
  /// With [envelope], lines, strokes and outlines appear as the string art of their tangents instead.
  static void drawPartial(Canvas canvas, Annotation a, double t,
      {int number = 0, ui.Image? base, bool hideText = false, bool envelope = false}) {
    if (t >= 1) return drawAnnotation(canvas, a, number: number, base: base, hideText: hideText);
    if (t <= 0) return;
    if (envelope && hasOutline(a)) return tangentEnvelope(canvas, a, t);
    final w = a.lineWidth, along = Curves.easeInOut.transform(t);
    switch (a.shape) {
      case ArrowShape() || LineShape():
        final pts = partialCurve(a.curve!, a.curveTangents, along);
        if (pts != null) {
          if (a.arrowStyle.snake) {
            drawSnake(canvas, pts, a.arrowStyle, a.color, w);
          } else if (a.arrowStyle.effect != ArrowEffect.none) {
            drawEffect(canvas, pts, a.arrowStyle, a.color, w);
          } else {
            drawArrow(canvas, pts, a.arrowStyle, a.color, w);
          }
        }
      case RectShape(:final rect):
        strokeStyled(canvas, _drawnOn(Path()..addRRect(RRect.fromRectXY(rect, 2, 2)), along), a.arrowStyle, a.color, w);
      case EllipseShape(:final rect):
        strokeStyled(canvas, _drawnOn(Path()..addOval(rect), along), a.arrowStyle, a.color, w);
      case PenShape(:final points):
        strokeStyled(canvas, _drawnOn(_smooth(points), along), a.arrowStyle, a.color, w);
      case HighlightShape(:final rect):
        drawAnnotation(canvas, a.withRect(Rect.fromLTWH(rect.left, rect.top, rect.width * along, rect.height)));
      case StepShape(:final center):
        _popIn(canvas, center, t, () => drawAnnotation(canvas, a, number: number));
      case CalloutShape(:final string, :final at):
        _popIn(canvas, calloutRect(string, at, a).center, t, () => drawAnnotation(canvas, a, hideText: hideText));
      default:
        canvas.saveLayer(null, Paint()..color = Colors.black.withValues(alpha: t));
        drawAnnotation(canvas, a, number: number, base: base, hideText: hideText);
        canvas.restore();
    }
  }

  /// The line an arrow, line, pen stroke, box or ellipse draws along (what [drawPartial] draws on by length).
  static Path outlinePath(Annotation a) => switch (a.shape) {
        ArrowShape() || LineShape() => Path()..addPolygon(curveSamples(a.curve!, tangents: a.curveTangents, perSegment: 32), false),
        RectShape(:final rect) => Path()..addRRect(RRect.fromRectXY(rect, 2, 2)),
        EllipseShape(:final rect) => Path()..addOval(rect),
        PenShape(:final points) => _smooth(points),
        _ => Path(),
      };

  /// Whether an annotation is drawn along a line (arrow, line, pen stroke, box, ellipse): what [outlinePath]
  /// covers and the tangent envelope can build.
  static bool hasOutline(Annotation a) =>
      a.shape is ArrowShape || a.shape is LineShape || a.shape is PenShape || a.shape is RectShape || a.shape is EllipseShape;

  /// A line, stroke or outline part-way through appearing as the envelope of its tangents, `t` 0…1: thin
  /// lines tangent to the path are laid down one after another along it (the newest few bright, the rest
  /// faint) and the shape emerges as the string art they wrap; the stroke itself follows a little behind the
  /// newest tangent. The fan fades over the last stretch, and the heads come with the finished shape at t = 1.
  static void tangentEnvelope(Canvas canvas, Annotation a, double t) {
    final w = a.lineWidth;
    final metrics = outlinePath(a).computeMetrics().toList();
    if (metrics.isEmpty) return;
    final total = metrics.fold(0.0, (sum, m) => sum + m.length);
    if (total <= 0) return;
    final count = _fanCount(total);
    final frontier = Curves.easeInOut.transform(t);
    final shown = (frontier * count).floor();
    final fade = t > 0.86 ? ((1 - t) / 0.14).clamp(0.0, 1.0) : 1.0;
    final along = ((frontier - 0.08) / 0.86).clamp(0.0, 1.0);
    if (along > 0) {
      final drawn = Path();
      for (final m in metrics) {
        drawn.addPath(m.extractPath(0, m.length * along), Offset.zero);
      }
      strokeStyled(canvas, drawn, a.arrowStyle, a.color, w);
    }
    if (fade <= 0) return;
    _fan(canvas, a, metrics, total, shown, count, fade);
  }

  /// String art while drawing: the tangents along the whole stroke so far, the newest (at the pen) brightest.
  static void tangentFan(Canvas canvas, Annotation a) {
    final metrics = outlinePath(a).computeMetrics().toList();
    if (metrics.isEmpty) return;
    final total = metrics.fold(0.0, (sum, m) => sum + m.length);
    if (total <= 0) return;
    final count = _fanCount(total);
    _fan(canvas, a, metrics, total, count, count, 1);
  }

  static int _fanCount(double total) => (total / 1.25).clamp(240, 960).round(); // tangents along the whole path

  static void _fan(Canvas canvas, Annotation a, List<ui.PathMetric> metrics, double total, int shown, int count, double fade) {
    final half = (total * 0.22).clamp(28.0, 150.0); // each tangent reaches this far either side
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.7, a.lineWidth * 0.22)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < shown; i++) {
      final d = total * (i + 0.5) / count;
      var base = 0.0;
      ui.Tangent? tangent;
      for (final m in metrics) {
        if (d <= base + m.length) {
          tangent = m.getTangentForOffset(d - base);
          break;
        }
        base += m.length;
      }
      if (tangent == null || tangent.vector.distance == 0) continue;
      final age = shown - i; // 1 = the newest
      final alpha = (age <= 24 ? 0.7 - 0.025 * (age - 1) : 0.1) * fade;
      line.color = a.color.withValues(alpha: alpha);
      final v = tangent.vector / tangent.vector.distance * half;
      canvas.drawLine(tangent.position - v, tangent.position + v, line);
    }
  }

  /// The first `fraction` of `path`, by length.
  static Path _drawnOn(Path path, double fraction) {
    final out = Path();
    for (final m in path.computeMetrics()) {
      out.addPath(m.extractPath(0, m.length * fraction), Offset.zero);
    }
    return out;
  }

  /// Grows from nothing around `center`, overshooting a little, while fading in.
  static void _popIn(Canvas canvas, Offset center, double t, void Function() draw) {
    final s = Curves.easeOutBack.transform(t);
    if (s <= 0.01) return;
    canvas.saveLayer(null, Paint()..color = Colors.black.withValues(alpha: math.min(1, t * 2)));
    canvas.translate(center.dx, center.dy);
    canvas.scale(s);
    canvas.translate(-center.dx, -center.dy);
    draw();
    canvas.restore();
  }

  /// The first `fraction` (by length) of the curve through `pts`, as points close enough together to
  /// redraw it with drawArrow (so the head rides along the tip); null while it is still too short.
  static List<Offset>? partialCurve(List<Offset> pts, List<Offset?> tangents, double fraction) {
    final s = curveSamples(pts, tangents: tangents, perSegment: 32);
    final cum = <double>[0];
    for (var i = 1; i < s.length; i++) {
      cum.add(cum.last + (s[i] - s[i - 1]).distance);
    }
    final target = cum.last * fraction;
    final out = <Offset>[s.first];
    for (var i = 1; i < s.length; i++) {
      if (cum[i] <= target) {
        out.add(s[i]);
      } else {
        final f = (target - cum[i - 1]) / math.max(cum[i] - cum[i - 1], 1e-9);
        out.add(Offset.lerp(s[i - 1], s[i], f)!);
        break;
      }
    }
    if (out.length < 2 || (out.last - out.first).distance <= 1) return null;
    final every = math.max(1, (out.length / 40).ceil()); // keep the spline light
    return [for (var i = 0; i < out.length - 1; i += every) out[i], out.last];
  }

  // ---- Arrows and lines ----

  /// A point on the cubic a → b with controls c1, c2.
  static Offset cubicPoint(Offset a, Offset c1, Offset c2, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
  }

  /// The curve's direction at point `i`: the one set by its tangent handles, or the automatic smooth one
  /// (Catmull-Rom). Its handles sit a third of it away on each side, like Bézier control points.
  static Offset tangentAt(List<Offset> pts, List<Offset?> tangents, int i) {
    final set = i < tangents.length ? tangents[i] : null;
    if (set != null) return set;
    final n = pts.length;
    if (n < 2) return Offset.zero;
    if (i == 0) return (pts[1] - pts[0]) / 2;
    if (i == n - 1) return (pts[n - 1] - pts[n - 2]) / 2;
    return (pts[i + 1] - pts[i - 1]) / 2;
  }

  /// The cubic segments (a, c1, c2, b) of a smooth curve through every point; two points with automatic
  /// tangents give a straight line.
  static List<(Offset, Offset, Offset, Offset)> spline(List<Offset> pts, [List<Offset?> tangents = const []]) => [
        for (var i = 0; i < pts.length - 1; i++)
          (pts[i], pts[i] + tangentAt(pts, tangents, i) / 3, pts[i + 1] - tangentAt(pts, tangents, i + 1) / 3, pts[i + 1]),
      ];

  /// Points along the curve (for hit-testing and the tapered body).
  static List<Offset> curveSamples(List<Offset> pts, {List<Offset?> tangents = const [], int perSegment = 24}) {
    final segs = spline(pts, tangents);
    return [
      pts.first,
      for (final (a, c1, c2, b) in segs)
        for (var i = 1; i <= perSegment; i++) cubicPoint(a, c1, c2, b, i / perSegment),
    ];
  }

  /// Where a new bend point can be pulled out: the middle of each stretch of the curve ("+" handles).
  static List<Offset> addHandles(List<Offset> pts, [List<Offset?> tangents = const []]) =>
      [for (final (a, c1, c2, b) in spline(pts, tangents)) cubicPoint(a, c1, c2, b, 0.5)];

  /// Every handle of a selected arrow or line, in a fixed order: start, end, bend points, "+" handles,
  /// then the tangent handles (two per bend point, one inward at each end).
  static List<CurveGrip> curveGrips(Annotation a) {
    final pts = a.curve!, tg = a.curveTangents, n = pts.length;
    return [
      (at: pts.first, kind: GripKind.end, index: 0, side: 0),
      (at: pts.last, kind: GripKind.end, index: n - 1, side: 0),
      for (var i = 1; i < n - 1; i++) (at: pts[i], kind: GripKind.bend, index: i, side: 0),
      for (final (stretch, at) in addHandles(pts, tg).indexed) (at: at, kind: GripKind.add, index: stretch, side: 0),
      for (var i = 0; i < n; i++) ...[
        if (i > 0) (at: pts[i] - tangentAt(pts, tg, i) / 3, kind: GripKind.tangent, index: i, side: -1),
        if (i < n - 1) (at: pts[i] + tangentAt(pts, tg, i) / 3, kind: GripKind.tangent, index: i, side: 1),
      ],
    ];
  }

  static Path _curvePath(List<Offset> pts, List<Offset?> tangents) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final (_, c1, c2, b) in spline(pts, tangents)) {
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, b.dx, b.dy);
    }
    return path;
  }

  static Offset _unit(Offset from, Offset to) {
    final d = to - from;
    final len = math.max(d.distance, 0.0001);
    return d / len;
  }

  /// A head at `tip`, pointing away from `from`. `trim` is where the body stops so its cap hides under the head;
  /// `back` is how far behind the tip the head's rearmost edge is (where a marching body stops instead).
  /// How much smaller a marker at the start of an arrow is drawn (1.88.1: "start of the arrow shapes are too big"): a dot,
  /// circle, square, diamond or bar at the tail marks where the arrow comes from and should not compete with the head, so
  /// it is drawn at half size (0.7 in 1.88.1, 0.5 since 1.88.2). The same shape at both ends (a dot-to-dot line) and pointed heads (a two-headed
  /// arrow) stay full size, so both ends match.
  static double tailScale(ArrowHead start, ArrowHead end) =>
      start != end && const {ArrowHead.dot, ArrowHead.circle, ArrowHead.square, ArrowHead.diamond, ArrowHead.bar}.contains(start) ? 0.5 : 1.0;

  static _Head _head(ArrowHead kind, Offset tip, Offset from, double w, double k) {
    final u = _unit(from, tip);
    final n = Offset(-u.dy, u.dx);
    Offset at(double along, double across) => tip - u * along + n * across;
    Path polygon(List<Offset> pts) => Path()..addPolygon(pts, true);
    Path stroked(List<Offset> pts) => Path()..addPolygon(pts, false);
    final length = math.max(14.0, w * 5) * k, half = length * 0.55;
    final thin = math.max(1.5, w * 0.6);
    switch (kind) {
      case ArrowHead.none:
        return _Head(null, trim: tip);
      case ArrowHead.triangle:
        return _Head(polygon([tip, at(length, half), at(length, -half)]), trim: at(length * 0.8, 0), back: length);
      case ArrowHead.swept:
        return _Head(polygon([tip, at(length * 1.1, half), at(length * 0.7, 0), at(length * 1.1, -half)]),
            trim: at(length * 0.6, 0), back: length * 1.1, hollow: true); // the notch is open
      case ArrowHead.triangleOutline:
        return _Head(polygon([tip, at(length, half), at(length, -half)]), filled: false, lineWidth: thin,
            trim: at(length, 0), back: length + thin / 2, hollow: true);
      case ArrowHead.open:
        return _Head(stroked([at(length * 0.75, half), tip, at(length * 0.75, -half)]), filled: false, lineWidth: w,
            trim: tip, back: length * 0.75, hollow: true);
      case ArrowHead.dot:
        final r = math.max(4.0, w * 1.4) * k;
        return _Head(Path()..addOval(Rect.fromCircle(center: tip, radius: r)), trim: tip, back: r);
      case ArrowHead.circle:
        final r = math.max(5.0, w * 1.8) * k;
        return _Head(Path()..addOval(Rect.fromCircle(center: tip, radius: r)), filled: false, lineWidth: thin,
            trim: at(r, 0), back: r + thin / 2, hollow: true);
      case ArrowHead.square:
        final s = math.max(4.0, w * 1.4) * k;
        return _Head(polygon([at(-s, s), at(-s, -s), at(s, -s), at(s, s)]), trim: tip, back: s);
      case ArrowHead.diamond:
        final d = math.max(8.0, w * 2.8) * k;
        return _Head(polygon([at(-d, 0), at(0, d * 0.7), at(d, 0), at(0, -d * 0.7)]), trim: tip, back: d);
      case ArrowHead.bar:
        final s = math.max(7.0, w * 2.4) * k;
        return _Head(stroked([at(0, s), at(0, -s)]), filled: false, lineWidth: w, trim: tip, back: w / 2);
    }
  }

  /// A filled outline whose width grows from a thin tail to the head end.
  static Path _taperedBody(List<Offset> pts, List<Offset?> tangents, double width) {
    final points = curveSamples(pts, tangents: tangents, perSegment: math.max(8, 40 ~/ (pts.length - 1)));
    final count = points.length - 1;
    final left = <Offset>[], right = <Offset>[];
    for (var i = 0; i <= count; i++) {
      final t = i / count;
      final u = _unit(points[math.max(i - 1, 0)], points[math.min(i + 1, count)]);
      final half = width * (0.15 + 0.85 * t) * 0.9;
      left.add(Offset(points[i].dx - u.dy * half, points[i].dy + u.dx * half));
      right.add(Offset(points[i].dx + u.dy * half, points[i].dy - u.dx * half));
    }
    return Path()..addPolygon([...left, ...right.reversed], true);
  }

  /// Black on light colors, white on dark ones (outline and callout/step text).
  static Color contrast(Color c) {
    final hsv = HSVColor.fromColor(c);
    return hsv.value > 0.75 && hsv.saturation < 0.6 ? Colors.black : Colors.white;
  }

  /// The Border effect's edge: the same hue, nearly black, as on route maps (dark grey for black lines).
  static Color darker(Color c) {
    final hsl = HSLColor.fromColor(c);
    if (hsl.lightness < 0.15) return const Color(0xFF4A4A4A);
    return hsl.withLightness((hsl.lightness * 0.3).clamp(0.0, 1.0)).toColor();
  }

  /// The Border effect's shine down the middle of the line, which makes it read as a glossy tube.
  static Color shine(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + (1 - hsl.lightness) * 0.45).clamp(0.0, 1.0)).toColor().withValues(alpha: 0.6);
  }

  /// `path` cut into dashes (near-zero dashes become dots under round caps).
  static Path dashed(Path path, List<double>? dashes, {double phase = 0}) {
    if (dashes == null) return path;
    final out = Path();
    for (final metric in path.computeMetrics()) {
      var d = -phase, i = 0;
      while (d < metric.length) {
        final len = dashes[i % dashes.length];
        final from = math.max(d, 0.0), to = math.min(d + math.max(len, 0.01), metric.length);
        if (i.isEven && to > from) out.addPath(metric.extractPath(from, to), Offset.zero);
        d += len;
        i++;
      }
    }
    return out;
  }

  /// `path` in `pattern` for a line `w` wide; marching ants are shifted toward the end by the current march.
  static Path patterned(Path path, LinePattern pattern, double w) {
    final dashes = pattern.dashes(w);
    if (dashes == null || !pattern.marches) return dashed(path, dashes);
    final cycle = dashes.fold(0.0, (a, b) => a + b);
    return dashed(path, dashes, phase: cycle * (1 - _marchNow % 1));
  }

  /// Runs `render` for the shadow (once, for the whole annotation), the contrast outline (widened by
  /// `outlineWidth`) and the real color, like the Swift app's transparency-layer approach. `bounds` (what
  /// `render` covers) keeps the shadow's blur layer to that area instead of the whole canvas, which is slow.
  /// `shine` draws the Border effect's highlight (a narrow line down the middle of the body, not the heads).
  static void _styled(Canvas canvas, ArrowStyle style, Color color, double outlineWidth,
      void Function(Color paint, double extra) render, {Rect? bounds, void Function(Color paint)? shine}) {
    // Border: a thin, nearly black edge in the line's own hue plus a shine down the middle (route-map tubes);
    // the contrast outline, when on too, goes outside it
    final edge = style.border ? math.max(1.5, outlineWidth * 0.7) : 0.0;   // bold enough to read at any size
    void paintLayers({bool shadowPass = false}) {
      // The chosen outline colour is the Border's edge when Border is on, otherwise the Outline's
      if (style.outline) render(style.border ? contrast(color) : style.borderColor ?? contrast(color), outlineWidth + edge);
      if (style.border) render(style.borderColor ?? darker(color), edge);
      render(color, 0);
      if (style.border && !shadowPass) shine?.call(CanvasPainter.shine(color));
    }
    if (style.shadow) {
      canvas.saveLayer(bounds?.inflate(outlineWidth * 2 + 8), Paint()
        ..colorFilter = ColorFilter.mode(Colors.black.withValues(alpha: 0.4), BlendMode.srcIn)
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 1.6, sigmaY: 1.6));
      canvas.translate(1.5, 1.5);
      paintLayers(shadowPass: true);
      canvas.restore();
    }
    paintLayers();
  }

  static Paint _stroke(Color c, double width) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  static Paint _fill(Color c) => Paint()..color = c..style = PaintingStyle.fill;

  /// Boxes, ellipses and pen strokes: pattern, outline and shadow.
  static void strokeStyled(Canvas canvas, Path path, ArrowStyle style, Color color, double w) {
    final p = patterned(path, style.pattern, w);
    _styled(canvas, style, color, math.max(1.5, w * 0.35), (paint, extra) {
      canvas.drawPath(p, _stroke(paint, w + extra * 2));
    }, bounds: path.getBounds().inflate(w), shine: (paint) => canvas.drawPath(p, _stroke(paint, w * 0.3)));
  }

  /// How wide a tapered body gets where it meets each kind of head (`hw`: the head's line width).
  static double _taperFull(ArrowHead kind, double hw, double k, double w) {
    final headWidth = math.max(14.0, hw * 5) * k * 1.1; // full width of the triangle-type heads
    return switch (kind) {
      ArrowHead.triangle => headWidth * 0.42,
      ArrowHead.swept => headWidth * 0.36, // stays inside the swept-back notch
      ArrowHead.triangleOutline => headWidth * 0.3,
      ArrowHead.open => math.max(w * 1.5, headWidth * 0.22),
      ArrowHead.dot => math.max(4.0, hw * 1.4) * k * 1.5, // 3/4 of the dot
      ArrowHead.circle => math.max(5.0, hw * 1.8) * k * 1.1,
      ArrowHead.square => math.max(4.0, hw * 1.4) * k * 1.6,
      ArrowHead.diamond => math.max(8.0, hw * 2.8) * k * 0.9,
      ArrowHead.bar => w * 1.6,
      ArrowHead.none => w * 2.6,
    };
  }

  /// How the heads sit on an arrow shorter than four head lengths (`headLength`, the full-size triangle/swept length), as
  /// a tiny freehand arrow is. The line thins smoothly (`thin`, down to half) and the head shrinks (`size`, a factor on the
  /// head size, same proportions): to a quarter of the path, a third of the larger side of the stroke's box and the normal
  /// length, whichever is least, but not under 2.2 thinned line widths, so it still reads as a head; then smaller still
  /// while it would lie over the tail (the line farther back than 1.5 head lengths), as on a tight curl. It points more and
  /// more along the stroke's chord over its last head length rather than the curve's own end direction, which on a tight
  /// curl twists it against the line (`blend` 0…1). Between three and four head lengths all of this eases back to normal;
  /// a normal arrow gets size 1, thin 1, blend 0 and its own directions, so it draws exactly as before.
  static _Short _shortArrow(List<Offset> pts, List<Offset?> tangents, Offset towardStart, Offset towardEnd, double headLength,
      double w, {ArrowHead start = ArrowHead.none, ArrowHead end = ArrowHead.none, double k = 1, double? headW}) {
    final curve = _curvePath(pts, tangents);
    final it = curve.computeMetrics().iterator;
    final total = it.moveNext() ? it.current.length : 0.0;
    final blend = total <= 0 ? 0.0 : ((4 * headLength - total) / headLength).clamp(0.0, 1.0);
    if (blend == 0) {
      return (size: 1, blend: 0, thin: 1, reach: headLength, towardStart: towardStart, towardEnd: towardEnd, curve: null);
    }
    final m = it.current, thin = 1 - 0.5 * blend, lw = w * thin;
    final box = curve.getBounds(), side = math.max(box.width, box.height);
    final target = math.min(math.max(math.min(headLength, math.min(0.25 * total, 0.33 * side)), 2.2 * lw), total / 2);
    var size = 1 - blend * (1 - math.min(1.0, target / headLength));
    Offset toward(Offset tip, Offset own, double at) {
      final chord = _unit(m.getTangentForOffset(at.clamp(0.0, total))!.position, tip), tangent = _unit(own, tip);
      final d = tangent * (1 - blend) + chord * blend;
      return tip - (d.distance < 1e-6 ? chord : d / d.distance) * 10;
    }
    var ts = towardStart, te = towardEnd;
    for (var tries = 0; tries < 16; tries++) {
      final reach = headLength * size;
      ts = toward(pts.first, towardStart, reach);
      te = toward(pts.last, towardEnd, total - reach);
      if (!_overTail(m, lw, reach, _head(start, pts.first, ts, headW ?? w, k * size * tailScale(start, end)), true) &&
          !_overTail(m, lw, reach, _head(end, pts.last, te, headW ?? w, k * size), false)) {
        break;
      }
      size *= 0.85;
    }
    return (size: size, blend: blend, thin: thin, reach: headLength * size, towardStart: ts, towardEnd: te, curve: m);
  }

  /// Whether a head (at the start or the end of the curve `m`) covers the line farther than 1.5 head lengths (`reach`) back
  /// along it: the line's centre or either edge (`lw` wide) inside the head's outline.
  static bool _overTail(ui.PathMetric m, double lw, double reach, _Head h, bool atStart) {
    final path = h.path;
    if (path == null) return false;
    final from = atStart ? 1.5 * reach : 0.0, to = atStart ? m.length : m.length - 1.5 * reach;
    for (var d = from; d <= to; d += 1) {
      final t = m.getTangentForOffset(d)!, n = Offset(-t.vector.dy, t.vector.dx) * (lw / 2);
      if (path.contains(t.position) || path.contains(t.position + n) || path.contains(t.position - n)) return true;
    }
    return false;
  }

  /// How far behind its tip a head takes the line in: the middle of its back (a swept head's notch), or, for a see-through
  /// head, half a line short of its back so the line's round end just reaches it.
  static double _entry(_Head h, double w) =>
      h.path == null ? 0 : h.filled && h.hollow ? h.back * 7 / 11 : h.back + (h.hollow ? w / 2 : 0);

  /// The body of a short arrow as one smooth stroke into each head: the drawn curve, whose last stretch before a head (its
  /// entry plus 0.4 of the shrunk head length, about one head length) is replaced by a cubic that leaves the curve in the curve's own direction and arrives at the middle of the head's back
  /// (`e0` / `e1` behind the tips `a` / `b`) travelling along the head's axis. No corner, no straight stub, no step.
  static Path _shortBody(_Short short, _Head start, _Head end, double e0, double e1, Offset a, Offset b) {
    final m = short.curve!, total = m.length;
    final out0 = _unit(short.towardStart, a), out1 = _unit(short.towardEnd, b); // the way each head points
    final q0 = start.path == null ? a : a - out0 * e0, q1 = end.path == null ? b : b - out1 * e1;
    final b0 = start.path == null ? 0.0 : e0 + 0.4 * short.reach, b1 = end.path == null ? 0.0 : e1 + 0.4 * short.reach;
    // Handles from a third of the gap (going straight on) to two thirds (a U-turn), as for a circular arc, so a stroke
    // that turns back into its head rounds the turn instead of folding it into a corner
    double handle(Offset from, Offset to, Offset v0, Offset v1) {
      final turn = math.acos((v0.dx * v1.dx + v0.dy * v1.dy).clamp(-1.0, 1.0));
      return (to - from).distance * (1 + turn / math.pi) / 3;
    }
    final path = Path()..moveTo(q0.dx, q0.dy);
    if (b0 + b1 >= total - 1) {
      // No stretch of the drawn curve left between the two blends: one cubic from end to end
      final v0 = start.path == null ? m.getTangentForOffset(0)!.vector : -out0;
      final v1 = end.path == null ? m.getTangentForOffset(total)!.vector : out1;
      final h = handle(q0, q1, v0, v1), c1 = q0 + v0 * h, c2 = q1 - v1 * h;
      return path..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, q1.dx, q1.dy);
    }
    if (start.path != null) {
      final t = m.getTangentForOffset(b0)!, p = t.position, h = handle(q0, p, -out0, t.vector);
      final c1 = q0 - out0 * h, c2 = p - t.vector * h;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy);
    }
    path.extendWithPath(m.extractPath(b0, total - b1), Offset.zero);
    if (end.path != null) {
      final t = m.getTangentForOffset(total - b1)!, p = t.position, h = handle(p, q1, t.vector, out1);
      final c1 = p + t.vector * h, c2 = q1 - out1 * h;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, q1.dx, q1.dy);
    }
    return path;
  }

  /// A plain body (solid or still dashes, not tapered): the drawn curve cut by length at the trims (re-fitting the spline to
  /// the trimmed ends with the curve's own end tangents made a short or sharply bent arrow wobble or hook behind its head),
  /// or on a short arrow the smooth stroke of [_shortBody]. Null: too short, keep the spline through the trims.
  static Path? _plainBody(List<Offset> pts, List<Offset?> tangents, _Short short, _Head start, _Head end, double w) {
    final a = pts.first, b = pts.last;
    if (short.blend > 0) return _shortBody(short, start, end, _entry(start, w), _entry(end, w), a, b);
    final full = _curvePath(pts, tangents).computeMetrics().iterator;
    if (!full.moveNext()) return null;
    final whole = full.current, s0 = (a - start.trim).distance, s1 = (b - end.trim).distance;
    return s0 + s1 < whole.length - 1 ? whole.extractPath(s0, whole.length - s1) : null;
  }

  /// For tests: a plain arrow's line (as drawn) and drawn curve, its end head (outline, tip, pointing direction, length and
  /// how far behind the tip it takes the line in: the middle of its back), where the line leaves the drawn curve (distance
  /// from the tip along it; 0 on a normal arrow) and the line's width, computed exactly as [drawArrow] does.
  @visibleForTesting
  static ({Path line, Path curve, Path? head, Offset tip, Offset axis, double entry, double headLength, double blendFrom,
      double lineWidth}) endJoin(List<Offset> pts, ArrowStyle style, double w, {List<Offset?> tangents = const []}) {
    final a = pts.first, b = pts.last;
    final segs = spline(pts, tangents);
    final (_, firstC1, _, _) = segs.first;
    final (lastA, _, lastC2, _) = segs.last;
    final full = math.max(14.0, w * 5) * style.headSize.scale;
    final short = _shortArrow(pts, tangents, (firstC1 - a).distance > 0.5 ? firstC1 : segs.first.$4,
        (lastC2 - b).distance > 0.5 ? lastC2 : lastA, full, w, start: style.start, end: style.end, k: style.headSize.scale);
    final k = style.headSize.scale * short.size;
    final start = _head(style.start, a, short.towardStart, w, k * tailScale(style.start, style.end)), end = _head(style.end, b, short.towardEnd, w, k);
    final lw = w * short.thin, entry = _entry(end, lw);
    final line = _plainBody(pts, tangents, short, start, end, lw) ?? _curvePath([start.trim, ...pts.sublist(1, pts.length - 1), end.trim], tangents);
    return (line: line, curve: _curvePath(pts, tangents), head: end.path, tip: b, axis: _unit(short.towardEnd, b), entry: entry,
        headLength: full * short.size, blendFrom: short.blend > 0 && end.path != null ? entry + 0.4 * short.reach : 0, lineWidth: lw);
  }

  /// An arrow or line along a smooth curve through `pts` (start, bend points, end); each head points
  /// along the curve at its end.
  static void drawArrow(Canvas canvas, List<Offset> pts, ArrowStyle style, Color color, double w,
      {List<Offset?> tangents = const []}) {
    final a = pts.first, b = pts.last;
    if (pts.length < 2 || ((b - a).distance <= 1 && pts.length == 2)) return;
    final segs = spline(pts, tangents);
    final (_, firstC1, _, _) = segs.first;
    final (lastA, _, lastC2, _) = segs.last;
    // Tapered: a slightly larger head, and a body that widens only as far as suits that head, so it
    // never swamps small heads (dot, bar, open chevron) or fills a swept head's notch
    final headW = style.tapered ? w * 1.45 : w;
    final short = _shortArrow(pts, tangents, (firstC1 - a).distance > 0.5 ? firstC1 : segs.first.$4,
        (lastC2 - b).distance > 0.5 ? lastC2 : lastA, math.max(14.0, headW * 5) * style.headSize.scale, w,
        start: style.start, end: style.end, k: style.headSize.scale, headW: headW);
    final towardEnd = short.towardEnd, towardStart = short.towardStart;
    final k = style.headSize.scale * short.size;
    final taperFull = style.tapered ? _taperFull(style.end, headW, k, w) : w; // body width where it meets the head
    final endWidth = taperFull / 1.8; // _taperedBody's width parameter (its widest end is 1.8 × this)
    var end = _head(style.end, b, towardEnd, headW, k);
    if (style.tapered && style.end == ArrowHead.open) {
      // The chevron's strokes match the body, which stops just behind its point
      final u = _unit(towardEnd, b);
      end = _Head(end.path, filled: false, lineWidth: math.max(headW, taperFull * 0.85), trim: b - u * (taperFull * 0.5),
          back: end.back, hollow: true);
    }
    final start = _head(style.start, a, towardStart, w, k * tailScale(style.start, style.end));
    w *= short.thin; // a short arrow's line is thinner (its heads keep their size from the full width)

    // The body runs between the trimmed ends (hidden under the heads), through the same bend points. A marching
    // body stops at the back of each head instead, so its moving dashes never show inside a head (a swept head's
    // notch, an outlined triangle or circle, an open chevron) and a dash never changes a head's outline. A dash's
    // round end would still reach into a see-through head or a notch, so there it stops half a line earlier (a tapered body
    // has a flat end). An arrow too short for that keeps the plain trims.
    var from = start.trim, to = end.trim;
    if (style.pattern.marches) {
      final cap = style.tapered ? 0.0 : w / 2;
      double room(_Head h) => h.path == null ? 0 : h.back + (h.hollow ? cap : 0);
      if (room(start) + room(end) < (b - a).distance - w) {
        from = a + _unit(a, towardStart) * room(start);
        to = b + _unit(b, towardEnd) * room(end);
      }
    }
    final body = [from, ...pts.sublist(1, pts.length - 1), to];
    var centerline = _curvePath(body, tangents);
    if (!style.pattern.marches && !style.tapered) centerline = _plainBody(pts, tangents, short, start, end, w) ?? centerline;
    final wedge = style.tapered ? _taperedBody(body, tangents, endWidth) : null;

    _styled(canvas, style, color, math.max(1.5, w * 0.35), (paint, extra) {
      if (wedge != null) {
        if (style.pattern == LinePattern.solid) {
          canvas.drawPath(wedge, _fill(paint));
          if (extra > 0) canvas.drawPath(wedge, _stroke(paint, extra * 2));
        } else {
          // A dashed tapered arrow: clip to the wedge and stroke a dashed centerline wide enough to fill it
          canvas.save();
          canvas.clipPath(extra > 0 ? _taperedBody(body, tangents, endWidth + extra * 2) : wedge);
          canvas.drawPath(patterned(centerline, style.pattern, taperFull), _stroke(paint, taperFull * 1.04 + extra * 2));
          canvas.restore();
        }
      } else {
        canvas.drawPath(patterned(centerline, style.pattern, w), _stroke(paint, w + extra * 2));
      }
      for (final part in [start, end]) {
        final path = part.path;
        if (path == null) continue;
        if (part.filled) {
          canvas.drawPath(path, _fill(paint));
          if (extra > 0) canvas.drawPath(path, _stroke(paint, extra * 2));
        } else {
          canvas.drawPath(path, _stroke(paint, part.lineWidth + extra * 2));
        }
      }
    }, shine: wedge != null ? null : (paint) => canvas.drawPath(patterned(centerline, style.pattern, w), _stroke(paint, w * 0.3)),
        bounds: [
      wedge?.getBounds() ?? centerline.getBounds(),
      for (final part in [start, end]) ?part.path?.getBounds(),
    ].reduce((a, b) => a.expandToInclude(b)).inflate(math.max(w, taperFull)));
  }

  // ---- Snake skin ----

  /// The Snake skin effect (an arrow as a dark glass tube with glowing scales inside): a see-through black
  /// band with a faint rim in the line's colour and a row of glowing pellets drifting toward the head. `phase`
  /// (0…1) moves the pellets; null uses the current march (the editor's ticker / the GIF loop).
  static void drawSnake(Canvas canvas, List<Offset> pts, ArrowStyle style, Color color, double w,
      {List<Offset?> tangents = const [], double? phase}) {
    final a = pts.first, b = pts.last;
    if (pts.length < 2 || ((b - a).distance <= 1 && pts.length == 2)) return;
    final segs = spline(pts, tangents);
    final (_, firstC1, _, _) = segs.first;
    final (lastA, _, lastC2, _) = segs.last;
    final towardEnd = (lastC2 - b).distance > 0.5 ? lastC2 : lastA;
    final towardStart = (firstC1 - a).distance > 0.5 ? firstC1 : segs.first.$4;
    final k = style.headSize.scale;
    final end = _head(style.end, b, towardEnd, w * 1.2, k);
    final start = _head(style.start, a, towardStart, w * 1.2, k * tailScale(style.start, style.end));
    final body = [start.trim, ...pts.sublist(1, pts.length - 1), end.trim];
    final centerline = _curvePath(body, tangents);
    final ph = (phase ?? _marchNow) % 1;
    final light = Color.lerp(color, Colors.white, 0.55)!;

    Paint glow(Color c, double width, double blur) => _stroke(c, width)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur)
      ..blendMode = BlendMode.plus;

    // The tube: a dark, see-through band with a faint rim in the colour, so it reads as glass over the picture
    canvas.drawPath(centerline, _stroke(color.withValues(alpha: 0.35), w * 2.8)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.25));
    canvas.drawPath(centerline, _stroke(Colors.black.withValues(alpha: 0.72), w * 2.3)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.15));
    // The scales: glowing pellets inside the tube, drifting toward the end (one scale per march cycle)
    final seg = [w * 0.9, w * 1.4];
    canvas.drawPath(dashed(centerline, seg, phase: (seg[0] + seg[1]) * (1 - ph)), glow(color.withValues(alpha: 0.55), w * 0.9, w * 0.3));

    // Heads: a flare in the colour behind, the head itself in a light tint
    for (final part in [start, end]) {
      final path = part.path;
      if (path == null) continue;
      final halo = Paint()
        ..color = color.withValues(alpha: 0.8)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 1.2)
        ..blendMode = BlendMode.plus;
      if (part.filled) {
        canvas.drawPath(path, halo..style = PaintingStyle.fill);
        canvas.drawPath(path, _fill(light));
      } else {
        canvas.drawPath(path, halo..style = PaintingStyle.stroke..strokeWidth = part.lineWidth * 1.5);
        canvas.drawPath(path, _stroke(light, part.lineWidth));
      }
    }
  }

  // ---- Arrow effects ----

  /// One of the animated arrow effects ([ArrowEffect]) along the curve through `pts`, with the arrow's own heads (both
  /// ends, any kind and size), colour and width; Colour flow and Fire trail keep their own colours. `phase` (0…1, one
  /// loop; 1.2 draws as 0.2) moves it; null uses the current march (the editor's ticker / the GIF loop), as for the snake.
  /// The body stops at the back of each head, as a marching body does, so nothing moves inside a head. Shadow, outline,
  /// border and tapered are not used. The line pattern is (1.88): the effect runs along the dashes or dots and leaves the
  /// gaps empty, and a Marching pattern moves them toward the head as on a plain arrow; the heads stay whole. Every
  /// effect draws its own dashes with round ends (a dot is a round dot), so a glow or shadow fades into a gap; only
  /// Pulse's comet, which runs across the dashes, is clipped out of the gaps. No layers: each blur is a mask filter on its
  /// own small shape.
  static void drawEffect(Canvas canvas, List<Offset> pts, ArrowStyle style, Color color, double w,
      {List<Offset?> tangents = const [], double? phase}) {
    if (style.effect == ArrowEffect.none) return drawArrow(canvas, pts, style, color, w, tangents: tangents);
    final a = pts.first, b = pts.last;
    if (pts.length < 2 || ((b - a).distance <= 1 && pts.length == 2)) return;
    final segs = spline(pts, tangents);
    final (_, firstC1, _, _) = segs.first;
    final (lastA, _, lastC2, _) = segs.last;
    final short = _shortArrow(pts, tangents, (firstC1 - a).distance > 0.5 ? firstC1 : segs.first.$4,
        (lastC2 - b).distance > 0.5 ? lastC2 : lastA, math.max(14.0, w * 5) * style.headSize.scale, w,
        start: style.start, end: style.end, k: style.headSize.scale);
    final towardEnd = short.towardEnd, towardStart = short.towardStart;
    final k = style.headSize.scale * short.size;
    final start = _head(style.start, a, towardStart, w, k * tailScale(style.start, style.end)), end = _head(style.end, b, towardEnd, w, k);
    w *= short.thin; // a short arrow's line (and the effect along it) is thinner; its heads keep their size
    // The line is the arrow's own curve, cut by length: under a filled head (a swept head's notch included) it stops where
    // the plain arrow's body does, so it meets the head with no gap; a see-through head (outlined triangle, circle, open
    // chevron) keeps the line out of it, half a line short of its back. Cutting the drawn curve, rather than re-fitting the
    // spline to moved end points, keeps its shape and the direction it arrives in on a short or sharply bent arrow.
    final full = _curvePath(pts, tangents).computeMetrics().iterator; // one pass only: PathMetrics cannot be walked twice
    if (!full.moveNext() || full.current.length < 1) return;
    final whole = full.current;
    double cut(_Head h, Offset tip) => h.path == null ? 0 : h.filled ? (tip - h.trim).distance : h.back + (h.hollow ? w / 2 : 0);
    var s0 = cut(start, a), s1 = cut(end, b);
    if (s0 + s1 > whole.length - 1) s0 = s1 = 0; // too short for both heads: the whole curve, under them
    final line = short.blend > 0
        ? _shortBody(short, start, end, _entry(start, w), _entry(end, w), a, b)
        : whole.extractPath(s0, whole.length - s1);
    final metrics = line.computeMetrics().iterator;
    if (!metrics.moveNext() || metrics.current.length < 1) return;
    final metric = metrics.current;
    // Rounded to a millionth, so a phase and the same phase one loop later give the very same frame
    // (whole millionths of a loop, one breath of Neon = [neonLoops] loops)
    final micro = (((phase ?? _marchNow) % neonLoops) * 1e6).round() % (neonLoops * 1000000);
    final t = micro % 1000000 / 1e6;
    // The line pattern: the pieces of the line that show (none = solid, the whole line)
    final dashes = style.pattern.dashes(w);
    var body = line;
    var pieces = const <(double, double)>[];
    if (dashes != null) {
      final shift = style.pattern.marches ? dashes.fold(0.0, (a, b) => a + b) * (1 - t) : 0.0;
      body = dashed(line, dashes, phase: shift);
      pieces = _pieces(metric.length, dashes, shift);
    }
    final fx = _Fx(line, metric, start, end, b, _unit(towardEnd, b), body: body, pieces: pieces, width: w);
    switch (style.effect) {
      case ArrowEffect.none:
        break;
      case ArrowEffect.neon:
        _neon(canvas, fx, color, w, micro / (neonLoops * 1e6));
      case ArrowEffect.flow:
        _flow(canvas, fx, w, t);
      case ArrowEffect.electric:
        _electric(canvas, fx, color, w, t);
      case ArrowEffect.fire:
        _fire(canvas, fx, w, t);
      case ArrowEffect.pulse:
        _pulse(canvas, fx, color, w, t);
      case ArrowEffect.rope:
        _rope(canvas, fx, color, w, t);
    }
  }

  /// The stretches (from, to) of a line `length` long that a dash pattern shows: the same cut as [dashed].
  static List<(double, double)> _pieces(double length, List<double> dashes, double phase) {
    final out = <(double, double)>[];
    var d = -phase, i = 0;
    while (d < length) {
      final len = dashes[i % dashes.length];
      final from = math.max(d, 0.0), to = math.min(d + math.max(len, 0.01), length);
      if (i.isEven && to > from) out.add((from, to));
      d += len;
      i++;
    }
    return out;
  }

  /// `draw` with the gaps of the line's pattern clipped out (a clip, not a layer): each gap is a band across the line,
  /// wide enough for the comet's glow; a piece shows half a line width past each end, as its round cap does. Beyond the
  /// line's ends (the heads, sparks, the pop) nothing is cut.
  static void _outOfGaps(Canvas canvas, _Fx a, VoidCallback draw) {
    if (a.pieces.isEmpty) return draw();
    final w = a.width, reach = w * 4, step = math.max(2.0, w / 2);
    final gaps = Path();
    void gap(double g0, double g1) {
      if (g1 - g0 < 0.5) return;
      final left = <Offset>[], right = <Offset>[];
      for (var d = g0; ; d = math.min(d + step, g1)) {
        left.add(a.at(d) + a.normal(d) * reach);
        right.add(a.at(d) - a.normal(d) * reach);
        if (d >= g1) break;
      }
      gaps.addPolygon([...left, ...right.reversed], true);
    }
    var from = 0.0;
    for (final (p0, p1) in a.pieces) {
      gap(from, p0 - w / 2);
      from = p1 + w / 2;
    }
    gap(from, a.len);
    final all = Path()..addRect(a.line.getBounds().inflate(math.max(400.0, w * 24)));
    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.difference, all, gaps));
    draw();
    canvas.restore();
  }

  static Paint _blurred(Paint p, double sigma) => p..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);

  /// A head as its kind draws it: filled, or stroked at its own width plus `grow`; blurred for a glow.
  static void _effectHead(Canvas canvas, _Head h, Color c, {double grow = 0, double blur = 0}) {
    final path = h.path;
    if (path == null) return;
    final p = h.filled ? _fill(c) : _stroke(c, h.lineWidth + grow);
    canvas.drawPath(path, blur > 0 ? _blurred(p, blur) : p);
  }

  /// A thin line along a head: round a filled head's edge, down the middle of a stroked one.
  static void _headLine(Canvas canvas, _Head h, Color c, double width) {
    final path = h.path;
    if (path == null) return;
    canvas.drawPath(path, _stroke(c, h.filled ? width : math.min(width, h.lineWidth * 0.4)));
  }

  /// Neon: a glowing tube whose (soft, a quarter dimmer since 1.87.4) glow breathes, with a white-hot core. [t] (0…1) is one breath, [neonLoops] march loops long.
  static void _neon(Canvas canvas, _Fx a, Color col, double w, double t) {
    final breathe = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
    final glow = col.withValues(alpha: 0.26 + 0.3 * breathe), blur = w * (1.2 + 0.6 * breathe);
    canvas.drawPath(a.body, _blurred(_stroke(glow, w * (2.6 + breathe)), blur));
    for (final h in a.heads) {
      _effectHead(canvas, h, glow, grow: w * (1.6 + breathe), blur: blur);
    }
    canvas.drawPath(a.body, _stroke(col, w));
    final core = Color.lerp(col, Colors.white, 0.8)!;
    canvas.drawPath(a.body, _stroke(core, w * 0.36));
    for (final h in a.heads) {
      _effectHead(canvas, h, col);
      _headLine(canvas, h, core, w * 0.3);
    }
  }

  static const _rainbow = [Color(0xFFFF2D95), Color(0xFFFF8A00), Color(0xFFFFE600), Color(0xFF00D4FF), Color(0xFF7A5CFF), Color(0xFFFF2D95)];

  /// Colour flow: a rainbow travelling toward the head (its own colours, not the line's).
  static void _flow(Canvas canvas, _Fx a, double w, double t) {
    Color at(double d) {
      final x = ((d / 260 - t) % 1 + 1) % 1 * (_rainbow.length - 1);
      final i = x.floor().clamp(0, _rainbow.length - 2);
      return Color.lerp(_rainbow[i], _rainbow[i + 1], x - i)!;
    }
    canvas.drawPath(a.body, _blurred(_stroke(Colors.black.withValues(alpha: 0.25), w + 2), 2));
    // Short square-cut pieces, each in its colour; longer pieces on a wide or long line keep the count down.
    // Per dash of the line's pattern (a solid line is one dash), each with round ends: a dot is just its two ends.
    final step = math.max(math.max(2.0, w / 3), a.len / 300);
    for (final (p0, p1) in a.pieces.isEmpty ? [(0.0, a.len)] : a.pieces) {
      canvas.drawCircle(a.at(p0), w / 2, _fill(at(p0))); // round ends: the pieces are cut square
      canvas.drawCircle(a.at(p1), w / 2, _fill(at(p1)));
      for (var d = p0; d < p1; d += step) {
        canvas.drawPath(a.part(d, math.min(d + step + 0.8, p1)), _stroke(at(d), w)..strokeCap = StrokeCap.butt);
      }
    }
    _effectHead(canvas, a.start, at(0));
    _effectHead(canvas, a.end, at(a.len));
  }

  /// A fixed pseudo-random number in -1…1 for (`seed`, `i`).
  static double _noise(int seed, int i) => math.Random(seed * 7919 + i * 104729).nextDouble() * 2 - 1;

  /// Electric: a crackling bolt around a steady core, sparks off the point. The bolt changes ten times a loop and is
  /// the same for the same phase (seeded from the phase step).
  static void _electric(Canvas canvas, _Fx a, Color col, double w, double t) {
    // (a tighter glow on a patterned line, or its round ends would fill the gaps)
    final solid = a.pieces.isEmpty;
    canvas.drawPath(a.body, _blurred(_stroke(col.withValues(alpha: 0.5), w * (solid ? 2.4 : 1.5)), w * (solid ? 1 : 0.55)));
    canvas.drawPath(a.body, _stroke(col, w * 0.7));
    final light = Color.lerp(col, Colors.white, 0.55)!;
    for (final h in a.heads) {
      _effectHead(canvas, h, col.withValues(alpha: 0.6), grow: w * 1.4, blur: w);
      _effectHead(canvas, h, light);
    }
    final seed = (t * 10 + 1e-6).floor();
    // One pair of bolts per dash of the line's pattern (a solid line is one dash; a dot has none), pinned at its ends
    var dash = 0;
    for (final (p0, p1) in solid ? [(0.0, a.len)] : a.pieces) {
      final len = p1 - p0;
      dash++;
      if (len < 4) continue;
      final swing = math.min(w * 2.2, len * 0.15); // the bolt's reach; less on a tiny arrow or dash, so it stays a line
      final count = math.max(2, (len / math.max(math.max(12.0, w * 1.8), len / 120)).round()), step = len / count;
      for (var bolt = 0; bolt < 2; bolt++) {
        final p = Path();
        for (var i = 0; i <= count; i++) {
          final d = p0 + i * step, ends = math.sin(math.pi * i / count); // pinned at both ends
          final pt = a.at(d) + a.normal(d) * (_noise(seed + bolt * 31 + (dash - 1) * 17, i) * swing * ends);
          i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
        }
        canvas.drawPath(p, _blurred(_stroke(col.withValues(alpha: 0.7), w * 0.9), w * 0.5));
        canvas.drawPath(p, _stroke(Colors.white, w * (bolt == 0 ? 0.32 : 0.2)));
      }
    }
    // Sparks off the front of the end head (a dot, circle, square or diamond is centred on the line's end, so further on)
    var reach = 0.0;
    if (a.end.path case final head?) {
      for (final m in head.computeMetrics()) {
        for (var i = 0; i < 24; i++) {
          final p = m.getTangentForOffset(m.length * i / 24)!.position - a.tip;
          reach = math.max(reach, p.dx * a.dir.dx + p.dy * a.dir.dy);
        }
      }
      if (!a.end.filled) reach += a.end.lineWidth / 2;
    }
    final point = a.tip + a.dir * reach, r = math.Random(seed);
    for (var i = 0; i < 4; i++) {
      final ang = math.atan2(a.dir.dy, a.dir.dx) + (r.nextDouble() - 0.5) * 2.2;
      final v = Offset(math.cos(ang), math.sin(ang));
      final from = point + v * (w * 0.8), to = from + v * math.min(w * (1 + r.nextDouble() * 2.5), a.len * 0.3);
      canvas.drawLine(from, to, _stroke(Colors.white, w * 0.22));
      canvas.drawLine(from, to, _blurred(_stroke(col.withValues(alpha: 0.6), w * 0.6), 2));
    }
  }

  /// Fire trail: the head burns and a flame with embers trails back along the line (its own fire colours).
  static void _fire(Canvas canvas, _Fx a, double w, double t) {
    const dark = Color(0xFFB3140A), mid = Color(0xFFFF6A00), hot = Color(0xFFFFD21F), white = Color(0xFFFFF6C8);
    Color heat(double f) => f < 0.5 ? Color.lerp(dark, mid, f * 2)! : Color.lerp(mid, hot, (f - 0.5) * 2)!;
    final s = math.max(1.0, w / 9); // the flicker and the embers were sized for a 9-point line
    final step = math.max(math.max(2.5, w * 0.55), a.len / 250); // blobs overlap at any width, never too many
    for (var d = 0.0; d < a.len; d += step) {
      if (!a.shows(d)) continue; // a gap of the line's pattern
      final f = d / a.len; // 0 tail … 1 head
      final wob = math.sin(d / (17 * s) - t * 2 * math.pi * 2) * 0.6 + math.sin(d / (7.3 * s) + t * 2 * math.pi * 3) * 0.4;
      final r = w * (0.22 + 0.75 * f) * (1 + 0.18 * wob);
      final p = a.at(d) + a.normal(d) * (wob * w * 0.35 * f);
      canvas.drawCircle(p, r * 1.5, _blurred(_fill(heat(f).withValues(alpha: 0.10 + 0.25 * f)), r * 0.9));
      canvas.drawCircle(p, r, _fill(heat(f).withValues(alpha: 0.55 + 0.45 * f)));
    }
    for (var d = a.len * 0.35; d < a.len; d += step) { // the hot core near the head
      if (!a.shows(d)) continue;
      final f = (d / a.len - 0.35) / 0.65;
      canvas.drawCircle(a.at(d), w * 0.3 * f, _fill(white.withValues(alpha: 0.85 * f)));
    }
    for (var i = 0; i < 14; i++) { // embers drifting back and up
      final life = (t + i / 14) % 1;
      final d = a.len * (1 - life * 0.75) - (i % 3) * 14 * s;
      final side = (i.isEven ? 1 : -1) * (0.6 + (i % 5) * 0.35);
      final p = a.at(d) + a.normal(d) * (side * w * (0.8 + life * 1.6)) + Offset(0, -life * w * 1.2);
      canvas.drawCircle(p, w * 0.16 * (1 - life) + 0.6, _fill(Color.lerp(hot, dark, life)!.withValues(alpha: 1 - life)));
    }
    _effectHead(canvas, a.start, heat(0.15)); // the tail end smoulders
    _effectHead(canvas, a.end, mid.withValues(alpha: 0.7), grow: w, blur: w * 1.1);
    _effectHead(canvas, a.end, hot);
    _headLine(canvas, a.end, white, w * 0.25);
  }

  /// Pulse: a bright comet runs tail to head and pops at the point. Shifted so phase 0 (a still picture) shows the
  /// comet part-way along.
  static void _pulse(Canvas canvas, _Fx a, Color col, double w, double phase) {
    final t = (phase + 0.45) % 1, s = math.max(1.0, w / 9);
    canvas.drawPath(a.body, _blurred(_stroke(Colors.black.withValues(alpha: 0.25), w + 2), 2));
    canvas.drawPath(a.body, _stroke(col, w));
    final run = (t / 0.7).clamp(0.0, 1.0), pop = ((t - 0.62) / 0.38).clamp(0.0, 1.0);
    final glowHead = pop > 0 ? (1 - pop) : 0.0;
    if (t < 0.7) {
      _outOfGaps(canvas, a, () { // the comet lights the dashes it passes, not the gaps
        final at = Curves.easeIn.transform(run) * (a.len + 30 * s), band = 70.0 * s;
        final bright = Color.lerp(col, Colors.white, 0.75)!;
        for (var i = 0; i < 8; i++) { // a comet: bright front, fading tail
          final f = i / 8;
          canvas.drawPath(a.part(at - band * (1 - f), at), _stroke(bright.withValues(alpha: 0.16 + 0.1 * f), w * (1.0 + 0.5 * f)));
        }
        canvas.drawPath(a.part(at - 14 * s, at), _blurred(_stroke(col.withValues(alpha: 0.8), w * 2.6), w * 0.9));
        canvas.drawPath(a.part(at - 10 * s, at), _stroke(Colors.white, w * 0.9));
      });
    }
    _effectHead(canvas, a.start, col);
    _effectHead(canvas, a.end, Color.lerp(col, Colors.white, 0.7 * glowHead)!);
    if (pop > 0 && pop < 1) {
      final centre = a.end.path?.getBounds().center ?? a.tip, e = Curves.easeOut.transform(pop);
      _effectHead(canvas, a.end, col.withValues(alpha: 0.7 * (1 - pop)), grow: w, blur: w * 1.4);
      canvas.drawCircle(centre, w * (2 + 6.5 * e), _stroke(col.withValues(alpha: 0.9 * (1 - pop)), w * 0.55 * (1 - pop) + 0.8));
      canvas.drawCircle(centre, w * (1 + 4 * e), _stroke(Colors.white.withValues(alpha: 0.7 * (1 - pop)), w * 0.3 * (1 - pop) + 0.5));
    }
  }

  /// Rope: a twisted cord crawling toward the head, one strand per loop.
  static void _rope(Canvas canvas, _Fx a, Color col, double w, double t) {
    final hsl = HSLColor.fromColor(col);
    final dark = hsl.withLightness((hsl.lightness * 0.45).clamp(0.0, 1.0)).toColor();
    final light = hsl.withLightness((hsl.lightness + (1 - hsl.lightness) * 0.5).clamp(0.0, 1.0)).toColor();
    final rw = w * 1.35;
    canvas.drawPath(a.body, _blurred(_stroke(Colors.black.withValues(alpha: 0.3), rw + 3), 2.5));
    canvas.drawPath(a.body, _stroke(dark, rw + 2));
    canvas.drawPath(a.body, _stroke(col, rw));
    // The strands: slanted strokes clipped to the cord (a clip, not a layer); per dash of the line's pattern (a solid
    // line is one dash), so a gap has none and a dot is a plain round knot
    final cord = Path();
    final step = math.max(2.0, a.len / 400);
    for (final (p0, p1) in a.pieces.isEmpty ? [(0.0, a.len)] : a.pieces) {
      if (p1 - p0 < 1) continue;
      final left = <Offset>[], right = <Offset>[];
      for (var d = p0; d <= p1 + step / 2; d += step) {
        left.add(a.at(math.min(d, p1)) + a.normal(math.min(d, p1)) * (rw / 2));
        right.add(a.at(math.min(d, p1)) - a.normal(math.min(d, p1)) * (rw / 2));
      }
      cord.addPolygon([...left, ...right.reversed], true);
    }
    canvas.save();
    canvas.clipPath(cord);
    final pitch = rw * 1.25, q = pitch * 0.42;
    Offset edge(double d, double side) => a.at(d) + a.normal(d) * (side * rw * 0.7);
    for (var d = -pitch + t * pitch; d < a.len + pitch; d += pitch) {
      canvas.drawLine(edge(d - rw * 0.55, 1), edge(d + rw * 0.55, -1), _stroke(dark, rw * 0.3));
      canvas.drawLine(edge(d - rw * 0.55 + q, 1), edge(d + rw * 0.55 + q, -1), _stroke(light.withValues(alpha: 0.75), rw * 0.2));
    }
    canvas.restore();
    for (final h in a.heads) {
      _effectHead(canvas, h, dark, grow: 2);
      if (h.filled) _headLine(canvas, h, dark, 2);
      _effectHead(canvas, h, col);
    }
  }

  // ---- Other shapes ----

  static Path _smooth(List<Offset> points) {
    final path = Path();
    if (points.isEmpty) return path;
    path.moveTo(points.first.dx, points.first.dy);
    if (points.length < 3) {
      path.lineTo(points.last.dx, points.last.dy);
      return path;
    }
    for (var i = 1; i < points.length - 1; i++) {
      final p = points[i], next = points[i + 1];
      path.quadraticBezierTo(p.dx, p.dy, (p.dx + next.dx) / 2, (p.dy + next.dy) / 2);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  /// Line spacing for annotation text. The inline text field uses the same style (see textStyle), so typed
  /// text lines up exactly with what is drawn.
  static const lineHeight = 1.2;

  /// The text style of a Text or Callout annotation, from its TextFormat.
  static TextStyle textStyle(Annotation a, Color color, {bool halo = false}) {
    final f = a.textFormat;
    final light = HSVColor.fromColor(color).value > 0.6;
    return TextStyle(
      fontFamily: f.family.isEmpty ? null : f.family,
      fontSize: a.fontSize,
      height: lineHeight,
      fontWeight: f.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: f.italic ? FontStyle.italic : FontStyle.normal,
      decoration: f.underline ? TextDecoration.underline : TextDecoration.none,
      decorationColor: color,
      color: color,
      shadows: halo && f.shadow
          ? [Shadow(color: light ? Colors.black.withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.9), blurRadius: 3)]
          : null,
    );
  }

  static List<TextRun> runsOf(Annotation a) => switch (a.shape) {
        TextShape(:final runs) || CalloutShape(:final runs) => runs,
        _ => const <TextRun>[],
      };

  /// The text as spans: the base style, with each run's colour / bold / italic / underline on top.
  /// Also used by the inline text field, so typed text shows its formatting live.
  static TextSpan richSpan(String text, List<TextRun> runs, TextStyle base) {
    if (runs.isEmpty || text.isEmpty) return TextSpan(text: text, style: base);
    final chars = TextRuns.expand(text.length, runs);
    final children = <TextSpan>[];
    var i = 0;
    while (i < text.length) {
      var j = i + 1;
      while (j < text.length && chars[j] == chars[i]) {
        j++;
      }
      final c = chars[i];
      children.add(TextSpan(
        text: text.substring(i, j),
        style: c == plainChar
            ? null
            : TextStyle(
                color: c.color,
                fontWeight: c.bold == null ? null : (c.bold! ? FontWeight.w700 : FontWeight.w400),
                fontStyle: c.italic == null ? null : (c.italic! ? FontStyle.italic : FontStyle.normal),
                decoration: c.underline == null ? null : (c.underline! ? TextDecoration.underline : TextDecoration.none),
                decorationColor: c.color,
              ),
      ));
      i = j;
    }
    return TextSpan(style: base, children: children);
  }

  /// Laid-out text; centred or right-aligned lines line up within the widest line.
  static TextPainter textLayout(String string, Annotation a, Color color, {bool halo = false}) {
    final tp = TextPainter(
      text: richSpan(string, runsOf(a), textStyle(a, color, halo: halo)),
      textAlign: a.textFormat.align,
      textDirection: TextDirection.ltr,
    )..layout();
    if (a.textFormat.align != TextAlign.left) tp.layout(minWidth: tp.maxIntrinsicWidth, maxWidth: tp.maxIntrinsicWidth);
    return tp;
  }

  /// A callout's text colour: the chosen one, or black/white for contrast with the bubble.
  static Color calloutTextColor(Annotation a) => a.textFormat.textColor ?? contrast(a.color);

  static CalloutStyle calloutStyleOf(Annotation a) => a.shape is CalloutShape ? (a.shape as CalloutShape).style : CalloutStyle.rounded;

  /// `at` is the text's top-left corner; the box adds padding around it (more for an ellipse or a cloud,
  /// whose curves cut into the corners).
  static Rect calloutRect(String string, Offset at, Annotation a) {
    final tp = textLayout(string, a, Colors.black);
    final fontSize = a.fontSize;
    final roomy = switch (calloutStyleOf(a)) { CalloutStyle.ellipse => true, CalloutStyle.cloud => true, _ => false };
    final padX = fontSize * (roomy ? 1.1 : 0.5), padY = fontSize * (roomy ? 0.7 : 0.3);
    return Rect.fromLTWH(at.dx - padX, at.dy - padY, tp.width + padX * 2, tp.height + padY * 2);
  }

  /// While typing (`hideText`) an empty bubble is sized for the "Type here" hint.
  static void _callout(Canvas canvas, String string, Offset at, Offset? tail, Annotation a, {bool hideText = false}) {
    final shown = string.isEmpty && hideText ? typeHint : string;
    final bubble = calloutPath(calloutRect(shown, at, a), tail, a.fontSize, style: calloutStyleOf(a));
    canvas.drawPath(bubble.shift(const Offset(0, 1)), Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    canvas.drawPath(bubble, Paint()..color = a.color);
    if (!hideText) textLayout(string, a, calloutTextColor(a)).paint(canvas, at);
  }

  static const typeHint = 'Type here';

  /// The bubble outline: the body in the given style plus a pointer from the body's edge facing `tail` to
  /// the tail tip (a thought cloud gets a trail of shrinking puffs instead).
  static Path calloutPath(Rect box, Offset? tail, double fontSize, {CalloutStyle style = CalloutStyle.rounded}) {
    final radius = switch (style) {
      CalloutStyle.square => 0.0,
      CalloutStyle.pill => math.min(box.width, box.height) / 2,
      _ => fontSize * 0.35,
    };
    final body = switch (style) {
      CalloutStyle.ellipse => Path()..addOval(box),
      CalloutStyle.cloud => _cloud(box, fontSize),
      _ => Path()..addRRect(RRect.fromRectXY(box, radius, radius)),
    };
    if (tail == null || box.inflate(2).contains(tail)) return body;
    final c = box.center, d = tail - c;
    final halfW = box.width / 2, halfH = box.height / 2;
    final base = math.min(fontSize * 0.9, math.min(box.width, box.height) * 0.6); // pointer width at the box
    if (style == CalloutStyle.cloud) {
      // Puffs from just outside the cloud toward the tip, each smaller than the last
      final edge = _ellipseEdge(box, d) ;
      var path = body;
      for (final (f, r) in [(0.3, base * 0.42), (0.62, base * 0.3), (0.88, base * 0.19)]) {
        path = Path.combine(PathOperation.union, path, Path()..addOval(Rect.fromCircle(center: Offset.lerp(edge, tail, f)!, radius: r)));
      }
      return path;
    }
    if (style == CalloutStyle.ellipse) {
      // The pointer's foot straddles the point where the line to the tip leaves the oval
      final t = math.atan2(d.dy / halfH, d.dx / halfW);
      final spread = base / (halfW + halfH); // radians either side, so the foot is about `base` wide
      Offset on(double ang) => Offset(c.dx + halfW * math.cos(ang) * 0.98, c.dy + halfH * math.sin(ang) * 0.98);
      final pointer = Path()..addPolygon([on(t - spread), tail, on(t + spread)], true);
      return Path.combine(PathOperation.union, body, pointer);
    }
    final List<Offset> foot;
    if (d.dy.abs() * halfW >= d.dx.abs() * halfH) {
      // Leaves through the top or bottom edge
      final y = d.dy > 0 ? box.bottom - 1 : box.top + 1;
      final x = _within(c.dx + d.dx * (halfH / d.dy.abs()), box.left + radius + base / 2, box.right - radius - base / 2);
      foot = [Offset(x - base / 2, y), Offset(x + base / 2, y)];
    } else {
      // Leaves through the left or right edge
      final x = d.dx > 0 ? box.right - 1 : box.left + 1;
      final y = _within(c.dy + d.dy * (halfW / d.dx.abs()), box.top + radius + base / 2, box.bottom - radius - base / 2);
      foot = [Offset(x, y - base / 2), Offset(x, y + base / 2)];
    }
    final pointer = Path()..addPolygon([foot[0], tail, foot[1]], true);
    return Path.combine(PathOperation.union, body, pointer);
  }

  /// Like clamp, but a box too small for the pointer's margins (lo > hi) gives the middle instead of throwing.
  static double _within(double v, double lo, double hi) => lo <= hi ? v.clamp(lo, hi) : (lo + hi) / 2;

  /// Where a ray from the box centre in direction `d` crosses the box's inscribed ellipse.
  static Offset _ellipseEdge(Rect box, Offset d) {
    final c = box.center, halfW = box.width / 2, halfH = box.height / 2;
    final t = math.atan2(d.dy / halfH, d.dx / halfW);
    return Offset(c.dx + halfW * math.cos(t), c.dy + halfH * math.sin(t));
  }

  /// A thought cloud: the box with a ring of puffs (circles) around its edge.
  static Path _cloud(Rect box, double fontSize) {
    final r = math.min(fontSize * 0.75, math.min(box.width, box.height) * 0.45);
    final inner = box.deflate(r * 0.55);
    var path = Path()..addRRect(RRect.fromRectXY(inner, r, r));
    void puff(Offset c) => path = Path.combine(PathOperation.union, path, Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    // Puffs along each edge of the inner box, spaced so neighbours overlap
    final step = r * 1.25;
    final nx = math.max(1, (inner.width / step).round()), ny = math.max(1, (inner.height / step).round());
    for (var i = 0; i <= nx; i++) {
      final x = inner.left + inner.width * i / nx;
      puff(Offset(x, inner.top));
      puff(Offset(x, inner.bottom));
    }
    for (var i = 1; i < ny; i++) {
      final y = inner.top + inner.height * i / ny;
      puff(Offset(inner.left, y));
      puff(Offset(inner.right, y));
    }
    return path;
  }

  /// The outline of a step marker of [style] whose number is centred at [center]; [d] is the step diameter.
  /// Every style covers about the same area as the circle, so the number stays the same size.
  static Path stepPath(Offset center, double d, StepMarker style) {
    final r = d / 2;
    final path = Path();
    switch (style) {
      case StepMarker.circle:
        path.addOval(Rect.fromCircle(center: center, radius: r));
      case StepMarker.rounded:
        path.addRRect(RRect.fromRectXY(Rect.fromCircle(center: center, radius: r * 0.96), r * 0.42, r * 0.42));
      case StepMarker.square:
        path.addRect(Rect.fromCircle(center: center, radius: r * 0.92));
      case StepMarker.diamond:
        final s = r * 1.22;
        path.addPolygon([center + Offset(0, -s), center + Offset(s, 0), center + Offset(0, s), center + Offset(-s, 0)], true);
      case StepMarker.hexagon:
        final s = r * 1.1;
        path.addPolygon([for (var i = 0; i < 6; i++) center + Offset(s * math.sin(i * math.pi / 3), -s * math.cos(i * math.pi / 3))], true);
      case StepMarker.pin:
        // A map pin: the disc, with a point hanging below it
        final disc = Path()..addOval(Rect.fromCircle(center: center, radius: r));
        final tip = Path()
          ..moveTo(center.dx - r * 0.78, center.dy + r * 0.62)
          ..lineTo(center.dx, center.dy + d * 0.98)
          ..lineTo(center.dx + r * 0.78, center.dy + r * 0.62)
          ..close();
        return Path.combine(PathOperation.union, disc, tip);
    }
    return path;
  }

  /// The area a step marker covers (its selection box and hit area).
  static Rect stepBounds(Offset center, double d, StepMarker style) {
    final r = d / 2;
    return switch (style) {
      StepMarker.pin => Rect.fromLTRB(center.dx - r, center.dy - r, center.dx + r, center.dy + d * 0.98),
      StepMarker.diamond => Rect.fromCircle(center: center, radius: r * 1.22),
      StepMarker.hexagon => Rect.fromCircle(center: center, radius: r * 1.1),
      _ => Rect.fromCircle(center: center, radius: r),
    };
  }

  static void _step(Canvas canvas, Offset center, int number, Annotation a) {
    final d = a.stepDiameter;
    final style = a.shape is StepShape ? (a.shape as StepShape).style : StepMarker.circle;
    final path = stepPath(center, d, style);
    canvas.drawPath(path, Paint()..color = a.color);
    canvas.drawPath(path, _stroke(Colors.white.withValues(alpha: 0.9), math.max(1.5, d / 16))..strokeJoin = StrokeJoin.round);
    final tp = TextPainter(
      text: TextSpan(text: '${math.max(number, 1)}',
          style: TextStyle(color: contrast(a.color), fontSize: d * 0.55, fontWeight: FontWeight.w900)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  /// Each spotlight with how far it has appeared: the dimming fades in with the first one, and later
  /// ones open up from their centres.
  void _drawSpotlight(Canvas canvas, List<(Rect, double)> spots, Rect bounds) {
    final path = Path()..addRect(bounds); // dim the image only, not the canvas area around it
    final dim = spots.map((s) => s.$2).reduce(math.max);
    for (final (r, t) in spots) {
      final open = dim < 1 ? 1.0 : Curves.easeOut.transform(t);
      path.addRRect(RRect.fromRectXY(Rect.fromCenter(center: r.center, width: r.width * open, height: r.height * open), 8, 8));
    }
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.55 * dim));
  }

  // ---- Selection chrome ----

  void _drawSelection(Canvas canvas, Annotation a) {
    final handles = handlesOf(a);
    if (handles.isEmpty) return;
    final accent = const Color(0xFF2F7CF6);
    final r = a.rect;
    if (r != null) {
      // White under a dashed accent line, so the box shows on light and dark images alike
      final line = 1.5 / scale;
      canvas.drawRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = line);
      canvas.drawPath(dashed(Path()..addRect(r), [5 / scale, 4 / scale]),
          Paint()..color = accent..style = PaintingStyle.stroke..strokeWidth = line);
    }
    final rad = 5 / scale;
    if (a.curve != null) {
      _drawCurveGrips(canvas, a, rad, accent);
      return;
    }
    for (final h in handles) {
      canvas.drawCircle(h, rad + 1 / scale, Paint()..color = Colors.black.withValues(alpha: 0.25));
      canvas.drawCircle(h, rad, Paint()..color = Colors.white);
      canvas.drawCircle(h, rad, Paint()..color = accent..style = PaintingStyle.stroke..strokeWidth = 1.5 / scale);
    }
  }

  /// A selected arrow or line: a tangent line through every point (with a handle at each end), white end
  /// handles, solid blue bend points and "+" handles for adding more.
  void _drawCurveGrips(Canvas canvas, Annotation a, double rad, Color accent) {
    final pts = a.curve!, tg = a.curveTangents, n = pts.length;
    final line = Paint()..color = accent..strokeWidth = 1 / scale;
    for (var i = 0; i < n; i++) {
      final t = tangentAt(pts, tg, i) / 3;
      canvas.drawLine(i > 0 ? pts[i] - t : pts[i], i < n - 1 ? pts[i] + t : pts[i], line);
    }
    for (final g in curveGrips(a)) {
      final h = g.at;
      switch (g.kind) {
        case GripKind.tangent:
          // small diamond at each end of a tangent line
          final r = rad * 0.7;
          final d = Path()..addPolygon([h + Offset(0, -r), h + Offset(r, 0), h + Offset(0, r), h + Offset(-r, 0)], true);
          canvas.drawPath(d, Paint()..color = Colors.white);
          canvas.drawPath(d, Paint()..color = accent..style = PaintingStyle.stroke..strokeWidth = 1.2 / scale);
        case GripKind.add:
          final r = rad * 0.75;
          canvas.drawCircle(h, r, Paint()..color = Colors.white.withValues(alpha: 0.85));
          canvas.drawCircle(h, r, Paint()..color = accent..style = PaintingStyle.stroke..strokeWidth = 1 / scale);
          final plus = Paint()..color = accent..strokeWidth = 1.2 / scale;
          canvas.drawLine(h - Offset(r * 0.55, 0), h + Offset(r * 0.55, 0), plus);
          canvas.drawLine(h - Offset(0, r * 0.55), h + Offset(0, r * 0.55), plus);
        case GripKind.bend || GripKind.end:
          final bend = g.kind == GripKind.bend;
          final r = bend ? rad * 0.85 : rad;
          canvas.drawCircle(h, r + 1 / scale, Paint()..color = Colors.black.withValues(alpha: 0.25));
          canvas.drawCircle(h, r, Paint()..color = bend ? accent : Colors.white);
          canvas.drawCircle(h, r, Paint()..color = bend ? Colors.white : accent..style = PaintingStyle.stroke..strokeWidth = 1.5 / scale);
      }
    }
  }

  static List<Offset> handlesOf(Annotation a) {
    switch (a.shape) {
      case ArrowShape() || LineShape():
        return [for (final g in curveGrips(a)) g.at];
      case CalloutShape(:final tail?):
        return [tail]; // drag the pointer's tip to re-aim it
      default:
        final r = a.rect;
        if (r == null) return const [];
        return rectHandles(r);
    }
  }

  static List<Offset> rectHandles(Rect r) => [
        r.topLeft, r.topRight, r.bottomLeft, r.bottomRight,
        Offset(r.center.dx, r.top), Offset(r.center.dx, r.bottom),
        Offset(r.left, r.center.dy), Offset(r.right, r.center.dy),
      ];

  @override
  bool shouldRepaint(covariant CanvasPainter old) =>
      old.state != state || old.selectionId != selectionId || old.scale != scale || old.scaleY != scaleY ||
      old.hiddenTextId != hiddenTextId || old.progress != progress || old.march != march || old.epicycles != epicycles ||
      old.envelope != envelope || old.fade != fade || old.flyFrom != flyFrom || old.flyTo != flyTo ||
      old.first != first || old.end != end || old.under != under;
}

/// The kinds of handle on a selected arrow or line.
enum GripKind { end, bend, add, tangent }

/// One handle: where it is, what it is, the curve point (or stretch, for "+") it belongs to, and which side
/// of its tangent line (-1 / +1) a tangent handle is on.
typedef CurveGrip = ({Offset at, GripKind kind, int index, int side});

class _Head {
  final Path? path;
  final bool filled;
  final double lineWidth;
  final Offset trim;
  /// How far behind the tip the head's rearmost edge is, and whether the line would show inside the head there.
  final double back;
  final bool hollow;
  const _Head(this.path, {this.filled = true, this.lineWidth = 0, required this.trim, this.back = 0, this.hollow = false});
}

/// An effect's line (ending at the back of each head) with its heads, and lookups along it by distance.
class _Fx {
  final Path line;
  final ui.PathMetric m;
  final _Head start, end;
  final Offset tip, dir; // the end's point and the direction the line arrives in
  final Path body; // [line] in the arrow's pattern (the line itself when solid)
  final List<(double, double)> pieces; // the stretches of the line the pattern shows; empty = solid
  final double width; // the line's width
  _Fx(this.line, this.m, this.start, this.end, this.tip, this.dir, {required this.body, required this.pieces, required this.width});
  List<_Head> get heads => [start, end];
  double get len => m.length;
  ui.Tangent _tangent(double d) => m.getTangentForOffset(d.clamp(0.0, len))!;
  Offset at(double d) => _tangent(d).position;
  Offset normal(double d) {
    final v = _tangent(d).vector;
    return Offset(-v.dy, v.dx);
  }
  Path part(double a, double b) => m.extractPath(a.clamp(0.0, len), b.clamp(0.0, len));
  /// Whether the line shows at `d` along it: on a dash of its pattern or within half a line width of one (its round end).
  bool shows(double d) => pieces.isEmpty || pieces.any((p) => d >= p.$1 - width / 2 && d <= p.$2 + width / 2);
}

/// A small preview of a line style (for the Arrowheads / Pattern menus).
class StylePreview extends StatelessWidget {
  final ArrowStyle style;
  final bool line;
  final Color color;
  const StylePreview(this.style, {super.key, this.line = true, this.color = Colors.black87});

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(48, 18), painter: _PreviewStyle(style, line, color));
}

class _PreviewStyle extends CustomPainter {
  final ArrowStyle style;
  final bool line;
  final Color color;
  _PreviewStyle(this.style, this.line, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final plain = style.copyWith(shadow: false, outline: false);
    final y = size.height / 2;
    if (line) {
      CanvasPainter.drawEffect(canvas, [Offset(7, y), Offset(size.width - 7, y)], plain, color, 2, phase: 0); // plain without an effect
    } else {
      CanvasPainter.strokeStyled(canvas, Path()..addRRect(RRect.fromRectXY(Rect.fromLTWH(4, 3, size.width - 8, size.height - 6), 2, 2)),
          plain, color, 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewStyle old) => old.style != style || old.line != line || old.color != color;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

/// How the heads sit on a short arrow ([CanvasPainter._shortArrow]).
typedef _Short = ({double size, double blend, double thin, double reach, Offset towardStart, Offset towardEnd, ui.PathMetric? curve});
