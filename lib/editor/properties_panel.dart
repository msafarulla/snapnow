import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../app/size_chooser.dart';
import '../app/theme.dart';
import '../export/build_up_gif.dart';
import '../model/annotation.dart';
import 'canvas_painter.dart';
import 'quick_styles.dart';

/// What the panel reads from and does to the editor.
abstract class PanelHost {
  Annotation? get selected;
  Tool get tool;
  Color get color;
  StrokeSize get size;
  StyleKind? get styleKind;
  ArrowStyle get currentArrowStyle;
  bool get selectionIsCurved;
  bool get followDrag; // new arrows and lines follow the dragged path
  void setFollowDrag(bool on);
  Entrance get gifEntrance; // how strokes appear: draw on, as string art, or traced by Fourier circles
  void setGifEntrance(Entrance e);
  int get gifMaxSide; // the build-up GIF's longest side in output pixels (S/M/L or custom)
  void setGifMaxSide(int px);
  bool get canPlayEntrance; // the selection can be watched appearing (a line, stroke or outline)
  void playEntrance();
  ShapeKind? get shapeKind; // a box or ellipse (selected, or the Shape tool's choice); null otherwise
  void pickShapeKind(ShapeKind k);
  StepMarker? get stepMarker; // a step's marker (selected, or the Step tool's choice); null otherwise
  void pickStepMarker(StepMarker s);
  CalloutStyle? get calloutStyle; // a callout's bubble (selected, or the Callout tool's choice); null otherwise
  void pickCalloutStyle(CalloutStyle s);
  void pickColor(Color c);
  void openColorPanel();
  void pickSize(StrokeSize s);
  void setArrowStyle(ArrowStyle s);
  void applyQuickStyle(QuickStyle q);
  void straighten();
  void resetStyle();
  void copyAllText();
  void saveCurrentStyle();
  void clearSavedStyles();
  bool get isTextual; // Text or Callout (selected, or the active tool)
  bool get isCallout;
  TextFormat get textFormat;
  void setTextFormat(TextFormat f);
  List<CharStyle> get selectedChars; // highlighted characters while typing
  void styleSelection(CharStyle Function(CharStyle) change);
}

/// The inspector: a floating card on the right with Styles for the current kind, then its properties.
/// It edits the selected annotation when there is one, otherwise the defaults for the active tool.
class PropertiesPanel extends StatelessWidget {
  static const width = 296.0; // wide enough that a tool's options fit without scrolling
  static const colors = <(String, Color)>[
    ('Red', Color(0xFFFF3B30)), ('Orange', Color(0xFFFF9500)), ('Yellow', Color(0xFFFFCC00)), ('Green', Color(0xFF34C759)),
    ('Blue', Color(0xFF007AFF)), ('Purple', Color(0xFFAF52DE)), ('Black', Color(0xFF000000)), ('White', Color(0xFFFFFFFF)),
  ];

  final PanelHost host;
  final VoidCallback? onClose; // hides the card (the toolbar's Inspector button brings it back)
  const PropertiesPanel({super.key, required this.host, this.onClose});

  String get _title {
    final a = host.selected;
    if (a != null) {
      return switch (a.shape) {
        ArrowShape() => 'Arrow', LineShape() => 'Line', RectShape() => 'Rectangle', EllipseShape() => 'Ellipse',
        PenShape() => 'Pen', HighlightShape() => 'Highlight', TextShape() => 'Text', CalloutShape() => 'Callout',
        StepShape() => 'Step', BlurShape() => 'Blur', SpotlightShape() => 'Spotlight', ImageShape() => 'Image',
      };
    }
    return '${_toolLabel(host.tool)} Tool';
  }

  static String _toolLabel(Tool t) => const {
        Tool.select: 'Select', Tool.arrow: 'Arrow', Tool.line: 'Line', Tool.box: 'Shape', Tool.ellipse: 'Shape',
        Tool.pen: 'Pen', Tool.highlight: 'Highlight', Tool.text: 'Text', Tool.callout: 'Callout', Tool.step: 'Step',
        Tool.blur: 'Blur', Tool.spotlight: 'Spotlight', Tool.crop: 'Crop', Tool.grabText: 'Copy Text',
      }[t]!;

  QuickKind? get _kind {
    final a = host.selected;
    return a != null ? QuickKind.of(a) : QuickKind.ofTool(host.tool);
  }

  bool get _usesColor {
    final a = host.selected;
    if (a != null) return a.shape is! BlurShape && a.shape is! SpotlightShape && a.shape is! ImageShape;
    return !const {Tool.select, Tool.blur, Tool.spotlight, Tool.crop, Tool.grabText}.contains(host.tool);
  }

  String get _hint => switch (host.tool) {
        Tool.select => 'Click an annotation to edit it. Drag to move, drag handles to resize, Delete removes it.',
        Tool.blur => 'Drag over anything private to blur it.',
        Tool.spotlight => 'Drag around what matters; everything else is dimmed.',
        Tool.crop => 'Drag the area to keep.',
        Tool.grabText => 'Drag over text to copy it. Table columns become tabs, so grids paste into Excel.',
        _ => host.selected?.shape is ImageShape ? 'Drag to move, corners resize. Flatten All merges it into the image.' : '',
      };

  @override
  Widget build(BuildContext context) {
    final kids = <Widget>[];
    final kind = _kind;

    // Header: what is being edited, the My Styles menu and the close button
    kids.add(Row(children: [
      Expanded(child: _heading(context, _title)),
      if (kind != null)
        PopupMenuButton<String>(
          tooltip: 'My Styles',
          icon: const Icon(Icons.settings_outlined, size: 17),
          iconSize: 17,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onSelected: (v) => v == 'save' ? host.saveCurrentStyle() : host.clearSavedStyles(),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'save', height: 32, child: Text('Save Current Style')),
            PopupMenuItem(value: 'clear', height: 32, child: Text('Clear My Styles for ${_title.replaceAll(' Tool', '')}')),
          ],
        ),
      if (onClose != null) ...[
        const SizedBox(width: 2),
        _IconTap(icon: Icons.close, tooltip: 'Hide the inspector', onTap: onClose!),
      ],
    ]));

    if (kind != null) {
      kids.add(_heading(context, 'Styles', small: true));
      // The built-in styles in the current color, then My Styles (your own saved looks) right below
      final current = QuickStyle(host.color.toARGB32() & 0xFFFFFF, host.size,
          host.styleKind != null ? host.currentArrowStyle : ArrowStyle.arrow);
      bool isCurrent(QuickStyle q) =>
          q.color == current.color && q.size == current.size && (host.styleKind == null || q.style == current.style);
      // Shape tiles show the shape in use (selected, or the tool's): a box, an ellipse or a pen stroke
      final sample = switch (host.selected?.shape) {
        EllipseShape() => Tool.ellipse,
        PenShape() => Tool.pen,
        RectShape() => Tool.box,
        _ => host.tool,
      };
      kids.add(Wrap(spacing: 4, runSpacing: 4, children: [
        for (final q in QuickStyles.presets(kind, color: current.color, current: host.styleKind != null ? host.currentArrowStyle : null, size: host.size))
          _QuickTile(q: q, kind: kind, sample: sample, current: isCurrent(q), onTap: () => host.applyQuickStyle(q)),
      ]));
      final mine = QuickStyles.saved(kind);
      kids.add(_heading(context, 'My Styles', small: true));
      kids.add(Wrap(spacing: 4, runSpacing: 4, children: [
        for (final q in mine) _QuickTile(q: q, kind: kind, sample: sample, current: isCurrent(q), onTap: () => host.applyQuickStyle(q)),
        _AddStyleTile(onTap: host.saveCurrentStyle, saved: mine.any(isCurrent)),
      ]));
      kids.add(_separator(context));
    }

    if (!_usesColor) {
      kids.add(_note(context, _hint));
      if (host.tool == Tool.grabText) {
        kids.add(Align(alignment: Alignment.centerLeft, child: _PillButton(icon: Icons.content_paste, label: 'Copy All Text', onTap: host.copyAllText)));
      }
    } else {
      kids.addAll([
        // Colours are in the bar above the selected annotation (editor_page.dart _ColorBar)
        if (host.shapeKind case final shape?) ...[
          const SizedBox(height: 4),
          _row(context, 'Shape', [
            _Segmented<ShapeKind>(
              values: ShapeKind.values,
              selected: shape,
              label: (k) => k.label,
              glyph: (k) => CustomPaint(size: const Size(16, 14), painter: _ShapeGlyph(k, Theme.of(context).colorScheme.onSurface)),
              tooltip: (k) => k.label,
              onTap: host.pickShapeKind,
            ),
          ]),
        ],
        if (host.calloutStyle case final bubble?) ...[
          const SizedBox(height: 4),
          _row(context, 'Bubble', [
            _Segmented<CalloutStyle>(
              values: CalloutStyle.values,
              selected: bubble,
              itemWidth: 38,
              label: (s) => s.label,
              glyph: (s) => CustomPaint(size: const Size(24, 18), painter: _CalloutGlyph(s, Theme.of(context).colorScheme.onSurface)),
              tooltip: (s) => s.label,
              onTap: host.pickCalloutStyle,
            ),
          ]),
        ],
        if (host.stepMarker case final step?) ...[
          const SizedBox(height: 4),
          _row(context, 'Marker', [
            _Segmented<StepMarker>(
              values: StepMarker.values,
              selected: step,
              itemWidth: 32,
              label: (s) => s.label,
              glyph: (s) => CustomPaint(size: const Size(18, 18), painter: _StepGlyph(s, Theme.of(context).colorScheme.onSurface)),
              tooltip: (s) => s.label,
              onTap: host.pickStepMarker,
            ),
          ]),
        ],
        const SizedBox(height: 4),
        _row(context, 'Size', [
          _Segmented<StrokeSize>(
            values: StrokeSize.values,
            selected: host.size,
            label: (s) => s.label,
            tooltip: (s) => const ['Small', 'Medium', 'Large'][s.index],
            onTap: host.pickSize,
          ),
        ]),
      ]);

      // A selected text/callout gets the floating format bar beside it; here only the tool's defaults
      if (host.isTextual && host.selected == null) kids.addAll(_textSection(context));

      final styleKind = host.styleKind;
      if (styleKind != null) {
        final style = host.currentArrowStyle;
        final isLine = styleKind != StyleKind.shape;
        if (isLine) {
          kids.addAll([
            _separator(context),
            Tooltip(
                message: 'New arrows and lines follow the path you drag, as a smooth curve',
                waitDuration: const Duration(milliseconds: 700),
                child: _check(context, 'Curve: follow my drag', host.followDrag, host.setFollowDrag, indent: false),
              ),
            _heading(context, 'Arrowheads', small: true),
            _row(context, 'Start', [_headMenu(style, start: true)]),
            _row(context, 'End', [
              _headMenu(style, start: false),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Swap Ends',
                icon: const Icon(Icons.swap_horiz, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => host.setArrowStyle(style.copyWith(start: style.end, end: style.start)),
              ),
            ]),
          ]);
        }
        kids.addAll([
          _separator(context),
          _heading(context, 'Line', small: true),
          _row(context, 'Pattern', [
            _Dropdown<LinePattern>(
              value: style.pattern.still,
              items: [for (final p in LinePattern.menu) (p, p.label, StylePreview(ArrowStyle(end: ArrowHead.none, pattern: p), line: isLine))],
              onChanged: (p) => host.setArrowStyle(style.copyWith(pattern: p.marching(style.pattern.marches))),
            ),
          ]),
          if (style.pattern.canMarch)
            Tooltip(
              message: 'The dashes keep running toward the end (in the editor and in GIFs)',
              waitDuration: const Duration(milliseconds: 700),
              child: _check(context, 'Marching', style.pattern.marches,
                  (v) => host.setArrowStyle(style.copyWith(pattern: style.pattern.marching(v)))),
            ),
          _row(context, 'Entrance', [
            Tooltip(
              message: 'How lines, pen strokes and outlines appear in animated GIFs',
              waitDuration: const Duration(milliseconds: 700),
              child: _Segmented<Entrance>(
                values: Entrance.values, selected: host.gifEntrance,
                label: (e) => e.label, tooltip: (e) => e.tip, onTap: host.setGifEntrance, itemWidth: 62),
            ),
          ]),
          if (host.canPlayEntrance)
            Row(children: [
              const Spacer(),
              Tooltip(
                message: 'Watch the selected stroke appear this way',
                child: _PillButton(icon: Icons.play_arrow, label: 'Play', onTap: host.playEntrance),
              ),
            ]),
          _row(context, 'GIF size', [
            Expanded(
              child: Tooltip(
                message: 'The animated GIF\'s longest side in pixels — type the clarity you want',
                waitDuration: const Duration(milliseconds: 700),
                child: SizeChooser(
                  value: host.gifMaxSide,
                  min: BuildUpGif.minMaxSide,
                  max: BuildUpGif.maxMaxSide,
                  onChanged: host.setGifMaxSide,
                ),
              ),
            ),
          ]),
          // One row each, so the whole panel fits without scrolling
          Wrap(spacing: 14, runSpacing: 4, children: [
            if (isLine) _check(context, 'Tapered', style.tapered, (v) => host.setArrowStyle(style.copyWith(tapered: v)), indent: false),
            _check(context, 'Outline', style.outline, (v) => host.setArrowStyle(style.copyWith(outline: v)), indent: false),
            _check(context, 'Shadow', style.shadow, (v) => host.setArrowStyle(style.copyWith(shadow: v)), indent: false),
            Tooltip(
              message: 'A dark edge around the line, with a shine down the middle',
              waitDuration: const Duration(milliseconds: 700),
              child: _check(context, 'Border', style.border, (v) => host.setArrowStyle(style.copyWith(border: v)), indent: false),
            ),
            if (isLine)
              Tooltip(
                message: 'Snake skin: a dark glass tube with glowing scales drifting toward the head (they move in GIFs)',
                waitDuration: const Duration(milliseconds: 700),
                child: _check(context, 'Snake skin', style.snake, (v) => host.setArrowStyle(style.copyWith(snake: v)), indent: false),
              ),
          ]),
          if (style.border || style.outline)
            _row(context, 'Outline\ncolor', [
              Expanded(
                child: Wrap(spacing: 5, runSpacing: 5, children: [
                  for (final (name, c) in [(style.border ? 'Automatic (a dark shade of the line)' : 'Automatic (black or white, whichever contrasts)', null), ...colors])
                    _ColorDot(name: name, color: c, selected: style.borderColor?.toARGB32() == c?.toARGB32(),
                        onTap: () => host.setArrowStyle(style.withBorderColor(c))),
                ]),
              ),
            ]),
          Wrap(spacing: 6, runSpacing: 4, children: [
            if (isLine)
              Tooltip(
                message: 'Remove all bend points (drag a + on the arrow, or double-click it, to bend it)',
                child: _PillButton(icon: Icons.horizontal_rule, label: 'Straighten', onTap: host.selectionIsCurved ? host.straighten : null),
              ),
            _PillButton(icon: Icons.restart_alt, label: 'Reset Style', onTap: host.resetStyle),
          ]),
        ]);
      }
    }

    // A floating card that hugs its content (and scrolls when the window is shorter than it)
    return Container(
      width: width,
      decoration: SnapChrome.of(context).decoration(),
      child: Material(
        type: MaterialType.transparency,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final k in kids) Padding(padding: const EdgeInsets.only(bottom: 6), child: k),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  /// Fonts installed on every Mac (others fall back to the system font).
  static const fonts = <(String, String)>[
    ('', 'System'), ('Helvetica Neue', 'Helvetica Neue'), ('Avenir Next', 'Avenir Next'), ('Futura', 'Futura'),
    ('Georgia', 'Georgia'), ('Times New Roman', 'Times New Roman'), ('Menlo', 'Menlo'), ('Courier New', 'Courier New'),
    ('Marker Felt', 'Marker Felt'), ('Chalkboard SE', 'Chalkboard'),
  ];

  static const textColors = <(String, Color?)>[
    ('Automatic (contrasts with the bubble)', null), ('White', Color(0xFFFFFFFF)), ('Black', Color(0xFF000000)),
    ('Yellow', Color(0xFFFFCC00)), ('Red', Color(0xFFFF3B30)), ('Blue', Color(0xFF007AFF)),
  ];

  /// Font, exact size, bold / italic / underline, alignment, and the callout text colour or the text shadow.
  List<Widget> _textSection(BuildContext context) {
    final f = host.textFormat;
    final sizePt = f.points ?? host.size.fontSize;
    return [
      _separator(context),
      _heading(context, 'Text', small: true),
      _row(context, 'Font', [
        _Dropdown<String>(
          value: f.family,
          items: [
            for (final (family, label) in fonts)
              (family, label, Text('Aa', style: TextStyle(fontFamily: family.isEmpty ? null : family, fontSize: 14, fontWeight: FontWeight.w600))),
          ],
          onChanged: (v) => host.setTextFormat(f.copyWith(family: v)),
        ),
      ]),
      _row(context, 'Points', [
        _Stepper(
          value: sizePt,
          onChanged: (v) => host.setTextFormat(f.withPoints(v.clamp(8, 200).toDouble())),
        ),
      ]),
      _row(context, 'Style', [
        _Toggle(icon: Icons.format_bold, tooltip: 'Bold', on: f.bold, onTap: () => host.setTextFormat(f.copyWith(bold: !f.bold))),
        const SizedBox(width: 4),
        _Toggle(icon: Icons.format_italic, tooltip: 'Italic', on: f.italic, onTap: () => host.setTextFormat(f.copyWith(italic: !f.italic))),
        const SizedBox(width: 4),
        _Toggle(icon: Icons.format_underlined, tooltip: 'Underline', on: f.underline,
            onTap: () => host.setTextFormat(f.copyWith(underline: !f.underline))),
      ]),
      _row(context, 'Align', [
        for (final (align, icon, tip) in const [
          (TextAlign.left, Icons.format_align_left, 'Left'),
          (TextAlign.center, Icons.format_align_center, 'Centre'),
          (TextAlign.right, Icons.format_align_right, 'Right'),
        ]) ...[
          _Toggle(icon: icon, tooltip: tip, on: f.align == align, onTap: () => host.setTextFormat(f.copyWith(align: align))),
          const SizedBox(width: 4),
        ],
      ]),
      if (host.isCallout)
        _row(context, 'Text colour', [
          Wrap(spacing: 5, children: [
            for (final (name, c) in textColors)
              _ColorDot(name: name, color: c, selected: f.textColor?.toARGB32() == c?.toARGB32(),
                  onTap: () => host.setTextFormat(f.withTextColor(c))),
          ]),
        ])
      else
        _check(context, 'Shadow', f.shadow, (v) => host.setTextFormat(f.copyWith(shadow: v))),
    ];
  }

  Widget _headMenu(ArrowStyle style, {required bool start}) => _Dropdown<Object>(
        value: start ? style.start : style.end,
        checked: (v) => v == style.headSize,
        items: headChoices(style, start: start),
        onChanged: (v) => host.setArrowStyle(v is HeadSize
            ? style.copyWith(headSize: v)
            : start ? style.copyWith(start: v as ArrowHead) : style.copyWith(end: v as ArrowHead)),
      );

  /// A head menu: the arrowheads, then the head sizes (the size applies to both ends).
  static List<(Object, String, Widget?)> headChoices(ArrowStyle style, {required bool start}) => [
        for (final h in ArrowHead.values)
          (h, h.label, StylePreview(start
              ? ArrowStyle(start: h, end: ArrowHead.none, headSize: style.headSize)
              : ArrowStyle(start: ArrowHead.none, end: h, headSize: style.headSize))),
        for (final h in HeadSize.values) (h, '${h.label} head', StylePreview(ArrowStyle(end: ArrowHead.triangle, headSize: h))),
      ];

  /// Menu rows with a divider where the kind of choice changes; `checked` ticks a second current choice.
  static List<PopupMenuEntry<T>> menuEntries<T>(List<(T, String, Widget?)> items, bool Function(T)? checked) => [
        for (var n = 0; n < items.length; n++) ...[
          if (n > 0 && items[n].$1.runtimeType != items[n - 1].$1.runtimeType) const PopupMenuDivider(height: 9),
          PopupMenuItem<T>(value: items[n].$1, height: 30, child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (items[n].$3 != null) ...[SizedBox(width: 48, height: 18, child: items[n].$3), const SizedBox(width: 8)],
            Flexible(child: Text(items[n].$2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
            if (checked?.call(items[n].$1) ?? false) ...[const SizedBox(width: 8), const Icon(Icons.check, size: 14)],
          ])),
        ],
      ];

  static Widget _heading(BuildContext context, String text, {bool small = false}) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(top: small ? 2 : 0),
      child: Text(small ? text.toUpperCase() : text,
          style: TextStyle(fontSize: small ? 10.5 : 13.5, fontWeight: FontWeight.w600, letterSpacing: small ? 0.6 : -0.2,
              color: small ? s.onSurfaceVariant : s.onSurface)),
    );
  }

  static Widget _note(BuildContext context, String text) =>
      Text(text, style: TextStyle(fontSize: 12, height: 1.35, color: Theme.of(context).colorScheme.onSurfaceVariant));

  static Widget _row(BuildContext context, String label, List<Widget> children) => Row(children: [
        SizedBox(width: 64, child: Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
        ...children,
      ]);

  static Widget _separator(BuildContext context) =>
      Divider(height: 10, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant);

  static Widget _check(BuildContext context, String label, bool value, ValueChanged<bool> onChanged, {bool indent = true}) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => onChanged(!value),
        child: Row(mainAxisSize: indent ? MainAxisSize.max : MainAxisSize.min, children: [
          if (indent) const SizedBox(width: 60),
          SizedBox(width: 22, height: 22, child: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12.5)),
        ]),
      );
}

/// A compact popup menu showing a preview + label for each choice.
class _Dropdown<T> extends StatelessWidget {
  final T value;
  final List<(T, String, Widget?)> items;
  final ValueChanged<T> onChanged;
  final double width;
  final bool Function(T)? checked; // a second ticked choice (the head size in a head menu)
  const _Dropdown({required this.value, required this.items, required this.onChanged, this.width = 152, this.checked});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final current = items.firstWhere((i) => i.$1 == value, orElse: () => items.first);
    Widget entry((T, String, Widget?) i) => Row(mainAxisSize: MainAxisSize.min, children: [
          if (i.$3 != null) ...[SizedBox(width: 48, height: 18, child: i.$3), const SizedBox(width: 8)],
          Flexible(child: Text(i.$2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
        ]);
    return PopupMenuButton<T>(
      tooltip: '',
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => PropertiesPanel.menuEntries(items, checked),
      child: Container(
        width: width,
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: SnapChrome.of(context).controlBox(),
        child: Row(children: [
          Expanded(child: entry(current)),
          Icon(Icons.unfold_more, size: 14, color: s.onSurfaceVariant),
        ]),
      ),
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final String Function(T) tooltip;
  final Widget Function(T)? glyph; // shown instead of the label
  final ValueChanged<T> onTap;
  final double itemWidth;
  const _Segmented({required this.values, required this.selected, required this.label, required this.tooltip, required this.onTap,
      this.glyph, this.itemWidth = 42});

  @override
  Widget build(BuildContext context) {
    final chrome = SnapChrome.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: chrome.controlBox(radius: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final v in values)
          Tooltip(
            message: tooltip(v),
            child: GestureDetector(
              onTap: () => onTap(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: itemWidth, height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: v == selected ? chrome.raised : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: v == selected ? const [BoxShadow(color: Color(0x26000000), blurRadius: 2, offset: Offset(0, 1))] : null,
                ),
                child: glyph?.call(v) ??
                    Text(label(v), style: TextStyle(fontSize: 12, fontWeight: v == selected ? FontWeight.w600 : FontWeight.w400)),
              ),
            ),
          ),
      ]),
    );
  }
}

/// The compact format card shown beside a text or callout while it is selected or being typed into.
class TextFormatBar extends StatelessWidget {
  static const width = 262.0;
  final PanelHost host;
  const TextFormatBar({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    final f = host.textFormat;
    final sizePt = f.points ?? host.size.fontSize;
    Widget gap([double w = 4]) => SizedBox(width: w);
    final chars = host.selectedChars;
    bool all(bool Function(CharStyle c) on) => chars.isNotEmpty && chars.every(on);
    final bold = all((c) => c.bold ?? f.bold), italic = all((c) => c.italic ?? f.italic);
    final underline = all((c) => c.underline ?? f.underline);
    final colors = {for (final c in chars) c.color?.toARGB32()};
    final selectedColor = colors.length == 1 ? colors.first : -1; // -1: mixed
    CharStyle withBold(CharStyle c, bool v) => (color: c.color, bold: v, italic: c.italic, underline: c.underline);
    CharStyle withItalic(CharStyle c, bool v) => (color: c.color, bold: c.bold, italic: v, underline: c.underline);
    CharStyle withUnderline(CharStyle c, bool v) => (color: c.color, bold: c.bold, italic: c.italic, underline: v);
    CharStyle withColor(CharStyle c, Color? v) => (color: v, bold: c.bold, italic: c.italic, underline: c.underline);
    return Container(
      width: width,
      padding: const EdgeInsets.all(8),
      decoration: SnapChrome.of(context).decoration(radius: 12),
      child: Material(
        type: MaterialType.transparency,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _Dropdown<String>(
              width: 128,
              value: f.family,
              items: [
                for (final (family, label) in PropertiesPanel.fonts)
                  (family, label, Text('Aa', style: TextStyle(fontFamily: family.isEmpty ? null : family, fontSize: 14, fontWeight: FontWeight.w600))),
              ],
              onChanged: (v) => host.setTextFormat(f.copyWith(family: v)),
            ),
            gap(6),
            _Stepper(value: sizePt, onChanged: (v) => host.setTextFormat(f.withPoints(v.clamp(8, 200).toDouble()))),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            _Toggle(icon: Icons.format_bold, tooltip: 'Bold', on: bold, onTap: () => host.styleSelection((c) => withBold(c, !bold))),
            gap(),
            _Toggle(icon: Icons.format_italic, tooltip: 'Italic', on: italic, onTap: () => host.styleSelection((c) => withItalic(c, !italic))),
            gap(),
            _Toggle(icon: Icons.format_underlined, tooltip: 'Underline', on: underline,
                onTap: () => host.styleSelection((c) => withUnderline(c, !underline))),
            gap(12),
            for (final (align, icon, tip) in const [
              (TextAlign.left, Icons.format_align_left, 'Align left'),
              (TextAlign.center, Icons.format_align_center, 'Centre'),
              (TextAlign.right, Icons.format_align_right, 'Align right'),
            ]) ...[
              _Toggle(icon: icon, tooltip: tip, on: f.align == align, onTap: () => host.setTextFormat(f.copyWith(align: align))),
              gap(),
            ],
          ]),
          const SizedBox(height: 6),
          Row(children: [
            for (final (name, c) in PropertiesPanel.textColors) ...[
              _ColorDot(
                name: c == null ? (host.isCallout ? name : 'Same as the text colour') : name,
                color: c,
                selected: selectedColor == c?.toARGB32(),
                onTap: () => host.styleSelection((ch) => withColor(ch, c)),
              ),
              gap(5),
            ],
            if (!host.isCallout) ...[
              const Spacer(),
              _Toggle(icon: Icons.blur_on, tooltip: 'Shadow behind the text', on: f.shadow,
                  onTap: () => host.setTextFormat(f.copyWith(shadow: !f.shadow))),
            ],
          ]),
        ]),
      ),
    );
  }
}

/// A round colour choice; `color` null = automatic (half white, half black).
class _ColorDot extends StatelessWidget {
  final String name;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorDot({required this.name, required this.color, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: name,
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 20, height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            gradient: color == null ? const LinearGradient(colors: [Colors.white, Colors.white, Colors.black, Colors.black],
                stops: [0, 0.5, 0.5, 1], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: selected ? [BoxShadow(color: scheme.primary, spreadRadius: 2.5), BoxShadow(color: scheme.surface, spreadRadius: 1)] : null,
          ),
        ),
      ),
    );
  }
}

/// A square on/off button (bold, italic, alignment…).
class _Toggle extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool on;
  final VoidCallback onTap;
  const _Toggle({required this.icon, required this.tooltip, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 30, height: 28,
          decoration: BoxDecoration(
            color: on ? s.primary.withValues(alpha: 0.16) : SnapChrome.of(context).control,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? s.primary : SnapChrome.of(context).controlBorder, width: 0.8),
          ),
          child: Icon(icon, size: 17, color: on ? s.primary : s.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// − value + for the exact point size; the value can also be typed.
class _Stepper extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const _Stepper({required this.value, required this.onChanged});
  @override
  State<_Stepper> createState() => _StepperState();
}

class _StepperState extends State<_Stepper> {
  late final _c = TextEditingController(text: _fmt(widget.value));
  static String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  @override
  void didUpdateWidget(covariant _Stepper old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _c.text = _fmt(widget.value);
  }

  void _submit(String t) {
    final v = double.tryParse(t.trim());
    if (v != null) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    Widget btn(IconData i, double d) => InkWell(
          onTap: () => widget.onChanged(widget.value + d),
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(width: 26, height: 28, child: Icon(i, size: 16, color: s.onSurfaceVariant)),
        );
    return Container(
      height: 28,
      decoration: SnapChrome.of(context).controlBox(),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn(Icons.remove, -2),
        SizedBox(
          width: 40,
          child: TextField(
            controller: _c,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5),
            decoration: const InputDecoration.collapsed(hintText: ''),
            keyboardType: TextInputType.number,
            onSubmitted: _submit,
            onTapOutside: (_) => _submit(_c.text),
          ),
        ),
        btn(Icons.add, 2),
        Padding(padding: const EdgeInsets.only(right: 6), child: Text('pt', style: TextStyle(fontSize: 11, color: s.onSurfaceVariant))),
      ]),
    );
  }
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _PillButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        backgroundColor: SnapChrome.of(context).control,
        side: BorderSide(color: SnapChrome.of(context).controlBorder, width: 0.8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
  }
}

/// A small flat icon button (the card's close button).
class _IconTap extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconTap({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(width: 24, height: 24, child: Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
}

/// A Quick Style tile, drawn with the real renderer (arrows point down-left), as in the Swift app.
class _QuickTile extends StatefulWidget {
  final QuickStyle q;
  final QuickKind kind;
  final Tool sample; // which shape a shape tile draws
  final bool current; // matches the style in use: outlined
  final VoidCallback onTap;
  const _QuickTile({required this.q, required this.kind, required this.onTap, this.sample = Tool.box, this.current = false});
  @override
  State<_QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends State<_QuickTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 50, height: 41,
          decoration: BoxDecoration(
            color: _hover ? Theme.of(context).colorScheme.surfaceContainerHighest : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: widget.current ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5) : null,
          ),
          child: CustomPaint(painter: _TilePainter(widget.q, widget.kind, widget.sample)),
        ),
      ),
    );
  }
}

/// "+": saves the current colour, size and line style to My Styles.
class _AddStyleTile extends StatelessWidget {
  final VoidCallback onTap;
  final bool saved; // the current style is already in My Styles
  const _AddStyleTile({required this.onTap, required this.saved});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Tooltip(
      message: saved ? 'This style is already in My Styles' : 'Save the current style to My Styles',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: saved ? null : onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 50, height: 41,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: s.outlineVariant, width: 1.2),
          ),
          child: Icon(saved ? Icons.check : Icons.add, size: 18, color: s.onSurfaceVariant.withValues(alpha: saved ? 0.5 : 1)),
        ),
      ),
    );
  }
}

/// A small outline of a rectangle, square, ellipse or circle for the Shape picker.
class _ShapeGlyph extends CustomPainter {
  final ShapeKind kind;
  final Color color;
  _ShapeGlyph(this.kind, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = kind.even ? size.height : size.width;
    final r = Rect.fromCenter(center: size.center(Offset.zero), width: w - 2, height: size.height - (kind.even ? 2 : 4));
    final p = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5;
    kind.oval ? canvas.drawOval(r, p) : canvas.drawRect(r, p);
  }

  @override
  bool shouldRepaint(covariant _ShapeGlyph old) => old.kind != kind || old.color != color;
}

/// A small outline of a callout bubble (with its pointer) for the Bubble picker.
class _CalloutGlyph extends CustomPainter {
  final CalloutStyle style;
  final Color color;
  _CalloutGlyph(this.style, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTWH(2, 1, size.width - 4, size.height * 0.68);
    final path = CanvasPainter.calloutPath(box, Offset(size.width * 0.3, size.height - 0.5), 7, style: style);
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.2..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _CalloutGlyph old) => old.style != style || old.color != color;
}

/// A small outline of a step marker for the Marker picker.
class _StepGlyph extends CustomPainter {
  final StepMarker style;
  final Color color;
  _StepGlyph(this.style, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final d = style == StepMarker.pin ? size.height * 0.62 : size.height * 0.72;
    final c = size.center(Offset.zero) - (style == StepMarker.pin ? Offset(0, size.height * 0.16) : Offset.zero);
    canvas.drawPath(CanvasPainter.stepPath(c, d, style), Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.4..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _StepGlyph old) => old.style != style || old.color != color;
}

class _TilePainter extends CustomPainter {
  final QuickStyle q;
  final QuickKind kind;
  final Tool sample;
  _TilePainter(this.q, this.kind, this.sample);

  @override
  void paint(Canvas canvas, Size size) {
    const w = 90.0, h = 72.0;
    final k = math.min(size.width / w, size.height / h);
    canvas.translate((size.width - w * k) / 2, (size.height - h * k) / 2);
    canvas.scale(k);
    Annotation ann(Shape s) => Annotation(id: 0, shape: s, color: q.colorValue, size: q.size, arrowStyle: q.style);
    switch (kind) {
      case QuickKind.arrow || QuickKind.line:
        CanvasPainter.drawAnnotation(canvas, ann(const ArrowShape(Offset(w - 14, 12), Offset(16, h - 12))));
      case QuickKind.shape:
        const r = Rect.fromLTWH(14, 12, w - 28, h - 24);
        CanvasPainter.drawAnnotation(canvas, ann(switch (sample) {
          Tool.ellipse => const EllipseShape(r),
          Tool.pen => PenShape([for (var i = 0; i <= 24; i++) Offset(14 + i * (w - 28) / 24, h / 2 - math.sin(i / 24 * 2 * math.pi) * 14)]),
          _ => const RectShape(r),
        }));
      case QuickKind.highlight:
        final bar = Paint()..color = const Color(0xFF8C8C8C);
        for (final (i, bw) in [w - 28, w - 40, w - 34].indexed) {
          canvas.drawRRect(RRect.fromRectXY(Rect.fromLTWH(14, 18 + i * 14.0, bw, 6), 3, 3), bar);
        }
        CanvasPainter.drawAnnotation(canvas, ann(const HighlightShape(Rect.fromLTWH(10, 28, w - 20, 18))));
      case QuickKind.step:
        CanvasPainter.drawAnnotation(canvas, ann(const StepShape(Offset(w / 2, h / 2))), number: 1);
      case QuickKind.text || QuickKind.callout:
        final fs = q.size.fontSize;
        final origin = Offset(w / 2 - fs * 0.62, h / 2 - fs * 0.62);
        CanvasPainter.drawAnnotation(canvas, ann(kind == QuickKind.text ? TextShape('Aa', origin) : CalloutShape('Aa', origin, tail: const Offset(14, h - 6))));
    }
  }

  @override
  bool shouldRepaint(covariant _TilePainter old) => old.q != q || old.kind != kind || old.sample != sample;
}
