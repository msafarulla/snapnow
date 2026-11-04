import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show ValueListenable;
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

  /// [animate] makes the painter repaint on every [march] tick: only wanted when a committed annotation
  /// actually marches, so the editor's cached picture layer isn't re-rasterised 25× a second for nothing.
  CanvasPainter({required this.state, required this.selectionId, required this.scale, this.scaleY, this.hiddenTextId,
      this.progress, this.march, this.epicycles = false, this.envelope = false, bool animate = false})
      : super(repaint: animate ? march : null);

  double get _sy => scaleY ?? scale; // vertical scale, == scale unless a non-proportional editor resize set it

  double _shown(Annotation a) => progress == null ? 1 : progress![a.id] ?? 0;

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
    canvas.drawRect(imageRect, Paint()..color = state.background); // canvas colour behind the image
    // Smoothed when drawn smaller (GIFs at point size, zoomed-out editor): unfiltered drops pixels, jagged text
    canvas.drawImage(img, Offset.zero, Paint()..filterQuality = FilterQuality.medium);

    // Blur patches first, then spotlight dimming, then the rest in order.
    final spotlights = <(Rect, double)>[];
    for (final a in state.annotations) {
      final t = _shown(a);
      if (t <= 0) continue;
      switch (a.shape) {
        case BlurShape():
          drawPartial(canvas, a, t, base: img);
        case SpotlightShape(:final rect):
          spotlights.add((rect, t));
        default:
          break;
      }
    }
    if (spotlights.isNotEmpty) _drawSpotlight(canvas, spotlights, imageRect);

    var step = 0;
    for (final a in state.annotations) {
      if (a.shape is StepShape) step += 1; // steps keep their final numbers while the others are still hidden
      final t = _shown(a);
      if (t <= 0) continue;
      switch (a.shape) {
        case BlurShape():
        case SpotlightShape():
          continue;
        case StepShape():
          drawPartial(canvas, a, t, number: step);
        default:
          drawPartial(canvas, a, t, hideText: a.id == hiddenTextId, envelope: envelope);
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
        drawArrow(canvas, a.curve!, a.arrowStyle, a.color, w, tangents: a.curveTangents);
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
        if (pts != null) drawArrow(canvas, pts, a.arrowStyle, a.color, w);
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
    final count = (total / 11).clamp(28, 110).round(); // tangents along the whole path
    final half = (total * 0.22).clamp(28.0, 150.0); // each tangent reaches this far either side
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
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.7, w * 0.22)
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
      final alpha = (age <= 6 ? 0.85 - 0.09 * (age - 1) : 0.3) * fade;
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

  /// A head at `tip`, pointing away from `from`. `trim` is where the body stops so its cap hides under the head.
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
        return _Head(polygon([tip, at(length, half), at(length, -half)]), trim: at(length * 0.8, 0));
      case ArrowHead.swept:
        return _Head(polygon([tip, at(length * 1.1, half), at(length * 0.7, 0), at(length * 1.1, -half)]),
            trim: at(length * 0.6, 0));
      case ArrowHead.triangleOutline:
        return _Head(polygon([tip, at(length, half), at(length, -half)]), filled: false, lineWidth: thin,
            trim: at(length, 0));
      case ArrowHead.open:
        return _Head(stroked([at(length * 0.75, half), tip, at(length * 0.75, -half)]), filled: false, lineWidth: w,
            trim: tip);
      case ArrowHead.dot:
        final r = math.max(4.0, w * 1.4) * k;
        return _Head(Path()..addOval(Rect.fromCircle(center: tip, radius: r)), trim: tip);
      case ArrowHead.circle:
        final r = math.max(5.0, w * 1.8) * k;
        return _Head(Path()..addOval(Rect.fromCircle(center: tip, radius: r)), filled: false, lineWidth: thin,
            trim: at(r, 0));
      case ArrowHead.square:
        final s = math.max(4.0, w * 1.4) * k;
        return _Head(polygon([at(-s, s), at(-s, -s), at(s, -s), at(s, s)]), trim: tip);
      case ArrowHead.diamond:
        final d = math.max(8.0, w * 2.8) * k;
        return _Head(polygon([at(-d, 0), at(0, d * 0.7), at(d, 0), at(0, -d * 0.7)]), trim: tip);
      case ArrowHead.bar:
        final s = math.max(7.0, w * 2.4) * k;
        return _Head(stroked([at(0, s), at(0, -s)]), filled: false, lineWidth: w, trim: tip);
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
    return dashed(path, dashes, phase: cycle * (1 - _marchNow));
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

  /// An arrow or line along a smooth curve through `pts` (start, bend points, end); each head points
  /// along the curve at its end.
  static void drawArrow(Canvas canvas, List<Offset> pts, ArrowStyle style, Color color, double w,
      {List<Offset?> tangents = const []}) {
    final a = pts.first, b = pts.last;
    if (pts.length < 2 || ((b - a).distance <= 1 && pts.length == 2)) return;
    final segs = spline(pts, tangents);
    final (_, firstC1, _, _) = segs.first;
    final (lastA, _, lastC2, _) = segs.last;
    final towardEnd = (lastC2 - b).distance > 0.5 ? lastC2 : lastA;
    final towardStart = (firstC1 - a).distance > 0.5 ? firstC1 : segs.first.$4;
    final k = style.headSize.scale;
    // Tapered: a slightly larger head, and a body that widens only as far as suits that head, so it
    // never swamps small heads (dot, bar, open chevron) or fills a swept head's notch
    final headW = style.tapered ? w * 1.45 : w;
    final taperFull = style.tapered ? _taperFull(style.end, headW, k, w) : w; // body width where it meets the head
    final endWidth = taperFull / 1.8; // _taperedBody's width parameter (its widest end is 1.8 × this)
    var end = _head(style.end, b, towardEnd, headW, k);
    if (style.tapered && style.end == ArrowHead.open) {
      // The chevron's strokes match the body, which stops just behind its point
      final u = _unit(towardEnd, b);
      end = _Head(end.path, filled: false, lineWidth: math.max(headW, taperFull * 0.85), trim: b - u * (taperFull * 0.5));
    }
    final start = _head(style.start, a, towardStart, w, k);

    // The body runs between the trimmed ends (hidden under the heads), through the same bend points
    final body = [start.trim, ...pts.sublist(1, pts.length - 1), end.trim];
    final centerline = _curvePath(body, tangents);
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
      old.envelope != envelope;
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
  const _Head(this.path, {this.filled = true, this.lineWidth = 0, required this.trim});
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
      CanvasPainter.drawArrow(canvas, [Offset(7, y), Offset(size.width - 7, y)], plain, color, 2);
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
