import 'dart:ui';


/// The editor tools. Mirrors the Swift app's `Tool`.
enum Tool { select, arrow, line, box, ellipse, highlight, pen, text, callout, step, blur, spotlight, crop, grabText }

/// The Shape tool's choices. Rectangles draw with the Box tool and ellipses with the Ellipse tool;
/// a square or circle keeps its sides equal while you drag.
enum ShapeKind {
  rectangle, square, ellipse, circle;

  String get label => const ['Rectangle', 'Square', 'Ellipse', 'Circle'][index];
  bool get oval => this == ellipse || this == circle;
  bool get even => this == square || this == circle;
  Tool get tool => oval ? Tool.ellipse : Tool.box;
}

enum StrokeSize {
  small,
  medium,
  large;

  String get label => const ['S', 'M', 'L'][index];
  double get line => switch (this) { StrokeSize.small => 3, StrokeSize.medium => 5, StrokeSize.large => 8 };
  double get fontSize => switch (this) { StrokeSize.small => 18, StrokeSize.medium => 26, StrokeSize.large => 36 };
  double get stepDiameter => switch (this) { StrokeSize.small => 26, StrokeSize.medium => 34, StrokeSize.large => 46 };
}

/// Arrowheads, in the Swift app's order (stored as their index).
enum ArrowHead {
  none, triangle, swept, triangleOutline, open, dot, circle, square, diamond, bar;

  String get label => const ['None', 'Triangle', 'Swept', 'Triangle Outline', 'Open', 'Dot', 'Circle', 'Square',
    'Diamond', 'Bar'][index];
}

enum HeadSize {
  small, medium, large;

  String get label => const ['Small', 'Medium', 'Large'][index];
  double get scale => const [0.75, 1.0, 1.45][index];
}

enum LinePattern {
  // Saved by index: add new patterns at the end
  solid, dashed, dotted, dashDot, longDash, ants, antsDotted, antsDashDot, antsLongDash;

  String get label => const ['Solid', 'Dashed', 'Dotted', 'Dash-Dot', 'Long Dash', 'Marching Ants', 'Marching Dots',
        'Marching Dash-Dot', 'Marching Long Dash'][index];

  /// The Pattern menu: the still patterns; the Marching checkbox picks the moving twin (solid has none).
  static const menu = [solid, dashed, dotted, dashDot, longDash];
  static const _twins = {dashed: ants, dotted: antsDotted, dashDot: antsDashDot, longDash: antsLongDash};

  /// The still pattern this one is (itself unless it marches).
  LinePattern get still => _twins.entries.firstWhere((e) => e.value == this, orElse: () => MapEntry(this, this)).key;

  /// Whether the Marching checkbox applies (anything with gaps).
  bool get canMarch => _twins.containsKey(still);

  /// This pattern, marching or still.
  LinePattern marching(bool on) => on ? (_twins[still] ?? this) : still;

  /// Dashes that keep running toward the line's end (the arrowhead) in the editor and animated GIFs.
  bool get marches => index >= LinePattern.ants.index;

  /// Dash lengths for a line `w` wide. Near-zero dashes with round caps draw as dots.
  List<double>? dashes(double w) => switch (this) {
        LinePattern.solid => null,
        LinePattern.dashed || LinePattern.ants => [w * 2.4, w * 2.2],
        LinePattern.dotted || LinePattern.antsDotted => [0.01, w * 2],
        LinePattern.dashDot || LinePattern.antsDashDot => [w * 2.6, w * 1.8, 0.01, w * 1.8],
        LinePattern.longDash || LinePattern.antsLongDash => [w * 5, w * 2.5],
      };
}

/// Which remembered style an annotation or tool uses: arrows, lines, and shapes (box, ellipse, pen).
enum StyleKind {
  arrow, line, shape;

  ArrowStyle get builtIn => switch (this) {
        StyleKind.arrow => ArrowStyle.arrow,
        StyleKind.line => ArrowStyle.line,
        StyleKind.shape => ArrowStyle.shape,
      };

  static StyleKind? ofTool(Tool t) => switch (t) {
        Tool.arrow => StyleKind.arrow,
        Tool.line => StyleKind.line,
        Tool.box || Tool.ellipse || Tool.pen => StyleKind.shape,
        _ => null,
      };
}

/// How arrows, lines, boxes, ellipses and pen strokes are drawn. Heads and tapering only apply to
/// arrows and lines. Mirrors the Swift `ArrowStyle`, including its JSON (shared UserDefaults).
class ArrowStyle {
  final ArrowHead start;
  final ArrowHead end;
  final HeadSize headSize;
  final LinePattern pattern;
  final bool tapered;
  final bool outline;
  final bool shadow;
  final bool border; // a thin edge in a darker shade of the line's own colour
  final bool beam; // a light beam: dark glass tube, glowing pellets and comets running toward the head
  final Color? borderColor; // the Border edge's colour, or the Outline's when Border is off; null = automatic
  final double? width; // exact line thickness in points (the thickness slider); null = from S / M / L
  const ArrowStyle({
    this.start = ArrowHead.none,
    this.end = ArrowHead.triangle,
    this.headSize = HeadSize.medium,
    this.pattern = LinePattern.solid,
    this.tapered = false,
    this.outline = false,
    this.shadow = true,
    this.border = false,
    this.beam = false,
    this.borderColor,
    this.width,
  });

  static const arrow = ArrowStyle(end: ArrowHead.swept); // the Arrow tool's built-in look
  static const line = ArrowStyle(end: ArrowHead.none);
  static const shape = ArrowStyle(end: ArrowHead.none, shadow: false);

  ArrowStyle copyWith({ArrowHead? start, ArrowHead? end, HeadSize? headSize, LinePattern? pattern, bool? tapered,
          bool? outline, bool? shadow, bool? border, bool? beam}) =>
      ArrowStyle(
        start: start ?? this.start,
        end: end ?? this.end,
        headSize: headSize ?? this.headSize,
        pattern: pattern ?? this.pattern,
        tapered: tapered ?? this.tapered,
        outline: outline ?? this.outline,
        shadow: shadow ?? this.shadow,
        border: border ?? this.border,
        beam: beam ?? this.beam,
        borderColor: borderColor,
        width: width,
      );

  ArrowStyle withWidth(double? value) => ArrowStyle(start: start, end: end, headSize: headSize, pattern: pattern,
      tapered: tapered, outline: outline, shadow: shadow, border: border, beam: beam, borderColor: borderColor, width: value);

  ArrowStyle withBorderColor(Color? value) => ArrowStyle(start: start, end: end, headSize: headSize, pattern: pattern,
      tapered: tapered, outline: outline, shadow: shadow, border: border, beam: beam, borderColor: value, width: width);

  Map<String, Object> toJson() => {
        'start': start.index, 'end': end.index, 'headSize': headSize.index, 'pattern': pattern.index,
        'tapered': tapered, 'outline': outline, 'shadow': shadow,
        if (border) 'border': true,
        if (beam) 'beam': true,
        if (borderColor != null) 'borderColor': borderColor!.toARGB32(),
        if (width != null) 'width': width!,
      };

  static ArrowStyle? fromJson(Object? json) {
    if (json is! Map) return null;
    T pick<T>(List<T> values, Object? i, T fallback) => i is int && i >= 0 && i < values.length ? values[i] : fallback;
    return ArrowStyle(
      start: pick(ArrowHead.values, json['start'], ArrowHead.none),
      end: pick(ArrowHead.values, json['end'], ArrowHead.triangle),
      headSize: pick(HeadSize.values, json['headSize'], HeadSize.medium),
      pattern: pick(LinePattern.values, json['pattern'], LinePattern.solid),
      tapered: json['tapered'] == true,
      outline: json['outline'] == true,
      shadow: json['shadow'] != false,
      border: json['border'] == true,
      beam: json['beam'] == true,
      borderColor: json['borderColor'] is int ? Color(json['borderColor'] as int) : null,
      width: (json['width'] as num?)?.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ArrowStyle && other.start == start && other.end == end && other.headSize == headSize &&
      other.pattern == pattern && other.tapered == tapered && other.outline == outline && other.shadow == shadow &&
      other.border == border && other.beam == beam && other.borderColor == borderColor && other.width == width;

  @override
  int get hashCode => Object.hash(start, end, headSize, pattern, tapered, outline, shadow, border, beam, borderColor, width);
}

/// How Text and Callout annotations set their words: font, exact size, bold/italic/underline, alignment,
/// the callout's text colour and the text's shadow. Remembered per tool (UserDefaults "style.textFormat.<kind>").
class TextFormat {
  final String family; // '' = the system font
  final double? points; // exact size; null = from S / M / L
  final bool bold, italic, underline;
  final bool shadow; // Text only: a soft halo so it reads on any background
  final TextAlign align;
  final Color? textColor; // Callout only: null = black or white, whichever contrasts with the bubble

  const TextFormat({this.family = '', this.points, this.bold = true, this.italic = false, this.underline = false,
      this.shadow = true, this.align = TextAlign.left, this.textColor});

  TextFormat copyWith({String? family, bool? bold, bool? italic, bool? underline, bool? shadow, TextAlign? align}) =>
      TextFormat(family: family ?? this.family, points: points, bold: bold ?? this.bold, italic: italic ?? this.italic,
          underline: underline ?? this.underline, shadow: shadow ?? this.shadow, align: align ?? this.align, textColor: textColor);

  TextFormat withPoints(double? value) => TextFormat(family: family, points: value, bold: bold, italic: italic,
      underline: underline, shadow: shadow, align: align, textColor: textColor);

  TextFormat withTextColor(Color? value) => TextFormat(family: family, points: points, bold: bold, italic: italic,
      underline: underline, shadow: shadow, align: align, textColor: value);

  Map<String, Object?> toJson() => {
        'family': family, 'points': points, 'bold': bold, 'italic': italic, 'underline': underline, 'shadow': shadow,
        'align': align.index, 'textColor': textColor?.toARGB32(),
      };

  static TextFormat? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['align'];
    return TextFormat(
      family: j['family'] is String ? j['family'] as String : '',
      points: (j['points'] as num?)?.toDouble(),
      bold: j['bold'] != false,
      italic: j['italic'] == true,
      underline: j['underline'] == true,
      shadow: j['shadow'] != false,
      align: a is int && a >= 0 && a < TextAlign.values.length ? TextAlign.values[a] : TextAlign.left,
      textColor: j['textColor'] is int ? Color(j['textColor'] as int) : null,
    );
  }

  @override
  bool operator ==(Object o) => o is TextFormat && o.family == family && o.points == points && o.bold == bold &&
      o.italic == italic && o.underline == underline && o.shadow == shadow && o.align == align && o.textColor == textColor;
  @override
  int get hashCode => Object.hash(family, points, bold, italic, underline, shadow, align, textColor);
}

/// Per-character formatting on top of the TextFormat: only what was set on highlighted words.
typedef CharStyle = ({Color? color, bool? bold, bool? italic, bool? underline});
const CharStyle plainChar = (color: null, bold: null, italic: null, underline: null);

/// A run of characters [start, end) with the same overrides.
class TextRun {
  final int start, end;
  final CharStyle style;
  const TextRun(this.start, this.end, this.style);

  @override
  bool operator ==(Object o) => o is TextRun && o.start == start && o.end == end && o.style == style;
  @override
  int get hashCode => Object.hash(start, end, style);
}

/// Helpers that keep runs right as text is edited or restyled.
class TextRuns {
  static List<CharStyle> expand(int length, List<TextRun> runs) {
    final out = List<CharStyle>.filled(length, plainChar);
    for (final r in runs) {
      for (var i = r.start.clamp(0, length); i < r.end.clamp(0, length); i++) {
        out[i] = r.style;
      }
    }
    return out;
  }

  static List<TextRun> compress(List<CharStyle> chars) {
    final out = <TextRun>[];
    var i = 0;
    while (i < chars.length) {
      var j = i + 1;
      while (j < chars.length && chars[j] == chars[i]) {
        j++;
      }
      if (chars[i] != plainChar) out.add(TextRun(i, j, chars[i]));
      i = j;
    }
    return out;
  }

  /// Restyles [start, end) with `change`.
  static List<TextRun> apply(int length, List<TextRun> runs, int start, int end, CharStyle Function(CharStyle) change) {
    final chars = expand(length, runs);
    for (var i = start.clamp(0, length); i < end.clamp(0, length); i++) {
      chars[i] = change(chars[i]);
    }
    return compress(chars);
  }

  /// Moves runs to follow an edit from `oldText` to `newText`: typed characters take the style of the
  /// character before them (or after, at the very start).
  static List<TextRun> adjust(String oldText, String newText, List<TextRun> runs) {
    if (runs.isEmpty || oldText == newText) return runs;
    final old = expand(oldText.length, runs);
    var p = 0;
    while (p < oldText.length && p < newText.length && oldText.codeUnitAt(p) == newText.codeUnitAt(p)) {
      p++;
    }
    var q = 0;
    while (q < oldText.length - p && q < newText.length - p &&
        oldText.codeUnitAt(oldText.length - 1 - q) == newText.codeUnitAt(newText.length - 1 - q)) {
      q++;
    }
    final inserted = newText.length - p - q;
    final carry = p > 0 ? old[p - 1] : (old.length > p ? old[p] : plainChar);
    return compress([...old.sublist(0, p), for (var i = 0; i < inserted; i++) carry, ...old.sublist(oldText.length - q)]);
  }
}

/// The geometry of an annotation, in the base image's coordinate space (origin top-left).
/// A Dart 3 sealed class, so the painter/hit-tester switch over it exhaustively.
sealed class Shape {
  const Shape();
}

/// Arrows and lines run from `from` to `to` through any number of bend `points` on the curve itself; the
/// curve flows smoothly through all of them. No points = a straight line. `tangents` holds a direction per
/// curve point (start, bends…, end), set by dragging the handles of the tangent line through it; a missing
/// or null entry = the automatic smooth tangent.
class ArrowShape extends Shape {
  final Offset from, to;
  final List<Offset> points;
  final List<Offset?> tangents;
  const ArrowShape(this.from, this.to, {this.points = const [], this.tangents = const []});
}

class LineShape extends Shape {
  final Offset from, to;
  final List<Offset> points;
  final List<Offset?> tangents;
  const LineShape(this.from, this.to, {this.points = const [], this.tangents = const []});
}

class RectShape extends Shape {
  final Rect rect;
  const RectShape(this.rect);
}

class EllipseShape extends Shape {
  final Rect rect;
  const EllipseShape(this.rect);
}

class HighlightShape extends Shape {
  final Rect rect;
  const HighlightShape(this.rect);
}

class SpotlightShape extends Shape {
  final Rect rect;
  const SpotlightShape(this.rect);
}

class PenShape extends Shape {
  final List<Offset> points;
  const PenShape(this.points);
}

class TextShape extends Shape {
  final String string;
  final Offset at;
  final List<TextRun> runs; // formatting on highlighted words
  const TextShape(this.string, this.at, {this.runs = const []});
}

/// A speech bubble: text at `at` (top-left of the text) and a pointer whose tip is at `tail`
/// (null: no pointer, e.g. callouts made before pointers existed).
/// The bubble a Callout's text sits in.
enum CalloutStyle {
  rounded, square, pill, ellipse, cloud;

  String get label => const ['Rounded', 'Square', 'Pill', 'Ellipse', 'Thought cloud'][index];
}

class CalloutShape extends Shape {
  final String string;
  final Offset at;
  final Offset? tail;
  final List<TextRun> runs; // formatting on highlighted words
  final CalloutStyle style;
  const CalloutShape(this.string, this.at, {this.tail, this.runs = const [], this.style = CalloutStyle.rounded});

  CalloutShape copyWith({String? string, Offset? at, Offset? Function()? tail, List<TextRun>? runs, CalloutStyle? style}) =>
      CalloutShape(string ?? this.string, at ?? this.at,
          tail: tail != null ? tail() : this.tail, runs: runs ?? this.runs, style: style ?? this.style);
}

/// The marker a Step number sits in.
enum StepMarker {
  circle, rounded, square, diamond, hexagon, pin;

  String get label => const ['Circle', 'Rounded square', 'Square', 'Diamond', 'Hexagon', 'Pin'][index];
}

class StepShape extends Shape {
  final Offset center;
  final StepMarker style;
  const StepShape(this.center, {this.style = StepMarker.circle});
}

/// A pixelated patch cut from the base image (computed when the blur is created/moved).
class BlurShape extends Shape {
  final Rect rect;
  final Image? patch;
  const BlurShape(this.rect, this.patch);
}

/// An image dropped on top: movable, resizable; grows the canvas if it spills past an edge.
class ImageShape extends Shape {
  final Rect rect;
  final Image image;
  const ImageShape(this.rect, this.image);
}

/// A single annotation: geometry plus style.
class Annotation {
  final int id;
  final Shape shape;
  final Color color;
  final StrokeSize size;
  final ArrowStyle arrowStyle;
  /// Pixels per point of the image it was drawn on (2 on Retina captures), so S/M/L look the same
  /// on any capture, as they did in the Swift app (which worked in points).
  final double scale;
  final TextFormat textFormat; // Text and Callout only

  const Annotation({
    required this.id,
    required this.shape,
    this.color = const Color(0xFFE8332A),
    this.size = StrokeSize.medium,
    this.arrowStyle = const ArrowStyle(),
    this.scale = 1,
    this.textFormat = const TextFormat(),
  });

  double get lineWidth => (styleKind != null ? arrowStyle.width ?? size.line : size.line) * scale;
  double get fontSize => (textFormat.points ?? size.fontSize) * scale;
  double get stepDiameter => size.stepDiameter * scale;

  Annotation copyWith({Shape? shape, Color? color, StrokeSize? size, ArrowStyle? arrowStyle, TextFormat? textFormat}) =>
      Annotation(
        id: id,
        shape: shape ?? this.shape,
        color: color ?? this.color,
        size: size ?? this.size,
        arrowStyle: arrowStyle ?? this.arrowStyle,
        scale: scale,
        textFormat: textFormat ?? this.textFormat,
      );

  bool get isTextual => shape is TextShape || shape is CalloutShape;

  /// An arrow's or line's whole path: start, bend points, end (null for other shapes).
  List<Offset>? get curve => switch (shape) {
        ArrowShape(:final from, :final to, :final points) || LineShape(:final from, :final to, :final points) =>
          [from, ...points, to],
        _ => null,
      };

  /// Tangents lined up with `curve` (null = automatic).
  List<Offset?> get curveTangents {
    final pts = curve;
    if (pts == null) return const [];
    final t = switch (shape) { ArrowShape(:final tangents) || LineShape(:final tangents) => tangents, _ => const <Offset?>[] };
    return [for (var i = 0; i < pts.length; i++) i < t.length ? t[i] : null];
  }

  /// The same arrow or line through a new path (start, bend points, end) with matching tangents.
  Annotation withCurve(List<Offset> pts, {List<Offset?>? tangents}) {
    final t = tangents ?? curveTangents;
    final inner = pts.sublist(1, pts.length - 1);
    final keep = t.any((x) => x != null) ? t : const <Offset?>[];
    return copyWith(
        shape: shape is LineShape
            ? LineShape(pts.first, pts.last, points: inner, tangents: keep)
            : ArrowShape(pts.first, pts.last, points: inner, tangents: keep));
  }

  /// A bend point inserted at curve index `i` (1 … length-1), with an automatic tangent.
  Annotation insertBend(int i, Offset p) =>
      withCurve([...curve!]..insert(i, p), tangents: [...curveTangents]..insert(i, null));

  Annotation removeBend(int i) => withCurve([...curve!]..removeAt(i), tangents: [...curveTangents]..removeAt(i));

  /// Sets (or with null, resets to automatic) the tangent at curve index `i`.
  Annotation withTangent(int i, Offset? t) => withCurve(curve!, tangents: [...curveTangents]..[i] = t);

  /// Arrows, lines and shapes have a line style; text, steps, blur etc. don't.
  StyleKind? get styleKind => switch (shape) {
        ArrowShape() => StyleKind.arrow,
        LineShape() => StyleKind.line,
        RectShape() || EllipseShape() || PenShape() => StyleKind.shape,
        _ => null,
      };

  /// The rect for rect-based shapes, else null.
  Rect? get rect => switch (shape) {
        RectShape(:final rect) => rect,
        EllipseShape(:final rect) => rect,
        HighlightShape(:final rect) => rect,
        SpotlightShape(:final rect) => rect,
        BlurShape(:final rect) => rect,
        ImageShape(:final rect) => rect,
        _ => null,
      };

  Annotation withRect(Rect r) {
    final s = switch (shape) {
      RectShape() => RectShape(r),
      EllipseShape() => EllipseShape(r),
      HighlightShape() => HighlightShape(r),
      SpotlightShape() => SpotlightShape(r),
      BlurShape(:final patch) => BlurShape(r, patch),
      ImageShape(:final image) => ImageShape(r, image),
      _ => shape,
    };
    return copyWith(shape: s);
  }

  Annotation movedBy(Offset d) {
    final s = switch (shape) {
      ArrowShape(:final from, :final to, :final points, :final tangents) =>
        ArrowShape(from + d, to + d, points: [for (final p in points) p + d], tangents: tangents),
      LineShape(:final from, :final to, :final points, :final tangents) =>
        LineShape(from + d, to + d, points: [for (final p in points) p + d], tangents: tangents),
      PenShape(:final points) => PenShape([for (final p in points) p + d]),
      TextShape(:final string, :final at, :final runs) => TextShape(string, at + d, runs: runs),
      CalloutShape(:final at, :final tail) && final c =>
        c.copyWith(at: at + d, tail: () => tail == null ? null : tail + d),
      StepShape(:final center, :final style) => StepShape(center + d, style: style),
      _ => (rect != null) ? null : shape,
    };
    if (s == null) return withRect(rect!.shift(d));
    return copyWith(shape: s);
  }

  /// Every geometry coordinate multiplied toward the image origin, for scaling the whole canvas to a new
  /// pixel size. Stroke width and text size (set by `size`, not pixels) are left as they are.
  Annotation scaledBy(double sx, double sy) {
    Offset sc(Offset o) => Offset(o.dx * sx, o.dy * sy);
    Rect scr(Rect r) => Rect.fromLTRB(r.left * sx, r.top * sy, r.right * sx, r.bottom * sy);
    final s = switch (shape) {
      ArrowShape(:final from, :final to, :final points, :final tangents) =>
        ArrowShape(sc(from), sc(to), points: [for (final p in points) sc(p)],
            tangents: [for (final t in tangents) t == null ? null : sc(t)]),
      LineShape(:final from, :final to, :final points, :final tangents) =>
        LineShape(sc(from), sc(to), points: [for (final p in points) sc(p)],
            tangents: [for (final t in tangents) t == null ? null : sc(t)]),
      PenShape(:final points) => PenShape([for (final p in points) sc(p)]),
      TextShape(:final string, :final at, :final runs) => TextShape(string, sc(at), runs: runs),
      CalloutShape(:final at, :final tail) && final c =>
        c.copyWith(at: sc(at), tail: () => tail == null ? null : sc(tail)),
      StepShape(:final center, :final style) => StepShape(sc(center), style: style),
      RectShape(:final rect) => RectShape(scr(rect)),
      EllipseShape(:final rect) => EllipseShape(scr(rect)),
      HighlightShape(:final rect) => HighlightShape(scr(rect)),
      SpotlightShape(:final rect) => SpotlightShape(scr(rect)),
      BlurShape(:final rect, :final patch) => BlurShape(scr(rect), patch),
      ImageShape(:final rect, :final image) => ImageShape(scr(rect), image),
    };
    return copyWith(shape: s);
  }
}

/// The editable document: a base image plus annotations, all in image points.
class CanvasState {
  final Image image;
  final List<Annotation> annotations;
  /// Shows through transparent parts of the image, including space added by resizing or auto-grow.
  final Color background;
  /// Pixels per point (2 for Retina captures); new annotations are sized by it.
  final double density;
  const CanvasState({required this.image, this.annotations = const [], this.background = const Color(0x00000000),
      this.density = 1});

  CanvasState copyWith({Image? image, List<Annotation>? annotations, Color? background}) => CanvasState(
      image: image ?? this.image, annotations: annotations ?? this.annotations, background: background ?? this.background,
      density: density);
}
