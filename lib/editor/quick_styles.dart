import 'dart:convert';
import 'dart:ui';
import '../model/annotation.dart';
import '../platform/native.dart';

/// What the Quick Styles grid offers presets for (same keys as the Swift app's saved styles).
enum QuickKind {
  arrow, line, shape, text, callout, step, highlight;

  static QuickKind? ofTool(Tool t) => switch (t) {
        Tool.arrow => QuickKind.arrow,
        Tool.line => QuickKind.line,
        Tool.box || Tool.ellipse || Tool.pen => QuickKind.shape,
        Tool.text => QuickKind.text,
        Tool.callout => QuickKind.callout,
        Tool.step => QuickKind.step,
        Tool.highlight => QuickKind.highlight,
        _ => null,
      };

  static QuickKind? of(Annotation a) => switch (a.shape) {
        ArrowShape() => QuickKind.arrow,
        LineShape() => QuickKind.line,
        RectShape() || EllipseShape() || PenShape() => QuickKind.shape,
        TextShape() => QuickKind.text,
        CalloutShape() => QuickKind.callout,
        StepShape() => QuickKind.step,
        HighlightShape() => QuickKind.highlight,
        _ => null,
      };
}

/// A preset look: color, size and line style, applied in one step.
class QuickStyle {
  final int color; // 0xRRGGBB, as the Swift app stores it
  final StrokeSize size;
  final ArrowStyle style;
  const QuickStyle(this.color, this.size, this.style);

  Color get colorValue => Color(0xFF000000 | color);

  Map<String, Object> toJson() => {'color': color, 'size': size.index, 'style': style.toJson()};

  static QuickStyle? fromJson(Object? j) {
    if (j is! Map || j['color'] is! int) return null;
    final s = j['size'];
    return QuickStyle(j['color'] as int, s is int && s >= 0 && s < 3 ? StrokeSize.values[s] : StrokeSize.medium,
        ArrowStyle.fromJson(j['style']) ?? ArrowStyle.arrow);
  }

  @override
  bool operator ==(Object o) => o is QuickStyle && o.color == color && o.size == size && o.style == style;
  @override
  int get hashCode => Object.hash(color, size, style);
}

/// Built-in looks, one tile each in the current color (the Color row picks the color), plus your saved ones.
class QuickStyles {
  static const _savedKey = 'myQuickStyles';

  static Map<String, List<QuickStyle>> _saved = {};

  static Future<void> load() async {
    final raw = await Native.getDataString(_savedKey);
    if (raw == null) { _saved = {}; return; } // none saved (or removed by defaults applied from another Mac)
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _saved = {
        for (final e in m.entries)
          e.key: [for (final j in (e.value as List)) ?QuickStyle.fromJson(j)],
      };
    } catch (_) {}
  }

  static List<(StrokeSize, ArrowStyle)> _rows(QuickKind kind) => switch (kind) {
        QuickKind.arrow => const [
            (StrokeSize.medium, ArrowStyle(tapered: true)),
            (StrokeSize.medium, ArrowStyle()),
            (StrokeSize.small, ArrowStyle(start: ArrowHead.dot, end: ArrowHead.open, pattern: LinePattern.dashed)),
            (StrokeSize.small, ArrowStyle(start: ArrowHead.bar, end: ArrowHead.triangle)),
            (StrokeSize.medium, ArrowStyle(end: ArrowHead.swept, outline: true)),
            (StrokeSize.medium, ArrowStyle(start: ArrowHead.triangle, end: ArrowHead.triangle)),
            (StrokeSize.large, ArrowStyle(border: true)),   // bold, with a darker edge (route-map style)
          ],
        QuickKind.line => const [
            (StrokeSize.medium, ArrowStyle.line),
            (StrokeSize.small, ArrowStyle(end: ArrowHead.none, pattern: LinePattern.dashed)),
            (StrokeSize.medium, ArrowStyle(end: ArrowHead.none, pattern: LinePattern.dotted)),
            (StrokeSize.small, ArrowStyle(start: ArrowHead.dot, end: ArrowHead.dot)),
            (StrokeSize.large, ArrowStyle(end: ArrowHead.none, border: true)),
          ],
        QuickKind.shape => const [
            (StrokeSize.medium, ArrowStyle.shape),
            (StrokeSize.large, ArrowStyle(end: ArrowHead.none, shadow: true)),
            (StrokeSize.small, ArrowStyle(end: ArrowHead.none, pattern: LinePattern.dashed, shadow: false)),
            (StrokeSize.medium, ArrowStyle(end: ArrowHead.none, pattern: LinePattern.dotted, outline: true, shadow: false)),
          ],
        QuickKind.text || QuickKind.callout || QuickKind.step => const [
            (StrokeSize.small, ArrowStyle.arrow), (StrokeSize.medium, ArrowStyle.arrow), (StrokeSize.large, ArrowStyle.arrow),
          ],
        QuickKind.highlight => const [(StrokeSize.medium, ArrowStyle.arrow)],
      };

  /// Your own saved styles for a kind (newest first).
  static List<QuickStyle> saved(QuickKind kind) => _saved[kind.name] ?? const [];

  /// The built-in looks in [color], built around your own current look (`current` / `size`): the first is
  /// exactly your style, and the others keep their variation (dashes, outline, double ends…) but use your
  /// arrowheads instead of the plain triangle. Text kinds are unchanged.
  static List<QuickStyle> presets(QuickKind kind, {required int color, ArrowStyle? current, StrokeSize? size}) {
    var rows = _rows(kind);
    final usesLines = kind == QuickKind.arrow || kind == QuickKind.line || kind == QuickKind.shape;
    if (current != null && usesLines) {
      ArrowStyle personal(ArrowStyle r) => switch (kind) {
            QuickKind.arrow => r.copyWith(
                end: r.end == ArrowHead.triangle ? current.end : r.end,
                start: r.start == ArrowHead.triangle ? current.end : r.start, // double-ended: your head at both ends
                headSize: current.headSize),
            QuickKind.line => r.copyWith(headSize: current.headSize),
            _ => r,
          };
      rows = [
        (size ?? StrokeSize.medium, current),
        for (final (s, r) in rows)
          if (personal(r) != current) (s, personal(r)),
      ];
    }
    return [for (final (size, style) in rows) QuickStyle(color, size, style)];
  }

  static Future<void> save(QuickStyle q, QuickKind kind) async {
    final list = [q, ...(_saved[kind.name] ?? const <QuickStyle>[]).where((x) => x != q)].take(24).toList();
    _saved[kind.name] = list;
    await _persist();
  }

  static Future<void> clear(QuickKind kind) async {
    _saved.remove(kind.name);
    await _persist();
  }

  static Future<void> _persist() => Native.setDataString(_savedKey,
      jsonEncode({for (final e in _saved.entries) e.key: [for (final q in e.value) q.toJson()]}));
}
