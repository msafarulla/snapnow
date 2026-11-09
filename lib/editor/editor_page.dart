import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:window_manager/window_manager.dart';
import '../app/app_controller.dart';
import '../app/theme.dart';
import '../export/build_up_gif.dart';
import '../export/epicycles.dart';
import '../model/annotation.dart';
import '../model/markup_file.dart';
import '../platform/native.dart';
import 'canvas_painter.dart';
import 'curve_fit.dart';
import '../excalidraw/excalidraw_page.dart';
import '../export/manim_scene.dart';
import '../manim/from_capture.dart';
import '../manim/manim_studio_page.dart';
import 'properties_panel.dart';
import 'quick_styles.dart';
import 'snapping.dart';

class EditorPage extends StatefulWidget {
  /// Room the host keeps covered by its own floating chrome (the Library's filmstrip at the bottom): the
  /// picture is fitted and centred in what's left, so nothing hides under it.
  final EdgeInsets chromeInsets;
  /// An optional first group in the floating toolbar (the Library's back button).
  final Widget? leading;
  /// Draw mode (double-tap Option): the window is a borderless, display-sized overlay and the picture is the frozen
  /// screen at 1:1 from the top-left corner, so it reads as the real screen; the chrome floats over it.
  final bool overlay;
  const EditorPage({super.key, this.chromeInsets = EdgeInsets.zero, this.leading, this.overlay = false});
  @override
  State<EditorPage> createState() => EditorPageState();
}

class EditorPageState extends State<EditorPage> implements PanelHost {
  CanvasState? _state;
  String? _path; // file on disk this canvas came from; Save writes back to it
  final _undo = <CanvasState>[];
  final _redo = <CanvasState>[];
  int _nextId = 1;

  Tool _tool = Tool.arrow;
  Color _color = const Color(0xFFE8332A);
  StrokeSize _size = StrokeSize.medium;
  int? _selection;
  /// Same-shape peers selected alongside _selection (⌘A with an element selected). Move, restyle and delete
  /// apply to the anchor and these together. Empty for an ordinary single selection.
  final Set<int> _group = {};
  /// The editor's own clipboard for shapes (Cut/Copy/Paste/Duplicate), separate from the system clipboard
  /// that ⌘C uses for the image.
  List<Annotation> _clip = const [];
  final _canvasKey = GlobalKey();
  final _focus = FocusNode(debugLabel: "editor"); // keyboard shortcuts go to the editor, not the hidden Library grid
  bool _editingDims = false; // the W×H fields under the image have focus: let them keep Backspace etc.
  Size? _originalSize; // the image's dimensions when the document was created/opened (for "fit to original")
  int? _imageBytes; // the current base image's PNG size, shown after the W×H readout
  ui.Image? _bytesImage; // which image _imageBytes was measured for, so edits that don't touch it skip the work

  void focus() => _focus.requestFocus();

  @visibleForTesting
  double get debugViewScale => _viewScale; // on-screen points per image pixel (x)
  @visibleForTesting
  double get debugViewScaleY => _viewScaleY; // on-screen points per image pixel (y)
  @visibleForTesting
  Size? get debugOriginalSize => _originalSize;
  @visibleForTesting
  Future<void> scaleCanvasTo(int w, int h) => _scaleCanvasTo(w, h);

  /// Measures the current base image's encoded (PNG) size for the readout, off the build. Cheap to call on
  /// every commit: it skips when the image object is the same one already measured.
  Future<void> _refreshImageBytes() async {
    final img = _state?.image;
    if (img == null || identical(img, _bytesImage)) return;
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted || !identical(_state?.image, img)) return;
    setState(() { _bytesImage = img; _imageBytes = data?.lengthInBytes; });
  }

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(b < 10 * 1024 ? 1 : 0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // In-place typing for Text and Callout: the annotation being typed into, and the state before (for undo/cancel)
  ({int id, CanvasState before, bool isNew})? _textEdit;
  final _textController = _RichTextController();
  String _lastText = ''; // to move formatting runs along with each edit
  final _textFocus = FocusNode(debugLabel: 'text');
  DateTime _lastDown = DateTime(0); // double-click detection on the canvas
  Offset _lastDownPoint = Offset.zero;

  // Active gesture
  Offset? _createStart;
  Offset? _createCurrent;
  // Interactive crop: a pending region (image coords) you adjust with dotted handles, then Enter/double-click
  // applies it (Esc cancels). Null when the Crop tool isn't mid-crop.
  Rect? _cropRect;
  int? _cropHandle; // which rect handle is dragging (0–7), -1 to move the whole rect, null when not dragging
  Offset? _cropGrab; // last pointer position while moving the rect
  int? _cropHover; // handle under the cursor (0–7), -1 inside the rect, null otherwise — drives the resize cursor
  List<Offset>? _penPoints;
  List<Offset>? _trail; // the path dragged so far, when the Arrow / Line tool follows the drag

  /// Curve: new arrows and lines follow the path you drag instead of going straight (remembered).
  bool _followDrag = true; // on unless turned off: a curved drag makes a curve
  int? _dragId;
  int? _resizeHandle; // null => move
  Offset _lastPoint = Offset.zero;
  (Rect, Offset)? _imageMove; // a dragged image overlay: its rect and the pointer when the drag began
  List<Guide> _guides = const []; // where that image lines up with the canvas or the other images
  (int, Offset)? _pendingBend; // a "+" handle grabbed: (stretch, where) — becomes a bend point when dragged
  CanvasState? _gestureSnapshot;

  static const _palette = [
    Color(0xFFE8332A), Color(0xFF56B947), Color(0xFF3B8EEA), Color(0xFFF5D33A),
    Color(0xFFFF7A00), Color(0xFF8E44EF), Color(0xFF1E1E1E), Color(0xFFFFFFFF),
  ];

  /// Remembered style per kind, shared with the Swift app (UserDefaults "style.arrow|line|shape").
  final _styleDefaults = <StyleKind, ArrowStyle>{};

  /// Toolbar tools from Settings › Toolbar (Swift raw values), in the Swift app's toolbar order.
  static const _swiftTool = [Tool.select, Tool.arrow, Tool.line, Tool.box, Tool.ellipse, Tool.pen, Tool.highlight,
    Tool.text, Tool.callout, Tool.step, Tool.blur, Tool.spotlight, Tool.crop, Tool.grabText];
  // One Shape button covers Box and Ellipse (pick rectangle, square, ellipse or circle in the panel)
  static const _toolOrder = [Tool.select, Tool.arrow, Tool.text, Tool.callout, Tool.box, Tool.line,
    Tool.pen, Tool.step, Tool.highlight, Tool.blur, Tool.spotlight, Tool.crop];
  static const _defaultTools = {Tool.select, Tool.arrow, Tool.text, Tool.callout, Tool.box, Tool.step, Tool.highlight,
    Tool.blur, Tool.crop};
  Set<Tool> _visibleTools = _defaultTools;
  ShapeKind _shapeKind = ShapeKind.rectangle;

  @override
  void initState() {
    super.initState();
    _makeBlankCanvas(1200, 800);
    _loadPrefs();
    Native.getBool('followDrag').then((on) { if (mounted && on != null) setState(() => _followDrag = on); });
    Native.getString('gifEntrance').then((v) async {
      var e = Entrance.values.where((e) => e.name == v).firstOrNull;
      e ??= (await Native.getBool('gifFourier')) == true ? Entrance.fourier : null; // the older on/off setting
      if (mounted && e != null) setState(() => BuildUpGif.entrance = e!);
    });
    Native.getString('gifMaxSide').then((v) { final n = int.tryParse(v ?? ''); if (mounted && n != null) setState(() => BuildUpGif.setMaxSide(n)); });
    Native.getBool('pinOnTop').then((on) { if (on == true && !_pinTouched) _setPinned(true, save: false); });
    Native.getBool('inspector.hidden').then((hidden) { if (mounted && hidden == true) setState(() => _inspectorShown = false); });
    Native.getBool('toolbar.left').then((left) { if (mounted && left != null) setState(() => toolbarLeft.value = left); });
    Native.getString('callout.style').then((v) {
      final s = CalloutStyle.values.where((s) => s.name == v).firstOrNull;
      if (mounted && s != null) setState(() => _calloutStyle = s);
    });
    Native.getString('step.style').then((v) {
      final s = StepMarker.values.where((s) => s.name == v).firstOrNull;
      if (mounted && s != null) setState(() => _stepMarker = s);
    });
    _textController.addListener(_textChanged);
    Native.onColorPicked = (rgb) => pickColor(Color(0xFF000000 | rgb), refresh: false);
  }

  Future<void> _loadPrefs() async {
    for (final k in StyleKind.values) {
      final raw = await Native.getDataString('style.${k.name}');
      if (raw == null) continue;
      try {
        final s = ArrowStyle.fromJson(jsonDecode(raw));
        if (s != null) _styleDefaults[k] = s;
      } catch (_) {}
    }
    for (final kind in ['text', 'callout']) {
      final raw = await Native.getDataString('style.textFormat.$kind');
      if (raw == null) continue;
      try {
        final f = TextFormat.fromJson(jsonDecode(raw));
        if (f != null) _textFormats[kind] = f;
      } catch (_) {}
    }
    final raw = await Native.toolbarTools();
    if (raw != null) {
      _visibleTools = {for (final i in raw) if (i >= 0 && i < _swiftTool.length) _swiftTool[i]};
      if (_visibleTools.contains(Tool.ellipse)) _visibleTools.add(Tool.box); // the Shape button
    }
    await QuickStyles.load();
    if (mounted) setState(() {});
  }

  ArrowStyle _styleFor(StyleKind k) => _styleDefaults[k] ?? k.builtIn;

  /// Remembered text formats for the Text and Callout tools ("text" / "callout").
  final _textFormats = <String, TextFormat>{};
  TextFormat _formatFor(String kind) => _textFormats[kind] ?? const TextFormat();
  static String _textKind(Annotation a) => a.shape is CalloutShape ? 'callout' : 'text';

  double get _density => _state?.density ?? 1;

  Future<void> _makeBlankCanvas(int w, int h) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    final img = await recorder.endRecording().toImage(w, h);
    setState(() => _state = _savedState = CanvasState(image: img));
    _originalSize = Size(w.toDouble(), h.toDouble());
    _refreshImageBytes();
  }

  void _commit(CanvasState next, {bool snapshot = true}) {
    if (snapshot && _state != null) {
      _undo.add(_state!);
      _redo.clear();
    }
    _clearCopied(); // any edit ends the "copied" marching ants
    setState(() => _state = next);
    _refreshImageBytes();
  }

  CanvasState? _savedState; // the state last opened or saved

  /// Edits since the file was opened or last saved.
  bool get hasUnsavedChanges => _state != null && !identical(_state, _savedState);

  /// Esc while the copied GIF is playing: closes just the preview (true), not the window.
  bool closeGifPreview() {
    if (_gifPreview == null) return false;
    setState(() => _gifPreview = null);
    return true;
  }
  String? get path => _path;
  @visibleForTesting
  CanvasState? get state => _state;

  void _undoAction() {
    if (_textEdit != null) return _endTextEdit(cancel: true);
    if (_undo.isEmpty || _state == null) return;
    _redo.add(_state!);
    setState(() { _state = _undo.removeLast(); _selection = null; _group.clear(); });
  }

  void _redoAction() {
    if (_redo.isEmpty || _state == null) return;
    _undo.add(_state!);
    setState(() { _state = _redo.removeLast(); _selection = null; _group.clear(); });
  }

  Annotation? _annotation(int? id) => _state?.annotations.where((a) => a.id == id).firstOrNull;

  // ---- Image selection and copy feedback (as in the Swift app) ----

  /// The whole image is selected (Select tool click on empty canvas, or ⌘A): dashed border + square handles.
  bool _imageSelected = false;
  /// After Copy, "marching ants" run around the image until the next edit or click.
  bool _copied = false;
  /// The GIF ⇧⌘C just copied, playing over the canvas until clicked away.
  Uint8List? _gifPreview;
  final _ants = ValueNotifier<double>(0);

  /// Pin keeps the window above other apps (⌥⌘T); remembered between launches.
  bool _pinned = false;
  bool _pinTouched = false; // a click before the saved setting loads wins

  void _setPinned(bool on, {bool save = true}) {
    if (!mounted) return;
    if (save) _pinTouched = true;
    setState(() => _pinned = on);
    windowManager.setAlwaysOnTop(on);
    if (save) Native.setBool('pinOnTop', on);
  }
  Timer? _antsTimer;
  /// Marching Ants lines run while any annotation uses them (one dash cycle every 0.8 s).
  final _march = ValueNotifier<double>(0);
  Timer? _marchTimer;
  /// Play: the annotation being watched appearing (drawn on, as the string art of its tangents or traced by Fourier circles),
  /// and how far (0…1).
  int? _playId;
  double _playT = 1;
  Timer? _playTimer;
  /// Resizing the canvas by its square handles: handle index, new rect (image coords), grab offset.
  (int, Rect, Offset)? _canvasDrag;
  double _viewScale = 1; // view points per image point (x), from the last layout
  double _viewScaleY = 1; // view points per image point (y); differs from _viewScale after a non-proportional resize

  // ---- Zoom and pan ----
  // One transform maps the canvas area to the image: view = origin + image * scale. Fit picks the scale
  // (and centres) unless the user zoomed; pinch, ⌘-wheel and ⌘+/− keep the point under the pointer fixed.

  double? _zoom; // view points per image point; null = fit to window
  Offset _pan = Offset.zero; // origin offset from the centred position, while zoomed
  Offset _viewOrigin = Offset.zero; // from the last layout
  Size _viewSize = Size.zero;
  EdgeInsets _viewInsets = EdgeInsets.zero; // the canvas area under floating chrome (toolbar, inspector, filmstrip)

  // ---- Floating chrome ----

  static const _chromeMargin = 10.0; // between a floating card and the window edge / another card
  static const _toolbarHeight = 52.0;
  /// The toolbar card's width when it stands on the left: one button plus the card padding.
  static const _toolbarLeftWidth = _ToolButton.width + _ToolbarCard.padding * 2;
  /// Where the toolbar card sits: across the top (default) or down the left edge (pref `toolbar.left`,
  /// toggled from View › Move Toolbar to Left/Top or the card's own right-click menu).
  static final toolbarLeft = ValueNotifier<bool>(false);
  bool get _toolbarLeft => toolbarLeft.value;
  bool _inspectorShown = true; // the properties card on the right (Settings persist it as inspector.hidden)

  void _toggleToolbarSide() => _setToolbarLeft(!toolbarLeft.value);

  void _setToolbarLeft(bool left) {
    if (left == toolbarLeft.value) return;
    setState(() => toolbarLeft.value = left);
    Native.setBool('toolbar.left', left);
  }

  // ---- Dragging the toolbar to another edge (by its grip) ----
  final _chromeKey = GlobalKey(); // the Stack the floating cards sit in: the drag's coordinate space
  Offset? _toolbarDragAt; // the pointer, in that Stack, while the grip is being dragged
  bool? _toolbarDropLeft; // the dock under the pointer: true = left edge, false = top, null = neither
  static const _dockReach = 160.0; // how close to an edge the pointer must come to dock there

  void _toolbarDragTo(Offset global) {
    final box = _chromeKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final p = box.globalToLocal(global);
    // Nearer the left edge than the top, and close to it → left; close to the top → top; else nowhere
    final bool? dock = p.dx < _dockReach && p.dx < p.dy ? true : p.dy < _dockReach ? false : null;
    setState(() { _toolbarDragAt = p; _toolbarDropLeft = dock; });
  }

  void _toolbarDragEnd() {
    final dock = _toolbarDropLeft;
    setState(() { _toolbarDragAt = null; _toolbarDropLeft = null; });
    if (dock != null) _setToolbarLeft(dock);
  }

  /// The toolbar card's right-click menu: move it to the other edge.
  Future<void> _showToolbarMenu(Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPos & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'side', height: 32, child: Row(children: [
          Icon(_toolbarLeft ? Icons.vertical_align_top : Icons.align_horizontal_left, size: 17), const SizedBox(width: 10),
          Text(_toolbarLeft ? 'Move Toolbar to Top' : 'Move Toolbar to Left', style: const TextStyle(fontSize: 13)),
        ])),
      ],
    );
    if (sel == 'side') _toggleToolbarSide();
  }

  void _toggleInspector() {
    setState(() => _inspectorShown = !_inspectorShown);
    Native.setBool('inspector.hidden', !_inspectorShown);
  }

  /// Where the floating chrome sits over the canvas area, so the picture is fitted and centred in the rest.
  EdgeInsets get _chromeInsets => widget.overlay ? EdgeInsets.zero : widget.chromeInsets + EdgeInsets.only(
        top: _toolbarLeft ? 0 : _toolbarHeight + _chromeMargin * 2,
        left: _toolbarLeft ? _toolbarLeftWidth + _chromeMargin * 2 : 0,
        right: _inspectorShown ? PropertiesPanel.width + _chromeMargin * 2 : 0,
      );

  /// The centred origin for an image of [size] at [scale], inside the chrome insets (shared by fit and zoom).
  Offset _centredOrigin(Size size, double scaleX, double scaleY) {
    final ins = _viewInsets;
    return Offset(ins.left + (_viewSize.width - ins.horizontal - size.width * scaleX) / 2,
        ins.top + (_viewSize.height - ins.vertical - size.height * scaleY) / 2);
  }
  double _pinchStart = 1; // scale when a trackpad pinch began
  Offset? _panGrab; // Space-drag / middle-drag pan: last pointer position

  @visibleForTesting
  double get viewScale => _viewScale;
  @visibleForTesting
  Offset get viewOrigin => _viewOrigin;

  /// Zoom as shown to the user: 100% = one image pixel per screen pixel.
  double get zoomPercent => _viewScale * MediaQuery.devicePixelRatioOf(context) * 100;
  bool get _zoomed => _zoom != null;

  /// Sets the view scale, keeping the image point under `focal` (canvas-area coords) where it is.
  void _zoomTo(double scale, {Offset? focal}) {
    final s = _state;
    if (s == null || _viewSize.isEmpty) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final next = scale.clamp(0.1 / dpr, 8 / dpr).toDouble();
    final f = focal ?? _viewInsets.deflateSize(_viewSize).center(_viewInsets.topLeft);
    final imagePoint = (f - _viewOrigin) / _viewScale;
    final origin = f - imagePoint * next;
    final centred = _centredOrigin(Size(s.image.width.toDouble(), s.image.height.toDouble()), next, next);
    setState(() { _zoom = next; _pan = origin - centred; });
    // Several pinch updates can land before the next layout: keep the transform current for them
    _viewScale = next;
    _viewOrigin = origin;
  }

  void _zoomBy(double factor, {Offset? focal}) => _zoomTo(_viewScale * factor, focal: focal);
  void zoomIn() => _zoomBy(1.25);
  void zoomOut() => _zoomBy(0.8);
  void zoomToFit() => setState(() { _zoom = null; _pan = Offset.zero; });
  void zoomActualSize() => _zoomTo(1 / MediaQuery.devicePixelRatioOf(context));

  void _panBy(Offset delta) {
    if (!_zoomed) return;
    setState(() => _pan += delta);
    _viewOrigin += delta;
  }

  /// Trackpad: pinch zooms around the fingers; two-finger scroll pans.
  void _onPanZoomStart(PointerPanZoomStartEvent e) => _pinchStart = _viewScale;
  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if ((e.scale - 1).abs() > 0.001) {
      _zoomTo(_pinchStart * e.scale, focal: e.localPosition);
    } else {
      _panBy(e.localPanDelta);
    }
  }

  /// Mouse wheel pans; with ⌘ (Ctrl elsewhere) it zooms around the pointer.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (Platform.isMacOS ? keys.isMetaPressed : keys.isControlPressed) {
      _zoomBy(math.exp(-e.scrollDelta.dy / 300), focal: e.localPosition);
    } else {
      _panBy(-e.scrollDelta);
    }
  }

  /// Space-drag or middle-button drag moves a zoomed image around.
  bool _startsPan(PointerDownEvent e) =>
      _zoomed && (e.buttons == kMiddleMouseButton ||
          (e.buttons == kPrimaryMouseButton && _textEdit == null &&
              HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.space)));

  /// ⌘ on macOS, Ctrl on Windows and Linux.
  static SingleActivator _cmd(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, meta: Platform.isMacOS, control: !Platform.isMacOS, shift: shift);

  bool get _showsCanvasHandles => (_imageSelected || _copied) && _selection == null;

  Rect get _imageRect => Rect.fromLTWH(0, 0, _state!.image.width.toDouble(), _state!.image.height.toDouble());

  /// Square handles just outside the image border (image coords).
  List<Offset> get _canvasHandles => CanvasPainter.rectHandles(_imageRect.inflate(4 / _viewScale));

  void selectImage() => setState(() { _selection = null; _group.clear(); _imageSelected = true; });

  /// The anchor plus its same-shape group (⌘A). Just the anchor when nothing is grouped.
  Iterable<int> get _selectedIds => _selection == null ? const [] : [_selection!, ..._group];

  /// ⌘A with an element selected: also select every other annotation of the same shape, to move, restyle or
  /// delete them as one. With nothing selected it keeps the old meaning (select the image for canvas resize).
  void _selectAllSimilar() {
    final sel = _annotation(_selection);
    if (sel == null) return selectImage();
    final kind = sel.shape.runtimeType;
    setState(() {
      _group
        ..clear()
        ..addAll([for (final a in _state!.annotations) if (a.id != sel.id && a.shape.runtimeType == kind) a.id]);
      _imageSelected = false;
    });
  }

  /// An annotation's bounding box in image coordinates (for the group selection outline).
  Rect? _annBounds(Annotation a) {
    final b = _bounds(a);
    if (b != null) return b;
    final p = CanvasPainter.outlinePath(a);
    return p.computeMetrics().isEmpty ? null : p.getBounds();
  }

  /// Outline boxes for the grouped peers (not the anchor, which shows its own handles).
  List<Rect> _groupBoxes() => [
        for (final id in _group)
          if (_annotation(id) case final a?)
            if (_annBounds(a) case final r?) r,
      ];

  // ---- The menu bar (lib/app/app_menu.dart) ----

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get pinned => _pinned;
  bool get hasSelection => _selection != null;

  /// Runs a menu bar command (the same actions as the editor's keys and its canvas menu).
  void runMenu(String id) {
    final t = Tool.values.where((t) => t.name == id).firstOrNull;
    if (t != null) return _setTool(t == Tool.box ? _shapeKind.tool : t);
    switch (id) {
      case 'undo': _undoAction();
      case 'redo': _redoAction();
      case 'copy': _copyImage();
      case 'cut': _cutSelection();
      case 'paste': _pasteClipboard();
      case 'duplicate': _duplicateSelection();
      case 'copyGif': copyAnimatedGif();
      case 'copySticker': copySticker();
      case 'copyStillSticker': copyStillSticker();
      case 'copyText': _copyAllText();
      case 'delete': _deleteSelection();
      case 'selectAll': _selectAllSimilar();
      case 'save': save();
      case 'saveAs': saveAs();
      case 'saveGif': saveAnimatedGif();
      case 'share': share();
      case 'reveal': if (_path != null) Native.reveal(_path!);
      case 'open': openImageDialog();
      case 'addImage': _addOverlay();
      case 'flipH': _flipImage(true);
      case 'flipV': _flipImage(false);
      case 'trim': _trim();
      case 'cropCanvas': _cropToCanvas();
      case 'resize': _resizeCanvasDialog();
      case 'canvasColor': _changeCanvasColor();
      case 'flatten': _flattenInPlace();
      case 'zoomIn': zoomIn();
      case 'zoomOut': zoomOut();
      case 'zoomFit': zoomToFit();
      case 'zoomActual': zoomActualSize();
      case 'pin': _setPinned(!_pinned);
      case 'toolbarSide': _toggleToolbarSide();
      case 'manim': _openManim();
      case 'whiteboard': _openWhiteboard();
      case 'excalidraw': _openInWhiteboard();
    }
  }

  /// File › Open in Manim Studio…: the capture as the backdrop and everything drawn on it as Studio objects,
  /// to animate there (lib/manim/from_capture.dart).
  Future<void> _openManim() async {
    _endTextEdit();
    final s = _state;
    if (s == null) return;
    final doc = ManimFromCapture.convert(s, await ManimScene.backdrop(s));
    if (!mounted) return;
    await ManimStudioPage.openDoc(context, doc, _gifName());
  }

  void _showCopied() {
    _antsTimer?.cancel();
    _antsTimer = Timer.periodic(const Duration(milliseconds: 83), (_) => _ants.value = (_ants.value + 1) % 8);
    setState(() => _copied = true);
  }

  void _clearCopied() {
    if (!_copied) return;
    _antsTimer?.cancel();
    _antsTimer = null;
    setState(() => _copied = false);
  }

  void _syncMarch(CanvasState state) {
    final needed = _cropRect != null || BuildUpGif.marches(state);
    if (needed && _marchTimer == null) {
      _marchTimer = Timer.periodic(const Duration(milliseconds: 40), (_) => _march.value = (_march.value + 0.05) % 1);
    } else if (!needed && _marchTimer != null) {
      _marchTimer!.cancel();
      _marchTimer = null;
    }
  }

  @override
  void dispose() {
    if (widget.overlay) _ToolButton.glass = false; // the glass chrome goes with draw mode
    _antsTimer?.cancel();
    _marchTimer?.cancel();
    _playTimer?.cancel();
    _march.dispose();
    super.dispose();
  }

  // ---- Hit testing (the Swift app's rules) ----

  /// Topmost annotation a click can grab with the current tool. Area shapes (highlight, blur, spotlight)
  /// count from inside only for Select or their own tool; boxes and ellipses only by their outline, so you
  /// can still draw inside them.
  Annotation? _hit(Offset p) {
    final t = 6 / _viewScale;
    for (final a in (_state?.annotations ?? const <Annotation>[]).reversed) {
      final interior = switch (a.shape) {
        BlurShape() => _tool == Tool.select || _tool == Tool.blur,
        HighlightShape() => _tool == Tool.select || _tool == Tool.highlight,
        SpotlightShape() => _tool == Tool.select || _tool == Tool.spotlight,
        _ => true,
      };
      if (_hitTest(a, p, t, interior: interior)) return a;
    }
    return null;
  }

  bool _hitTest(Annotation a, Offset p, double t, {bool interior = true}) {
    final reach = t + a.lineWidth;
    bool nearEdge(Rect r, double reach) => r.inflate(reach).contains(p) && !r.deflate(reach).contains(p);
    switch (a.shape) {
      case ArrowShape() || LineShape():
        return _nearCurve(a.curve!, a.curveTangents, p, reach);
      case PenShape(:final points):
        for (var i = 0; i < points.length - 1; i++) {
          if (_distToSeg(p, points[i], points[i + 1]) <= reach) return true;
        }
        return false;
      case RectShape(:final rect):
        return nearEdge(rect, reach);
      case EllipseShape(:final rect):
        final rx = math.max(rect.width / 2, 1.0), ry = math.max(rect.height / 2, 1.0);
        final d = math.sqrt(math.pow((p.dx - rect.center.dx) / rx, 2) + math.pow((p.dy - rect.center.dy) / ry, 2));
        return (d - 1).abs() * math.min(rx, ry) <= reach;
      case HighlightShape(:final rect) || SpotlightShape(:final rect) || BlurShape(:final rect):
        return interior ? rect.inflate(t).contains(p) : nearEdge(rect, t + 2);
      default:
        return _bounds(a)?.inflate(t).contains(p) ?? false;
    }
  }

  /// Bounds of text, callouts, steps and images (for hit testing and their selection box).
  Rect? _bounds(Annotation a) => switch (a.shape) {
        TextShape(:final string, :final at) => () {
            final tp = CanvasPainter.textLayout(string, a, a.color);
            return Rect.fromLTWH(at.dx, at.dy, tp.width, tp.height);
          }(),
        CalloutShape(:final string, :final at) => CanvasPainter.calloutRect(string, at, a),
        StepShape(:final center, :final style) => CanvasPainter.stepBounds(center, a.stepDiameter, style),
        _ => a.rect,
      };

  bool _nearCurve(List<Offset> pts, List<Offset?> tangents, Offset p, double reach) {
    final samples = CanvasPainter.curveSamples(pts, tangents: tangents);
    for (var i = 0; i < samples.length - 1; i++) {
      if (_distToSeg(p, samples[i], samples[i + 1]) <= reach) return true;
    }
    return false;
  }

  /// Which stretch of the curve (between consecutive points) is nearest to `p`.
  int _nearestStretch(List<Offset> pts, List<Offset?> tangents, Offset p) {
    var best = 0, bestDist = double.infinity;
    final segs = CanvasPainter.spline(pts, tangents);
    for (final (i, (a, c1, c2, b)) in segs.indexed) {
      for (var k = 0; k <= 16; k++) {
        final d = (CanvasPainter.cubicPoint(a, c1, c2, b, k / 16) - p).distance;
        if (d < bestDist) { bestDist = d; best = i; }
      }
    }
    return best;
  }

  double _distToSeg(Offset p, Offset a, Offset b) {
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final l2 = dx * dx + dy * dy;
    if (l2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / l2;
    t = t.clamp(0.0, 1.0);
    return (p - Offset(a.dx + t * dx, a.dy + t * dy)).distance;
  }

  List<Offset> _handlesOf(Annotation a) => CanvasPainter.handlesOf(a);

  // ---- Gesture handling ----

  /// New annotations stay inside the image (as in the Swift app).
  Offset _clamp(Offset p) {
    final s = _state;
    if (s == null) return p;
    return Offset(p.dx.clamp(0.0, s.image.width.toDouble()), p.dy.clamp(0.0, s.image.height.toDouble()));
  }

  void _beginMove(Annotation a, Offset p) {
    _dragId = a.id; _resizeHandle = null; _lastPoint = p; _gestureSnapshot = _state;
    _imageMove = a.shape is ImageShape && a.rect != null ? (a.rect!, p) : null;
  }

  /// Where a dragged image goes: snapped to the canvas edges/centre and the other images' (⌘ or Ctrl: freely).
  Annotation _movedImage(Annotation a, Rect start, Offset grab, Offset p) {
    final raw = start.shift(p - grab);
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed) {
      _guides = const [];
      return a.withRect(raw);
    }
    final s = _state!;
    final targets = [
      Rect.fromLTWH(0, 0, s.image.width.toDouble(), s.image.height.toDouble()),
      for (final o in s.annotations)
        if (o.id != a.id && o.shape is ImageShape && o.rect != null) o.rect!,
    ];
    final (shift, guides) = snapRect(raw, targets, 6 / _viewScale);
    _guides = guides;
    return a.withRect(raw.shift(shift));
  }

  /// `p` is in image coordinates and may lie outside the image (the canvas area around it).
  void _down(Offset p) {
    _stopPlay();
    if (_textEdit != null) { _endTextEdit(); return; } // a click elsewhere keeps the typed text
    final now = DateTime.now();
    final doubleClick = now.difference(_lastDown).inMilliseconds < 400 && (p - _lastDownPoint).distance * _viewScale < 6;
    _lastDown = now;
    _lastDownPoint = p;
    final handleTolerance = 9 / _viewScale;
    final canvasHandle = _showsCanvasHandles
        ? _canvasHandles.indexWhere((h) => (h - p).distance <= 8 / _viewScale) : -1;
    _clearCopied();

    if (_tool == Tool.crop) { _downCrop(p, doubleClick: doubleClick); return; }

    if (canvasHandle >= 0) {
      final edge = CanvasPainter.rectHandles(_imageRect)[canvasHandle];
      setState(() => _canvasDrag = (canvasHandle, _imageRect, edge - p));
      return;
    }
    if (doubleClick) {
      final sel = _annotation(_selection);
      final pts = sel?.curve;
      if (sel != null && pts != null) {
        final grip = CanvasPainter.curveGrips(sel).where((g) => (g.at - p).distance <= 9 / _viewScale).firstOrNull;
        if (grip?.kind == GripKind.tangent) {
          _replace(sel.withTangent(grip!.index, null)); // double-click a tangent handle: back to automatic
          return;
        }
        if (grip?.kind == GripKind.bend) {
          _replace(sel.removeBend(grip!.index)); // double-click a bend point: remove it
          return;
        }
        if (_hitTest(sel, p, 6 / _viewScale)) {
          _replace(sel.insertBend(_nearestStretch(pts, sel.curveTangents, p) + 1, p)); // double-click the curve: add one
          return;
        }
      }
      final t = _hit(p);
      if (t != null && (t.shape is TextShape || t.shape is CalloutShape)) {
        _beginTextEdit(t, before: _state!, isNew: false);
        return;
      }
    }
    final selected = _annotation(_selection);
    if (selected != null) {
      final handles = _handlesOf(selected);
      for (var i = 0; i < handles.length; i++) {
        if ((handles[i] - p).distance <= handleTolerance) {
          _gestureSnapshot = _state;
          if (selected.curve != null) {
            final g = CanvasPainter.curveGrips(selected)[i];
            // A "+" handle: a new bend point on that stretch once it's dragged (a plain click changes nothing)
            if (g.kind == GripKind.add) _pendingBend = (g.index, g.at);
          }
          _dragId = selected.id; _resizeHandle = i; _lastPoint = p;
          return;
        }
      }
      if (_hitTest(selected, p, 6 / _viewScale)) {
        _beginMove(selected, p);
        return;
      }
    }
    // Any tool: clicking an existing annotation selects it for editing (drag moves it)
    final hit = _hit(p);
    if (hit != null) {
      // Tapping within the current ⌘A group keeps it (so the drag moves the whole group); otherwise select just this shape.
      final inGroup = _group.isNotEmpty && _selectedIds.contains(hit.id);
      if (!inGroup) setState(() { _group.clear(); _selection = hit.id; _imageSelected = false; });
      _beginMove(hit, p);
      return;
    }
    setState(() { _selection = null; _group.clear(); });
    if (_tool == Tool.select) {
      setState(() => _imageSelected = _imageRect.contains(p)); // empty canvas selects the image
      return;
    }
    setState(() => _imageSelected = false);
    if (!_imageRect.inflate(24 / _viewScale).contains(p)) return; // far outside the image: nothing to draw
    if (_tool == Tool.text) { _addText(_clamp(p)); return; }
    if (_tool == Tool.step) { _addStep(_clamp(p)); return; }
    if (_tool == Tool.pen) { _penPoints = [_clamp(p)]; return; }
    _createStart = _clamp(p); _createCurrent = _createStart;
    _trail = (_followDrag || BuildUpGif.fourier) && (_tool == Tool.arrow || _tool == Tool.line) ? [_createStart!] : null;
  }

  void _move(Offset p) {
    if (_tool == Tool.crop && _cropHandle != null && _cropRect != null) {
      if (_cropHandle == -1) {
        final d = p - (_cropGrab ?? p);
        _cropGrab = p;
        setState(() => _cropRect = _cropRect!.shift(d));
      } else {
        setState(() => _cropRect = _resizedRect(_cropRect!, _cropHandle!, p));
      }
      return;
    }
    if (_canvasDrag case (final h, _, final grab)) {
      final r = _resizedRect(_imageRect, h, p + grab);
      final n = Rect.fromLTRB(math.min(r.left, r.right), math.min(r.top, r.bottom),
          math.max(r.left, r.right), math.max(r.top, r.bottom));
      if (n.width >= 16 && n.height >= 16) setState(() => _canvasDrag = (h, n, grab));
    } else if (_dragId != null) {
      var a = _annotation(_dragId);
      if (a == null) return;
      // A grouped body-drag moves every selected shape by the same step (resize handles stay anchor-only).
      if (_group.isNotEmpty && _resizeHandle == null && _imageMove == null) {
        final d = p - _lastPoint;
        _lastPoint = p;
        final ids = _selectedIds.toSet();
        _commit(_state!.copyWith(annotations: [for (final x in _state!.annotations) ids.contains(x.id) ? x.movedBy(d) : x]),
            snapshot: false);
        return;
      }
      if (_pendingBend case (final stretch, final at)) {
        _pendingBend = null;
        a = a.insertBend(stretch + 1, at);
        _replace(a, snapshot: false);
        _resizeHandle = 2 + stretch; // now dragging the new bend point (handles: 2 ends, then the bends)
      }
      final next = switch ((_resizeHandle, _imageMove)) {
        (final handle?, _) => _resized(a, handle, p),
        (null, (final start, final grab)?) => _movedImage(a, start, grab, p),
        _ => _moved(a, p - _lastPoint),
      };
      _lastPoint = p;
      _replace(next, snapshot: false);
    } else if (_penPoints != null) {
      if ((_penPoints!.last - _clamp(p)).distance >= 1) setState(() => _penPoints!.add(_clamp(p)));
    } else if (_createStart != null) {
      var q = _clamp(p);
      // Square and circle (or Shift) keep the sides equal
      final shape = _tool == Tool.box || _tool == Tool.ellipse;
      if (shape && (_shapeKind.even || HardwareKeyboard.instance.isShiftPressed)) {
        final d = q - _createStart!, side = math.min(d.dx.abs(), d.dy.abs());
        q = _createStart! + Offset(side * d.dx.sign, side * d.dy.sign);
      }
      if (_trail != null && (_trail!.last - q).distance * _viewScale >= 2) _trail!.add(q);
      setState(() => _createCurrent = q);
    }
  }

  void _up(Offset p) {
    if (_tool == Tool.crop) {
      if (_cropHandle != null) { setState(() { _cropHandle = null; _cropGrab = null; }); return; }
      if (_createStart != null && _createCurrent != null) {
        final r = Rect.fromPoints(_createStart!, _createCurrent!);
        setState(() { _cropRect = (r.width > 8 && r.height > 8) ? r : null; _createStart = null; _createCurrent = null; });
        return;
      }
    }
    if (_canvasDrag case (_, final rect, _)) {
      setState(() => _canvasDrag = null);
      if (rect != _imageRect) _resizeCanvasTo(rect);
      return;
    }
    if (_dragId != null) {
      final wasImage = _annotation(_dragId)?.shape is ImageShape;
      // One undo step for the whole move/resize, and none for a plain click
      if (_gestureSnapshot != null && !identical(_gestureSnapshot, _state)) { _undo.add(_gestureSnapshot!); _redo.clear(); }
      // A redraw on release: the thickness slider (hidden while dragging) comes back, even after a plain click
      setState(() { _dragId = null; _resizeHandle = null; _gestureSnapshot = null; _pendingBend = null; _imageMove = null; _guides = const []; });
      if (wasImage) _growAfterEdit();
      return;
    }
    if (_penPoints != null) {
      final pts = _penPoints!; _penPoints = null;
      if (pts.length > 1) {
        final a = Annotation(id: _nextId++, scale: _density, shape: PenShape(pts), color: _color, size: _size, arrowStyle: _styleFor(StyleKind.shape));
        _add(BuildUpGif.fourier ? Epicycles.fourierized(a) : a); // Fourier drawing keeps the curve the circles trace
      }
      return;
    }
    if (_createStart != null) {
      final a = _createStart!, b = _createCurrent ?? p;
      _createStart = null; _createCurrent = null;
      _finishCreate(a, b);
      _trail = null;
    }
  }

  /// Crop-tool pointer-down: grab a dotted handle to resize, the body to move, a double-click inside to apply,
  /// or start a fresh crop rectangle.
  void _downCrop(Offset p, {required bool doubleClick}) {
    final tol = 10 / _viewScale;
    if (_cropRect != null) {
      if (doubleClick && _cropRect!.contains(p)) { _applyCrop(); return; }
      final handles = CanvasPainter.rectHandles(_cropRect!);
      for (var i = 0; i < handles.length; i++) {
        if ((handles[i] - p).distance <= tol) { setState(() => _cropHandle = i); _cropGrab = p; return; }
      }
      if (_cropRect!.contains(p)) { setState(() => _cropHandle = -1); _cropGrab = p; return; }
    }
    setState(() { _cropRect = null; _cropHandle = null; _createStart = _clamp(p); _createCurrent = _createStart; });
  }

  /// Applies the pending crop (clipped to the image, rounded corners) and returns to the Select tool.
  void _applyCrop() {
    final r = _cropRect?.intersect(_imageRect);
    setState(() { _cropRect = null; _cropHandle = null; _cropHover = null; });
    if (r == null || r.width < 1 || r.height < 1) return;
    _crop(r, rounded: true);
  }

  void _cancelCrop() =>
      setState(() { _cropRect = null; _cropHandle = null; _cropHover = null; _createStart = null; _createCurrent = null; });

  /// Tracks which crop handle (or the body) the cursor is over, so the cursor can show it's draggable.
  void _hoverCrop(Offset p) {
    int? h;
    if (_cropRect != null) {
      final tol = 10 / _viewScale;
      final handles = CanvasPainter.rectHandles(_cropRect!);
      for (var i = 0; i < handles.length; i++) {
        if ((handles[i] - p).distance <= tol) { h = i; break; }
      }
      h ??= _cropRect!.contains(p) ? -1 : null;
    }
    if (h != _cropHover) setState(() => _cropHover = h);
  }

  /// The resize cursor for the crop handle under the pointer (two-sided arrow), or move inside the rect.
  MouseCursor get _cropCursor => switch (_cropHover) {
        0 || 3 => SystemMouseCursors.resizeUpLeftDownRight, // top-left / bottom-right corners
        1 || 2 => SystemMouseCursors.resizeUpRightDownLeft, // top-right / bottom-left corners
        4 || 5 => SystemMouseCursors.resizeUpDown, // top / bottom edges
        6 || 7 => SystemMouseCursors.resizeLeftRight, // left / right edges
        -1 => SystemMouseCursors.move,
        _ => SystemMouseCursors.precise,
      };

  /// Dragging an annotation's body. A callout's bubble moves on its own, leaving the pointer tip anchored on
  /// what it points at; Option-drag (Alt on Windows/Linux) moves the whole callout.
  Annotation _moved(Annotation a, Offset d) {
    if (a.shape case CalloutShape(:final at, tail: _?) && final c when !HardwareKeyboard.instance.isAltPressed) {
      return a.copyWith(shape: c.copyWith(at: at + d));
    }
    return a.movedBy(d);
  }

  /// New canvas = `rect` of the current image (image coords): added space shows the canvas colour, or it crops.
  Future<void> _resizeCanvasTo(Rect rect) async {
    final s = _state!;
    final w = rect.width.round(), h = rect.height.round();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(s.image, -rect.topLeft, Paint());
    final out = await rec.endRecording().toImage(w, h);
    _commit(s.copyWith(image: out, annotations: [for (final a in s.annotations) a.movedBy(-rect.topLeft)]));
    setState(() => _imageSelected = true);
  }

  /// Scale the whole canvas (image resampled, annotations scaled with it) to [w]×[h] pixels — what the
  /// editable W×H fields under the image do, so reducing the numbers shrinks the picture rather than
  /// cropping it.
  Future<void> _scaleCanvasTo(int w, int h) async {
    final s = _state!;
    if (w == s.image.width && h == s.image.height) return;
    final sx = w / s.image.width, sy = h / s.image.height;
    final rec = ui.PictureRecorder();
    final src = Rect.fromLTWH(0, 0, s.image.width.toDouble(), s.image.height.toDouble());
    Canvas(rec).drawImageRect(s.image, src, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..filterQuality = FilterQuality.high);
    final out = await rec.endRecording().toImage(w, h);
    _commit(s.copyWith(image: out, annotations: [for (final a in s.annotations) a.scaledBy(sx, sy)]));
  }

  void _finishCreate(Offset a, Offset b) {
    if (_tool == Tool.callout) {
      // Drag from what to point at to where the bubble goes; a click points at the click
      final dragged = (b - a).distance * _viewScale > 12;
      _addCallout(a, dragged ? b : null);
      return;
    }
    final rect = Rect.fromPoints(a, b);
    final big = rect.width > 3 && rect.height > 3;
    Shape? shape;
    switch (_tool) {
      case Tool.arrow || Tool.line when BuildUpGif.fourier && _fourierShape(a, b) != null:
        shape = _fourierShape(a, b);
      case Tool.arrow || Tool.line:
        final f = _follow(a, b);
        if (f != null) {
          shape = _tool == Tool.arrow
              ? ArrowShape(f.from, f.to, points: f.points, tangents: f.tangents)
              : LineShape(f.from, f.to, points: f.points, tangents: f.tangents);
        } else if ((b - a).distance > 4) {
          shape = _tool == Tool.arrow ? ArrowShape(a, b) : LineShape(a, b);
        }
      case Tool.box:
        if (big) shape = RectShape(rect);
      case Tool.ellipse:
        if (big) shape = EllipseShape(rect);
      case Tool.highlight:
        if (big) shape = HighlightShape(rect);
      case Tool.spotlight:
        if (big) shape = SpotlightShape(rect);
      case Tool.blur:
        if (big) shape = BlurShape(rect, null);
      case Tool.crop:
        if (rect.width > 8 && rect.height > 8) _crop(rect);
      default:
        break;
    }
    if (shape != null) {
      final kind = StyleKind.ofTool(_tool);
      _add(Annotation(id: _nextId++, scale: _density, shape: shape, color: _color, size: _size,
          arrowStyle: kind == null ? ArrowStyle.arrow : _styleFor(kind)));
    }
  }

  /// Fourier drawing: the arrow or line as the smooth Fourier curve its circles trace through the drag
  /// (ends exactly where you pressed and let go). Null for a drag too short to trace.
  Shape? _fourierShape(Offset a, Offset b) {
    final raw = _rawStroke(_tool, a, b, _trail);
    return raw == null ? null : Epicycles.fourierized(Annotation(id: -1, shape: raw)).shape;
  }

  /// The drag exactly as made, as an arrow or line through every point of `trail`.
  static Shape? _rawStroke(Tool tool, Offset a, Offset b, List<Offset>? trail) {
    if ((b - a).distance < 4) return null;
    final mid = trail == null || trail.length < 3
        ? const <Offset>[]
        : [for (final q in trail.skip(1)) if ((q - a).distance > 1 && (q - b).distance > 1) q];
    return tool == Tool.arrow ? ArrowShape(a, b, points: mid) : LineShape(a, b, points: mid);
  }

  void _add(Annotation a) {
    final next = _state!.copyWith(annotations: [..._state!.annotations, a]);
    _commit(next);
    setState(() { _selection = a.id; _group.clear(); });
  }

  /// Shows `a` appearing as the GIF would (Play): drawn on, as the string art of its tangents, or traced by Fourier circles
  /// (while drawing with Fourier on, the circles follow live).
  void _playEntrance(Annotation a) {
    if (!_canPlay(a)) return;
    _playTimer?.cancel();
    final start = DateTime.now();
    final length = BuildUpGif.fourier ? 1800 : BuildUpGif.appearing(a).inMilliseconds;
    setState(() { _playId = a.id; _playT = 0; });
    _playTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final t = DateTime.now().difference(start).inMilliseconds / length;
      if (t >= 1 || !mounted) return _stopPlay();
      setState(() => _playT = t);
    });
  }

  void _stopPlay() {
    if (_playId == null) return;
    _playTimer?.cancel();
    _playTimer = null;
    if (mounted) setState(() => _playId = null);
  }

  static bool _canPlay(Annotation a) => switch (BuildUpGif.entrance) {
        Entrance.fourier => Epicycles.of(a) != null,
        Entrance.envelope || Entrance.draw => CanvasPainter.hasOutline(a),
      };

  @override
  bool get canPlayEntrance => selected != null && _canPlay(selected!);

  @override
  void playEntrance() {
    final a = selected;
    if (a != null) _playEntrance(a);
  }

  void _replace(Annotation a, {bool snapshot = true}) {
    final anns = [for (final x in _state!.annotations) x.id == a.id ? a : x];
    _commit(_state!.copyWith(annotations: anns), snapshot: snapshot);
  }

  Annotation _resized(Annotation a, int handle, Offset p) {
    switch (a.shape) {
      case CalloutShape() && final c:
        return a.copyWith(shape: c.copyWith(tail: () => _clamp(p)));
      // Ends and bend points move; a tangent handle steers the curve through its point (both sides together)
      case ArrowShape() || LineShape():
        final grips = CanvasPainter.curveGrips(a);
        if (handle >= grips.length) return a;
        final g = grips[handle];
        final pts = [...a.curve!];
        return switch (g.kind) {
          GripKind.end || GripKind.bend => a.withCurve(pts..[g.index] = p),
          GripKind.tangent => a.withTangent(g.index, (p - pts[g.index]) * 3.0 * g.side.toDouble()),
          GripKind.add => a,
        };
      default:
        final r = a.rect;
        if (r == null) return a;
        return a.withRect(_resizedRect(r, handle, p));
    }
  }

  Rect _resizedRect(Rect r, int i, Offset p) {
    switch (i) {
      case 0: return Rect.fromPoints(r.bottomRight, p);
      case 1: return Rect.fromPoints(r.bottomLeft, p);
      case 2: return Rect.fromPoints(r.topRight, p);
      case 3: return Rect.fromPoints(r.topLeft, p);
      case 4: return Rect.fromLTRB(r.left, p.dy, r.right, r.bottom);
      case 5: return Rect.fromLTRB(r.left, r.top, r.right, p.dy);
      case 6: return Rect.fromLTRB(p.dx, r.top, r.right, r.bottom);
      case 7: return Rect.fromLTRB(r.left, r.top, p.dx, r.bottom);
      default: return r;
    }
  }

  /// Text: starts typing right where you clicked.
  void _addText(Offset p) {
    final before = _state!;
    final a = Annotation(id: _nextId++, scale: _density, shape: TextShape('', p), color: _color, size: _size,
        textFormat: _formatFor('text'));
    setState(() => _state = before.copyWith(annotations: [...before.annotations, a]));
    _beginTextEdit(a, before: before, isNew: true);
  }

  /// A callout whose pointer tip is at `tip`. Dragged: the bubble is centred where the drag ended (`boxCenter`).
  /// A plain click (`boxCenter` null): the bubble sits up and to the right of the click (below it near the top).
  /// Typing starts in the bubble straight away.
  void _addCallout(Offset tip, Offset? boxCenter) {
    final fs = _size.fontSize * _density;
    final probe = Annotation(id: -1, shape: CalloutShape('', Offset.zero, style: _calloutStyle), size: _size, scale: _density,
        textFormat: _formatFor('callout'));
    final r = CanvasPainter.calloutRect(CanvasPainter.typeHint, Offset.zero, probe); // placed for a few words of text
    Offset at;
    if (boxCenter != null) {
      at = boxCenter - r.center;
    } else {
      at = tip + Offset(fs * 1.2, -(r.height + fs * 1.6)) - r.topLeft;
      if (at.dy + r.top < 0) at = tip + Offset(fs * 1.2, fs * 1.6) - r.topLeft;
    }
    // Keep the whole bubble on the image
    final s = _state;
    if (s != null) {
      final box = r.shift(at);
      final dx = box.left < 0 ? -box.left : (box.right > s.image.width ? s.image.width - box.right : 0.0);
      final dy = box.top < 0 ? -box.top : (box.bottom > s.image.height ? s.image.height - box.bottom : 0.0);
      at += Offset(dx, dy);
    }
    final before = _state!;
    final a = Annotation(id: _nextId++, scale: _density, shape: CalloutShape('', at, tail: tip, style: _calloutStyle),
        color: _color, size: _size, textFormat: _formatFor('callout'));
    setState(() => _state = before.copyWith(annotations: [...before.annotations, a]));
    _beginTextEdit(a, before: before, isNew: true);
  }

  static Shape _withText(Shape s, String text, List<TextRun> runs) => switch (s) {
        TextShape(:final at) => TextShape(text, at, runs: runs),
        CalloutShape() && final c => c.copyWith(string: text, runs: runs),
        _ => s,
      };

  void _beginTextEdit(Annotation a, {required CanvasState before, required bool isNew}) {
    final text = switch (a.shape) { TextShape(:final string) || CalloutShape(:final string) => string, _ => '' };
    // Cursor at the end; highlighting text (drag, Shift+arrows, ⌘A) brings up the format bar
    _textController.runs = CanvasPainter.runsOf(a);
    _lastText = text;
    _textController.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    setState(() { _textEdit = (id: a.id, before: before, isNew: isNew); _selection = a.id; _group.clear(); _imageSelected = false; });
    WidgetsBinding.instance.addPostFrameCallback((_) => _textFocus.requestFocus());
  }

  void _insertNewline() {
    final v = _textController.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _textController.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, '\n'),
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
  }

  /// Live: the bubble (or text box) follows what is typed. Not an undo step by itself.
  void _textChanged() {
    final e = _textEdit;
    final a = e == null ? null : _annotation(e.id);
    if (a == null) return;
    final text = _textController.text;
    if (text != _lastText) {
      _textController.runs = TextRuns.adjust(_lastText, text, _textController.runs);
      _lastText = text;
    }
    final next = a.copyWith(shape: _withText(a.shape, text, _textController.runs));
    setState(() => _state = _state!.copyWith(annotations: [for (final x in _state!.annotations) x.id == a.id ? next : x]));
  }

  /// Ends typing: the text becomes one undo step; an empty new one disappears; `cancel` (Esc) restores.
  void _endTextEdit({bool cancel = false}) {
    final e = _textEdit;
    if (e == null) return;
    final text = _textController.text.trim();
    setState(() => _textEdit = null);
    if (cancel || (text.isEmpty && e.isNew)) {
      setState(() { _state = e.before; if (e.isNew) _selection = null; });
    } else {
      final a = _annotation(e.id);
      if (a != null) {
        _undo.add(e.before);
        _redo.clear();
        _clearCopied();
        setState(() {
          _state = _state!.copyWith(annotations: [
            for (final x in _state!.annotations)
              if (x.id != e.id) x
              else if (text.isNotEmpty)
                a.copyWith(shape: _withText(a.shape, text, TextRuns.adjust(_textController.text, text, _textController.runs))),
          ]);
          if (text.isEmpty) _selection = null; // emptied an existing one: it is removed
        });
      }
    }
    _focus.requestFocus();
  }

  void _addStep(Offset p) {
    _add(Annotation(id: _nextId++, scale: _density, shape: StepShape(p, style: _stepMarker), color: _color, size: _size));
  }

  /// The bubble new callouts get (remembered as `callout.style`); a selected callout shows its own.
  CalloutStyle _calloutStyle = CalloutStyle.rounded;

  @override
  CalloutStyle? get calloutStyle {
    final a = selected;
    if (a != null) return a.shape is CalloutShape ? (a.shape as CalloutShape).style : null;
    return _tool == Tool.callout ? _calloutStyle : null;
  }

  /// Picks the bubble for new callouts; a selected callout changes to it (the text stays where it is).
  @override
  void pickCalloutStyle(CalloutStyle s) {
    setState(() => _calloutStyle = s);
    Native.setString('callout.style', s.name);
    final a = selected;
    if (a != null && a.shape is CalloutShape) {
      _replace(a.copyWith(shape: (a.shape as CalloutShape).copyWith(style: s)));
    }
  }

  /// The marker shape new steps get (remembered as `step.style`); a selected step shows its own.
  StepMarker _stepMarker = StepMarker.circle;

  @override
  StepMarker? get stepMarker {
    final a = selected;
    if (a != null) return a.shape is StepShape ? (a.shape as StepShape).style : null;
    return _tool == Tool.step ? _stepMarker : null;
  }

  /// Picks the marker for new steps; a selected step changes to it.
  @override
  void pickStepMarker(StepMarker s) {
    setState(() => _stepMarker = s);
    Native.setString('step.style', s.name);
    final a = selected;
    if (a != null && a.shape is StepShape) {
      _replace(a.copyWith(shape: StepShape((a.shape as StepShape).center, style: s)));
    }
  }

  Future<void> _growAfterEdit() async {
    if (_state == null) return;
    final grown = await _grownToFit(_state!);
    if (!identical(grown, _state)) _commit(grown);
  }

  /// Loads an image file (a capture, or one picked by the user) as a fresh canvas. `fresh` marks a capture
  /// that just happened: it opens in Crop mode (frame + handles ready) unless that setting is off.
  Future<void> openFile(String path, {bool fresh = false}) async {
    final bytes = await File(path).readAsBytes(); // read fully first: the file may be rewritten later
    if (bytes.isEmpty) return;
    // Saved by SnapNow with its markup: the original capture and every annotation come back, still editable
    var state = await MarkupFile.read(bytes);
    if (state == null) {
      final frame = await (await ui.instantiateImageCodec(bytes)).getNextFrame();
      // Retina captures record 144 dpi; images without DPI info count as Retina when they are large
      final density = await Native.imageDensity(path) ?? (frame.image.width > 1800 ? 2.0 : 1.0);
      state = CanvasState(image: frame.image, density: density);
    }
    for (final a in state.annotations) {
      if (a.id >= _nextId) _nextId = a.id + 1;
    }
    _resetInteraction();
    setState(() {
      _undo.clear(); _redo.clear(); _selection = null;
      _state = state;
      _path = path;
      _savedState = _state;
      _imageSelected = false;
      _canvasDrag = null;
      _zoom = null; // a new image opens fitted
      _pan = Offset.zero;
      _originalSize = Size(state!.image.width.toDouble(), state.image.height.toDouble());
    });
    _clearCopied();
    _refreshImageBytes();
    await windowManager.setTitle('SnapNow — ${path.split('/').last}');
    if (widget.overlay) {
      final level = int.tryParse(await Native.getString('liveDrawGlass') ?? '');
      if (mounted && level != null && level != _glassLevel) setState(() => _glassLevel = level.clamp(0, 100));
      if (mounted) _setTool(Tool.arrow); // draw mode starts on the Arrow, ready to point at things
    } else if (fresh && mounted && ((await Native.getBool('capture.openInCrop')) ?? true) && mounted) {
      _setTool(Tool.crop);
    }
  }

  /// Drops whatever was mid-way on the old picture (text being typed, a pending crop frame, a drag, a ⌘A
  /// group) before another one takes the canvas, so none of it lands on the new picture.
  void _resetInteraction() {
    if (_textEdit != null) _endTextEdit(cancel: true);
    _cropRect = null; _cropHandle = null; _cropGrab = null; _cropHover = null;
    _createStart = null; _createCurrent = null; _penPoints = null; _trail = null;
    _dragId = null; _resizeHandle = null; _imageMove = null; _guides = const []; _pendingBend = null;
    _gestureSnapshot = null;
    _group.clear();
  }

  @visibleForTesting
  bool get debugInteracting => _textEdit != null || _cropRect != null || _group.isNotEmpty || _dragId != null;

  Future<void> openImageDialog() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    final path = result?.files.firstOrNull?.path;
    if (path != null) await AppController.instance.openEditor(path); // via the Library: offers to save first
  }

  Future<Uint8List?> _flatPng() async {
    if (_state == null) return null;
    final data = await (await _flatten()).toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  /// ⌘C: always the flattened still image (PNG); marching ants run around it instead of a toast (as in
  /// the Swift app). Until 1.70.6 markup with Marching Ants lines copied a looping GIF here instead -
  /// per the user, ⌘C is always the static image and ⇧⌘C (copyAnimatedGif) is the GIF.
  Future<void> _copyImage() async {
    _endTextEdit();
    final s = _state;
    if (s == null) return;
    final png = await _flatPng();
    if (png == null) return;
    await Pasteboard.writeImage(png);
    if (!mounted) return;
    setState(() => _selection = null);
    _showCopied();
  }

  final _shareKey = GlobalKey();

  /// Share button: what ⌘C would copy (the flattened picture, or the looping GIF when something marches)
  /// as a file in the macOS share menu. Flattened only, so blurred parts can't be recovered from it.
  Future<void> share() async {
    _endTextEdit();
    final s = _state;
    // The share menu opens under the toolbar's Share button (also File › Share…)
    final box = (_shareKey.currentContext ?? context).findRenderObject() as RenderBox?;
    if (s == null || box == null) return;
    final String path;
    try {
      final dir = Directory('${Directory.systemTemp.path}/SnapNow Share')..createSync(recursive: true);
      final preview = _gifPreview; // context-aware: share the animated GIF you're looking at, not the still
      if (preview != null) {
        path = '${dir.path}/${_gifName()}.gif';
        await File(path).writeAsBytes(preview, flush: true);
      } else if (BuildUpGif.marches(s)) {
        path = '${dir.path}/${_gifName()}.gif';
        await File(path).writeAsBytes(await BuildUpGif.renderMarching(s), flush: true);
      } else {
        final png = await _flatPng();
        if (png == null) return;
        path = '${dir.path}/${_gifName()}.png';
        await File(path).writeAsBytes(png, flush: true);
      }
    } catch (e, st) {
      debugPrint('Share: $e\n$st');
      await Native.toast("Couldn't prepare the image", symbol: 'exclamationmark.triangle.fill');
      return;
    }
    if (!mounted) return;
    final at = box.localToGlobal(Offset.zero);
    await Native.share(path, _shareKey.currentContext != null
        ? at & box.size
        : Rect.fromLTWH(at.dx + box.size.width - 72, at.dy, 56, 58)); // the toolbar's right end
  }

  /// Saves back to the capture's file, or a new file in Pictures › SnapNow. The file is the finished
  /// image with the markup kept inside it, so reopening it later brings the annotations back.
  Future<void> save() async {
    _endTextEdit();
    var png = await _flatPng();
    if (png == null) return;
    try {
      png = await MarkupFile.embed(png, _state!);
    } catch (e, st) {
      debugPrint('Markup not kept: $e\n$st'); // still save the picture
    }
    final path = _path ?? AppController.newCapturePath();
    await File(path).writeAsBytes(png!, flush: true);
    _path = path;
    setState(() => _savedState = _state);
    await windowManager.setTitle('SnapNow — ${path.split('/').last}');
    AppController.instance.capturesVersion.value++;
    await Native.toast('Saved');
  }

  /// OCR of the whole image: clipboard plus a toast showing what was read.
  Future<void> _copyAllText() async {
    final png = await _flatPng();
    if (png == null) return;
    final tmp = '${Directory.systemTemp.path}/snaplite-ocr-${DateTime.now().millisecondsSinceEpoch}.png';
    await File(tmp).writeAsBytes(png, flush: true);
    await Native.toast('Reading text…', symbol: 'text.viewfinder');
    final text = await Native.ocr(tmp);
    try { File(tmp).deleteSync(); } catch (_) {}
    await Native.copyText(text);
  }

  Future<void> _addOverlay() async {
    if (_state == null) return;
    final result = await FilePicker.pickFiles(type: FileType.image, withData: true);
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null) return;
    await addOverlayBytes(bytes);
  }

  /// Drops an image into the canvas as a movable, resizable overlay at its actual size (so captures of the
  /// same size take the same space), centred on `globalPosition` (a filmstrip drop) or on the canvas; the
  /// canvas grows if the overlay spills past it.
  Future<void> addOverlayFile(String path, {Offset? globalPosition}) async =>
      addOverlayBytes(await File(path).readAsBytes(), globalPosition: globalPosition);

  Future<void> addOverlayBytes(Uint8List bytes, {Offset? globalPosition}) async {
    if (_state == null) return;
    final codec = await ui.instantiateImageCodec(bytes);
    final overlay = (await codec.getNextFrame()).image;
    final cw = _state!.image.width.toDouble(), ch = _state!.image.height.toDouble();
    final nw = overlay.width.toDouble(), nh = overlay.height.toDouble();
    final fit = math.min(1.0, 8000 / math.max(nw, nh)); // only a huge image is scaled down, to keep the canvas workable
    final w = nw * fit, h = nh * fit;
    var center = Offset(cw / 2, ch / 2);
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (globalPosition != null && box != null && box.hasSize) {
      center = box.globalToLocal(globalPosition) * (cw / box.size.width);
    }
    final rect = Rect.fromCenter(center: center, width: w, height: h);
    final ann = Annotation(id: _nextId++, scale: _density, shape: ImageShape(rect, overlay), color: const Color(0x00000000));
    var next = _state!.copyWith(annotations: [..._state!.annotations, ann]);
    next = await _grownToFit(next);
    _commit(next);
    setState(() { _selection = ann.id; _group.clear(); _tool = Tool.select; });
  }

  static const _logoExts = ['.png', '.jpg', '.jpeg', '.webp'];
  Directory? _logosDirCache;

  /// Where user-added logos live (persist without a rebuild, unlike the bundled `assets/logos/`).
  Future<Directory> _userLogosDir() async {
    final d = _logosDirCache ??= Directory('${(await getApplicationSupportDirectory()).path}/logos');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// Copies dropped/picked image files into the user logos dir, with collision-safe names; the one import
  /// path for both drag-and-drop and the Add button. Returns how many were added.
  Future<int> _importLogoFiles(Iterable<String> paths) async {
    final dir = await _userLogosDir();
    var added = 0;
    for (final p in paths) {
      if (!_logoExts.any((e) => p.toLowerCase().endsWith(e))) continue;
      final src = File(p);
      if (!src.existsSync()) continue;
      try {
        if (await src.length() > 20 * 1024 * 1024) continue; // skip absurdly large files
      } catch (_) {
        continue;
      }
      final base = p.split('/').last, dot = base.lastIndexOf('.');
      final name = base.substring(0, dot), ext = base.substring(dot);
      var dest = '${dir.path}/$base';
      for (var n = 1; File(dest).existsSync(); n++) {
        dest = '${dir.path}/$name-$n$ext';
      }
      try {
        await src.copy(dest);
        added++;
      } catch (_) {}
    }
    return added;
  }

  /// Saves a pasted/clipboard image into the user logos dir (collision-safe name); returns 1 if added, else 0.
  Future<int> _importLogoBytes(Uint8List bytes, {String stem = 'pasted-logo'}) async {
    if (bytes.isEmpty || bytes.length > 20 * 1024 * 1024) return 0;
    try {
      (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image.dispose(); // must be a real image
    } catch (_) {
      return 0;
    }
    final dir = await _userLogosDir();
    var dest = '${dir.path}/$stem.png';
    for (var n = 1; File(dest).existsSync(); n++) {
      dest = '${dir.path}/$stem-$n.png';
    }
    try {
      await File(dest).writeAsBytes(bytes, flush: true);
      return 1;
    } catch (_) {
      return 0;
    }
  }

  /// A grid of logos — those bundled under `assets/logos/` plus any the user has added — that you can grow by
  /// dragging image files onto the dialog or via the Add button; the chosen one drops onto the canvas as a
  /// movable, resizable overlay (the same as Add Image).
  Future<void> _showLogoPicker() async {
    final dir = await _userLogosDir();
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final bundled = manifest.listAssets()
        .where((a) => a.startsWith('assets/logos/') && _logoExts.any((e) => a.toLowerCase().endsWith(e)))
        .toList()
      ..sort();
    // Built-in logos the user removed: they can't be deleted from the app bundle, so they're hidden by path
    // (newline-joined in the `logos.hidden` pref) and come back with "Restore built-ins".
    final hidden = <String>{
      ...((await Native.getString('logos.hidden').catchError((_) => null)) ?? '').split('\n').where((s) => s.isNotEmpty),
    };
    if (!mounted) return;
    // Result: (isAsset, path) — asset path for bundled, file path for user logos.
    final picked = await showDialog<(bool, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) {
          final scheme = Theme.of(ctx).colorScheme;
          final files = dir
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where((p) => _logoExts.any((e) => p.toLowerCase().endsWith(e)))
              .toList()
            ..sort();
          final entries = <(bool, String)>[
            for (final a in bundled) if (!hidden.contains(a)) (true, a),
            for (final p in files) (false, p),
          ];
          // Removes a logo: a user file is deleted; a built-in is hidden (restorable with "Restore built-ins").
          Future<void> remove(bool isAsset, String path) async {
            final name = path.split('/').last.replaceFirst(RegExp(r'\.[^.]+$'), '');
            try {
              if (isAsset) {
                hidden.add(path);
                await Native.setString('logos.hidden', hidden.join('\n'));
              } else {
                await File(path).delete();
              }
              setInner(() {});
              await Native.toast('Removed $name', symbol: 'trash.fill');
            } catch (_) {
              await Native.toast("Couldn't remove $name", symbol: 'exclamationmark.triangle.fill');
            }
          }
          Future<void> importAndRefresh(Iterable<String> paths) async {
            final n = await _importLogoFiles(paths);
            if (n > 0) setInner(() {});
          }
          Future<void> importPasted() async {
            final bytes = await Pasteboard.image;
            final n = bytes == null ? 0 : await _importLogoBytes(bytes);
            if (n > 0) {
              setInner(() {});
            } else {
              await Native.toast('No image on the clipboard', symbol: 'exclamationmark.triangle.fill');
            }
          }
          return AlertDialog(
            title: const Text('Insert Logo'),
            content: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.keyV, meta: true): importPasted,
                if (!Platform.isMacOS) const SingleActivator(LogicalKeyboardKey.keyV, control: true): importPasted,
              },
              child: Focus(
                autofocus: true,
                child: SizedBox(
                  width: 520,
                  height: 420,
                  child: DropTarget(
                    onDragDone: (d) => importAndRefresh(d.files.map((f) => f.path)),
                    child: entries.isEmpty
                        ? Center(
                            child: Text('Drag or paste (⌘V) logo images here, or use “Add…”.',
                                textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)))
                        : GridView.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 120, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1),
                        itemCount: entries.length,
                        itemBuilder: (_, i) {
                          final (isAsset, path) = entries[i];
                          final name = path.split('/').last.replaceFirst(RegExp(r'\.[^.]+$'), '');
                          return Stack(
                            children: [
                              Positioned.fill(
                                child: Tooltip(
                                  message: name,
                                  waitDuration: const Duration(milliseconds: 400),
                                  child: InkWell(
                                    onTap: () => Navigator.pop(ctx, (isAsset, path)),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                          color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                                      child: isAsset
                                          ? Image.asset(path, fit: BoxFit.contain)
                                          : Image.file(File(path), fit: BoxFit.contain),
                                    ),
                                  ),
                                ),
                              ),
                              // Remove this logo: a user file is deleted; a built-in is hidden (restorable).
                              Positioned(
                                top: 2,
                                right: 2,
                                child: Tooltip(
                                  message: isAsset ? 'Hide this built-in logo' : 'Delete this logo',
                                  waitDuration: const Duration(milliseconds: 400),
                                  child: InkWell(
                                    onTap: () => remove(isAsset, path),
                                    customBorder: const CircleBorder(),
                                    child: Container(
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                          color: scheme.surface.withValues(alpha: 0.92),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: scheme.outlineVariant)),
                                      child: Icon(Icons.close, size: 13, color: scheme.onSurfaceVariant),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            actions: [
              if (hidden.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.restore, size: 16),
                  label: const Text('Restore built-ins'),
                  onPressed: () async {
                    hidden.clear();
                    await Native.setString('logos.hidden', '');
                    setInner(() {});
                  },
                ),
              TextButton.icon(
                icon: const Icon(Icons.content_paste, size: 16),
                label: const Text('Paste'),
                onPressed: importPasted,
              ),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add…'),
                onPressed: () async {
                  final r = await FilePicker.pickFiles(type: FileType.image, allowMultiple: true);
                  if (r != null) await importAndRefresh(r.files.map((f) => f.path).whereType<String>());
                },
              ),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            ],
          );
        },
      ),
    );
    if (picked == null) return;
    final (isAsset, path) = picked;
    try {
      final bytes = isAsset ? (await rootBundle.load(path)).buffer.asUint8List() : await File(path).readAsBytes();
      await addOverlayBytes(bytes);
    } catch (e, st) {
      debugPrint('Insert logo: $e\n$st');
      await Native.toast("Couldn't insert that logo", symbol: 'exclamationmark.triangle.fill');
    }
  }

  /// Opens the embedded Excalidraw whiteboard blank; its "Send to SnapNow" drops the result on the canvas.
  void _openWhiteboard() {
    _endTextEdit();
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ExcalidrawPage(onExport: addOverlayBytes),
    ));
  }

  /// Opens the current picture in the whiteboard to mark it up there; the result comes back as an overlay.
  Future<void> _openInWhiteboard() async {
    _endTextEdit();
    final s = _state;
    if (s == null) return;
    final png = await _flatPng();
    if (png == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ExcalidrawPage(
        capture: png,
        captureSize: Size(s.image.width.toDouble(), s.image.height.toDouble()),
        onExport: addOverlayBytes,
      ),
    ));
  }

  /// Grows the base canvas to fit every image overlay, shifting content if it spills past top/left.
  Future<CanvasState> _grownToFit(CanvasState s) async {
    var union = Rect.fromLTWH(0, 0, s.image.width.toDouble(), s.image.height.toDouble());
    final base = union;
    for (final a in s.annotations) {
      if (a.shape is ImageShape) {
        final r = a.rect;
        if (r != null) union = union.expandToInclude(r);
      }
    }
    if (union == base) return s;
    final newW = union.width.round(), newH = union.height.round();
    final shift = Offset(-union.left, -union.top);
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    c.drawImage(s.image, shift, Paint());
    final newImage = await recorder.endRecording().toImage(newW, newH);
    return s.copyWith(image: newImage, annotations: [for (final a in s.annotations) a.movedBy(shift)]);
  }

  Future<ui.Image> _flatten() async {
    final s = _state!;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    CanvasPainter(state: s, selectionId: null, scale: 1)
        .paint(canvas, Size(s.image.width.toDouble(), s.image.height.toDouble()));
    return recorder.endRecording().toImage(s.image.width, s.image.height);
  }

  /// Save As in a chosen format (macOS: native panel with a Format menu); the capture's own file is untouched.
  Future<void> saveAs() async {
    _endTextEdit();
    final png = await _flatPng();
    if (png == null) return;
    final name = _path?.split('/').last.replaceFirst(RegExp(r'\.[^.]+$'), '') ?? 'SnapNow';
    if (!Platform.isMacOS) {
      await FileSaver.instance.saveFile(name: name, bytes: png, fileExtension: 'png', mimeType: MimeType.png);
      return;
    }
    try {
      final saved = await Native.saveAs(png, name: name, density: _density);
      if (saved != null) await Native.toast('Saved ${saved.split('/').last}');
    } on PlatformException catch (e) {
      await Native.toast(e.message ?? "Couldn't save", symbol: 'exclamationmark.triangle.fill');
    }
  }

  /// Where to save the build-up GIF (the platform save panel); swapped out in tests.
  @visibleForTesting
  static Future<String?> Function(String fileName) pickGifPath = (fileName) => FilePicker.saveFile(
      dialogTitle: 'Save Animated GIF', fileName: fileName, type: FileType.custom, allowedExtensions: ['gif']);

  /// Save as Animated GIF: the original capture, then each addition appearing in the order it was made.
  Future<void> saveAnimatedGif() async {
    final s = await _gifState();
    if (s == null) return;
    try {
      var path = await pickGifPath('${_gifName()}.gif');
      if (path == null) return;
      if (!path.toLowerCase().endsWith('.gif')) path = '$path.gif';
      await Native.toast('Making GIF…', symbol: 'hourglass');
      await File(path).writeAsBytes(await BuildUpGif.render(s));
      await Native.toast('Saved ${path.split('/').last}');
    } catch (e, st) {
      debugPrint('GIF: $e\n$st');
      await Native.toast("Couldn't make the GIF", symbol: 'exclamationmark.triangle.fill');
    }
  }

  /// ⇧⌘C: the build-up GIF on the clipboard (marching ants keep moving in it; ⌘C is always the still). The file lives in a temp
  /// folder, since apps like Messages and Slack paste the file to keep it animated.
  Future<void> copyAnimatedGif() async {
    final s = await _gifState();
    if (s == null) return;
    try {
      await Native.toast('Making GIF…', symbol: 'hourglass');
      final dir = Directory('${Directory.systemTemp.path}/SnapNow GIFs')..createSync(recursive: true);
      final path = '${dir.path}/${_gifName()}.gif';
      final gif = await BuildUpGif.render(s);
      await File(path).writeAsBytes(gif, flush: true);
      await Native.copyGif(path);
      await Native.toast('Copied GIF');
      if (mounted) setState(() => _gifPreview = gif);
    } catch (e, st) {
      debugPrint('GIF: $e\n$st');
      await Native.toast("Couldn't make the GIF", symbol: 'exclamationmark.triangle.fill');
    }
  }

  /// ⌃⌘C: the build-up animation as a WhatsApp sticker. WhatsApp only animates stickers from installed
  /// packs, so it goes into SnapNow's pack and WhatsApp offers to add (or update) it. No markup = still sticker.
  Future<void> copySticker() async {
    _endTextEdit();
    final s = _state;
    if (s == null) return;
    if (s.annotations.isEmpty) return copyStillSticker();
    try {
      await Native.toast('Making sticker…', symbol: 'hourglass');
      final frames = await BuildUpGif.stickerFrames(s);
      final all = Uint8List(frames.fold(0, (n, f) => n + f.rgba.length));
      var at = 0;
      for (final f in frames) {
        all.setAll(at, f.rgba);
        at += f.rgba.length;
      }
      await Native.addWhatsAppSticker(all, [for (final f in frames) f.ms]);
      await Native.toast('Sent to WhatsApp: add it, then pick it from the SnapNow stickers');
    } on PlatformException catch (e) {
      await Native.toast(e.message ?? "Couldn't make the sticker", symbol: 'exclamationmark.triangle.fill');
    } catch (e, st) {
      debugPrint('Sticker: $e\n$st');
      await Native.toast("Couldn't make the sticker", symbol: 'exclamationmark.triangle.fill');
    }
  }

  /// The finished image as a still WhatsApp sticker on the clipboard (pastes into a chat as a sticker).
  Future<void> copyStillSticker() async {
    _endTextEdit();
    final png = await _flatPng();
    if (png == null) return;
    try {
      await Native.copySticker(png, name: _gifName());
      await Native.toast('Copied sticker');
    } catch (e, st) {
      debugPrint('Sticker: $e\n$st');
      await Native.toast("Couldn't make the sticker", symbol: 'exclamationmark.triangle.fill');
    }
  }

  /// The canvas to animate, or null (with a toast) when there's no markup to build up.
  Future<CanvasState?> _gifState() async {
    _endTextEdit();
    final s = _state;
    if (s == null) return null;
    if (s.annotations.isEmpty) {
      await Native.toast('Add some markup first', symbol: 'exclamationmark.triangle.fill');
      return null;
    }
    final fps = int.tryParse(await Native.getString('gifFps').catchError((_) => null) ?? '');
    BuildUpGif.fps = BuildUpGif.fpsChoices.contains(fps) ? fps! : 50; // Settings › GIF frame rate
    return s;
  }

  String _gifName() => _path?.split('/').last.replaceFirst(RegExp(r'\.[^.]+$'), '') ?? 'SnapNow';

  // ---- Canvas operations (flatten / flip / trim / crop / resize / color) ----

  Future<ui.Image> _cropImage(ui.Image src, Rect rect, {bool rounded = false}) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final dst = Rect.fromLTWH(0, 0, rect.width, rect.height);
    if (rounded) {
      c.clipRRect(RRect.fromRectAndRadius(dst, Radius.circular(math.min(rect.width, rect.height) * 0.025)));
    }
    c.drawImageRect(src, rect, dst, Paint());
    return rec.endRecording().toImage(rect.width.round(), rect.height.round());
  }

  Future<void> _crop(Rect rect, {bool rounded = false}) async {
    if (_state == null) return;
    final cropped = await _cropImage(_state!.image, rect, rounded: rounded);
    final shift = Offset(-rect.left, -rect.top);
    _commit(_state!.copyWith(image: cropped, annotations: [for (final a in _state!.annotations) a.movedBy(shift)]));
    setState(() { _selection = null; _tool = Tool.select; _cropHover = null; });
  }

  Future<void> _flattenInPlace() async {
    if (_state == null || _state!.annotations.isEmpty) return;
    final flat = await _flatten();
    _commit(_state!.copyWith(annotations: const [], image: flat));
    setState(() => _selection = null);
  }

  Future<void> _flipImage(bool horizontal) async {
    if (_state == null) return;
    final flat = await _flatten();
    final w = flat.width.toDouble(), h = flat.height.toDouble();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    if (horizontal) { c.translate(w, 0); c.scale(-1, 1); } else { c.translate(0, h); c.scale(1, -1); }
    c.drawImage(flat, Offset.zero, Paint());
    final out = await rec.endRecording().toImage(flat.width, flat.height);
    _commit(_state!.copyWith(annotations: const [], image: out));
    setState(() => _selection = null);
  }

  /// Bounding box (image coords) of pixels differing from the top-left corner colour.
  Future<Rect?> _contentRect(ui.Image image) async {
    final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return null;
    final b = bd.buffer.asUint8List();
    final w = image.width, h = image.height;
    int i(int x, int y) => (y * w + x) * 4;
    final br = b[0], bg = b[1], bb = b[2], ba = b[3];
    bool diff(int x, int y) {
      final k = i(x, y);
      return (b[k] - br).abs() + (b[k + 1] - bg).abs() + (b[k + 2] - bb).abs() + (b[k + 3] - ba).abs() > 30;
    }
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (diff(x, y)) { if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y; }
      }
    }
    if (maxX < minX || maxY < minY) return null;
    return Rect.fromLTRB(minX.toDouble(), minY.toDouble(), (maxX + 1).toDouble(), (maxY + 1).toDouble());
  }

  Future<void> _trim() async {
    if (_state == null) return;
    final flat = await _flatten();
    final rect = await _contentRect(flat);
    final full = Rect.fromLTWH(0, 0, flat.width.toDouble(), flat.height.toDouble());
    if (rect == null || rect == full) return;
    final cropped = await _cropImage(flat, rect);
    _commit(_state!.copyWith(annotations: const [], image: cropped));
    setState(() => _selection = null);
  }

  Future<void> _cropToCanvas() => _flattenInPlace(); // flatten clips everything to the canvas bounds

  Future<void> _resizeCanvasDialog() async {
    if (_state == null) return;
    final w0 = _state!.image.width, h0 = _state!.image.height;
    final wc = TextEditingController(text: '$w0'), hc = TextEditingController(text: '$h0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resize Canvas'),
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 80, child: TextField(controller: wc, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Width'))),
          const SizedBox(width: 12),
          SizedBox(width: 80, child: TextField(controller: hc, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Height'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Resize')),
        ],
      ),
    );
    if (ok != true) return;
    final w = (int.tryParse(wc.text) ?? w0).clamp(16, 10000);
    final h = (int.tryParse(hc.text) ?? h0).clamp(16, 10000);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(_state!.image, Offset.zero, Paint());
    final out = await rec.endRecording().toImage(w, h);
    _commit(_state!.copyWith(image: out)); // annotations keep their coordinates
  }

  Future<void> _changeCanvasColor() async {
    if (_state == null) return;
    final color = await _pickColor();
    if (color == null) return;
    // The canvas colour shows wherever the image doesn't cover the canvas (added space, transparent edges)
    _commit(_state!.copyWith(background: color));
  }

  Future<Color?> _pickColor() {
    final current = _state?.background.toARGB32();
    return showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Canvas Colour'),
        content: SizedBox(
          width: 300,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Fills the canvas around and behind the image — resize the canvas (drag its square handles) to add space.',
                style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final c in const [Color(0x00000000), Colors.white, Color(0xFFEEEEEE), Color(0xFF8E8E93), Colors.black,
                  Color(0xFF1E1E2E), ..._palette])
                Tooltip(
                  message: c.a == 0 ? 'Transparent (the capture as is)' : '',
                  child: GestureDetector(
                    onTap: () => Navigator.pop(ctx, c),
                    child: Container(
                      width: 30, height: 30,
                      decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.black26),
                          boxShadow: c.toARGB32() == current ? [BoxShadow(color: Theme.of(ctx).colorScheme.primary, spreadRadius: 2.5)] : null),
                      child: c.a == 0 ? ClipOval(child: CustomPaint(painter: _Checker())) : null,
                    ),
                  ),
                ),
            ]),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
  }

  Future<void> _showCanvasMenu(Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    // Same compact look as the toolbar's "More ▾" menus: icon + 13pt label, so nothing is clipped.
    PopupMenuItem<String> row(String value, IconData icon, String label) => PopupMenuItem(
          value: value,
          height: 32,
          child: Row(children: [
            Icon(icon, size: 17), const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 13)),
          ]),
        );
    final sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPos & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        row('flipH', Icons.swap_horiz, 'Flip Horizontal'),
        row('flipV', Icons.swap_vert, 'Flip Vertically'),
        const PopupMenuDivider(height: 8),
        row('trim', Icons.crop_free, 'Trim'),
        row('cropCanvas', Icons.crop, 'Crop to Canvas'),
        row('resize', Icons.aspect_ratio, 'Resize Canvas…'),
        row('color', Icons.format_color_fill, 'Change Canvas Colour…'),
        row('flatten', Icons.layers_clear, 'Flatten All'),
      ],
    );
    switch (sel) {
      case 'flipH': await _flipImage(true);
      case 'flipV': await _flipImage(false);
      case 'trim': await _trim();
      case 'cropCanvas': await _cropToCanvas();
      case 'resize': await _resizeCanvasDialog();
      case 'color': await _changeCanvasColor();
      case 'flatten': await _flattenInPlace();
    }
  }

  void _deleteSelection() {
    if (_selection == null) return;
    final ids = _selectedIds.toSet();
    final anns = [for (final a in _state!.annotations) if (!ids.contains(a.id)) a];
    _commit(_state!.copyWith(annotations: anns));
    setState(() { _selection = null; _group.clear(); });
  }

  /// A copy of `a` with a fresh id (for Paste/Duplicate); the shape is immutable, so it is shared until moved.
  Annotation _clone(Annotation a, int id) => Annotation(
      id: id, shape: a.shape, color: a.color, size: a.size, arrowStyle: a.arrowStyle, scale: a.scale, textFormat: a.textFormat);

  /// Puts the selected shapes on the editor's clipboard. Returns false when nothing is selected.
  bool _copySelection() {
    final ids = _selectedIds.toSet();
    if (ids.isEmpty) return false;
    _clip = [for (final a in _state!.annotations) if (ids.contains(a.id)) a];
    return true;
  }

  /// ⌘X: copy the selected shapes to the clipboard and remove them.
  void _cutSelection() {
    if (!_copySelection()) return;
    final ids = _selectedIds.toSet();
    _commit(_state!.copyWith(annotations: [for (final a in _state!.annotations) if (!ids.contains(a.id)) a]));
    setState(() { _selection = null; _group.clear(); });
  }

  /// Adds `copies` to the canvas and selects them (the first is the anchor, the rest its group).
  void _addAndSelect(List<Annotation> copies) {
    if (copies.isEmpty) return;
    _commit(_state!.copyWith(annotations: [..._state!.annotations, ...copies]));
    setState(() {
      _selection = copies.first.id;
      _group..clear()..addAll(copies.skip(1).map((a) => a.id));
      _imageSelected = false;
    });
  }

  /// ⌘V: paste the clipboard shapes, nudged a little so they are visible, and leave them selected. Repeated
  /// pastes cascade.
  void _pasteClipboard() {
    if (_clip.isEmpty) return;
    final copies = [for (final a in _clip) _clone(a, _nextId++).movedBy(const Offset(20, 20))];
    _addAndSelect(copies);
    _clip = copies;
  }

  /// ⌘D: duplicate the selected shapes in place (nudged) and select the copies.
  void _duplicateSelection() {
    final ids = _selectedIds.toSet();
    if (ids.isEmpty) return;
    final copies = [for (final a in _state!.annotations) if (ids.contains(a.id)) _clone(a, _nextId++).movedBy(const Offset(20, 20))];
    _addAndSelect(copies);
  }

  void _setTool(Tool t) {
    _endTextEdit();
    if (t == Tool.grabText) {
      _copyAllText();
      return;
    }
    setState(() {
      // R / O pick a rectangle / an ellipse unless the Shape tool already draws that kind's square / circle
      if (t == Tool.box && _shapeKind.oval) _shapeKind = ShapeKind.rectangle;
      if (t == Tool.ellipse && !_shapeKind.oval) _shapeKind = ShapeKind.ellipse;
      _tool = t; _selection = null; _group.clear();
      // Entering Crop starts with a frame around the whole image (edges ready to drag); other tools clear it.
      _cropRect = t == Tool.crop && _state != null ? _imageRect : null;
      _cropHandle = null; _cropHover = null;
    });
  }

  @override
  ShapeKind? get shapeKind {
    final a = selected;
    if (a != null) {
      final r = a.rect;
      final even = r != null && (r.width - r.height).abs() < 0.5;
      return switch (a.shape) {
        RectShape() => even ? ShapeKind.square : ShapeKind.rectangle,
        EllipseShape() => even ? ShapeKind.circle : ShapeKind.ellipse,
        _ => null,
      };
    }
    return _tool == Tool.box || _tool == Tool.ellipse ? _shapeKind : null;
  }

  /// Picks what the Shape tool draws; a selected box or ellipse changes to it (a square or circle keeps its centre).
  @override
  void pickShapeKind(ShapeKind k) {
    setState(() => _shapeKind = k);
    final a = selected;
    if (a != null && (a.shape is RectShape || a.shape is EllipseShape)) {
      var r = a.rect!;
      if (k.even) {
        final side = math.min(r.width, r.height);
        r = Rect.fromCenter(center: r.center, width: side, height: side);
      }
      _replace(a.copyWith(shape: k.oval ? EllipseShape(r) : RectShape(r)));
      return;
    }
    setState(() => _tool = k.tool);
  }

  @visibleForTesting
  int get annotationCount => _state?.annotations.length ?? 0;
  @visibleForTesting
  int get groupCount => _group.length;

  // ---- PanelHost (the properties panel) ----

  @override
  Annotation? get selected => _annotation(_selection);
  @override
  Tool get tool => _tool;
  @override
  Color get color => _color;
  @override
  StrokeSize get size => _size;

  @override
  StyleKind? get styleKind {
    final a = selected;
    return a != null ? a.styleKind : StyleKind.ofTool(_tool);
  }

  @override
  ArrowStyle get currentArrowStyle {
    final a = selected;
    if (a != null && a.styleKind != null) return a.arrowStyle;
    final k = styleKind;
    return k == null ? ArrowStyle.arrow : _styleFor(k);
  }

  @override
  bool get selectionIsCurved {
    final s = selected?.shape;
    return switch (s) {
      ArrowShape(:final points) || LineShape(:final points) => points.isNotEmpty,
      _ => false,
    };
  }

  /// Color picks also restyle the selection.
  @override
  void pickColor(Color c, {bool refresh = true}) {
    setState(() => _color = c);
    final a = selected;
    if (a != null && a.shape is! ImageShape) _restyleAll((x) => x.copyWith(color: c));
  }

  @override
  void openColorPanel() => Native.showColorPanel(_color.toARGB32() & 0xFFFFFF);

  @override
  void pickSize(StrokeSize s) {
    setState(() => _size = s);
    final a = selected;
    if (a == null) {
      if (isTextual) setTextFormat(textFormat.withPoints(null));
      if (styleKind != null) setArrowStyle(currentArrowStyle.withWidth(null)); // S / M / L replace a slider thickness
      return;
    }
    _restyleAll((x) => x.isTextual
        ? x.copyWith(size: s, textFormat: x.textFormat.withPoints(null))
        : x.styleKind != null
            ? x.copyWith(size: s, arrowStyle: x.arrowStyle.withWidth(null))
            : x.copyWith(size: s));
  }

  /// Restyles the selection (undoable) and makes the style the default for its kind.
  @override
  void setArrowStyle(ArrowStyle style) {
    final k = styleKind;
    if (k == null) return;
    final a = selected;
    if (a != null && a.styleKind != null) _restyleAll((x) => x.copyWith(arrowStyle: style));
    setState(() => _styleDefaults[k] = style);
    Native.setDataString('style.${k.name}', jsonEncode(style.toJson()));
  }

  /// Color, size and style together: to the selection as one undo step, and as the defaults.
  @override
  void applyQuickStyle(QuickStyle q) {
    setState(() { _color = q.colorValue; _size = q.size; });
    final k = styleKind;
    if (k != null) {
      _styleDefaults[k] = q.style;
      Native.setDataString('style.${k.name}', jsonEncode(q.style.toJson()));
    }
    final a = selected;
    if (a == null) return;
    _restyleAll((x) => x.copyWith(color: q.colorValue, size: q.size, arrowStyle: x.styleKind != null ? q.style : null,
        textFormat: x.isTextual ? x.textFormat.withPoints(null) : null));
  }

  @override
  void straighten() {
    final a = selected;
    switch (a?.shape) {
      case ArrowShape(:final from, :final to):
        _replace(a!.copyWith(shape: ArrowShape(from, to)));
      case LineShape(:final from, :final to):
        _replace(a!.copyWith(shape: LineShape(from, to)));
      default:
        break;
    }
  }

  @override
  void resetStyle() {
    final k = styleKind;
    if (k != null) setArrowStyle(k.builtIn);
  }

  @override
  void copyAllText() => _copyAllText();

  @override
  Future<void> saveCurrentStyle() async {
    final a = selected;
    final kind = a != null ? QuickKind.of(a) : QuickKind.ofTool(_tool);
    if (kind == null) return;
    await QuickStyles.save(QuickStyle(_color.toARGB32() & 0xFFFFFF, _size, currentArrowStyle), kind);
    setState(() {});
    await Native.toast('Saved to My Styles', symbol: 'star.fill');
  }

  @override
  Future<void> clearSavedStyles() async {
    final a = selected;
    final kind = a != null ? QuickKind.of(a) : QuickKind.ofTool(_tool);
    if (kind == null) return;
    await QuickStyles.clear(kind);
    setState(() {});
  }

  /// Applies the same change to every selected shape (anchor + its ⌘A group) as one undo step. With no group
  /// it falls back to [_restyleSelected] (which keeps an inline text field focused while typing).
  void _restyleAll(Annotation Function(Annotation a) change) {
    final anchor = _annotation(_selection);
    if (anchor == null) return;
    if (_group.isEmpty) return _restyleSelected(change(anchor));
    final ids = _selectedIds.toSet();
    _commit(_state!.copyWith(annotations: [for (final x in _state!.annotations) ids.contains(x.id) ? change(x) : x]));
  }

  /// Restyles the selection: one undo step normally; while it is being typed into, part of the typing
  /// session (and the text field keeps the keyboard).
  void _restyleSelected(Annotation next) {
    if (_textEdit?.id == next.id) {
      setState(() => _state = _state!.copyWith(annotations: [for (final x in _state!.annotations) x.id == next.id ? next : x]));
      WidgetsBinding.instance.addPostFrameCallback((_) => _textFocus.requestFocus());
    } else {
      _replace(next);
    }
  }

  /// The highlighted characters of the text being typed into (empty when nothing is highlighted).
  @override
  List<CharStyle> get selectedChars {
    if (_formatBarTarget == null) return const [];
    final sel = _textController.selection;
    return TextRuns.expand(_textController.text.length, _textController.runs).sublist(sel.start, sel.end);
  }

  /// Colour / bold / italic / underline on just the highlighted characters (part of the typing session).
  @override
  void styleSelection(CharStyle Function(CharStyle) change) {
    final sel = _textController.selection;
    if (_textEdit == null || !sel.isValid || sel.isCollapsed) return;
    _textController.setRuns(TextRuns.apply(_textController.text.length, _textController.runs, sel.start, sel.end, change));
    WidgetsBinding.instance.addPostFrameCallback((_) => _textFocus.requestFocus());
  }

  @override
  bool get isTextual => selected?.isTextual ?? (_tool == Tool.text || _tool == Tool.callout);
  @override
  bool get isCallout => selected != null ? selected!.shape is CalloutShape : _tool == Tool.callout;

  @override
  TextFormat get textFormat {
    final a = selected;
    if (a != null && a.isTextual) return a.textFormat;
    return _formatFor(_tool == Tool.callout ? 'callout' : 'text');
  }

  /// Applies to the selected text/callout (live while typing) and becomes that tool's default.
  @override
  void setTextFormat(TextFormat f) {
    final a = selected;
    final kind = a != null && a.isTextual ? _textKind(a) : (_tool == Tool.callout ? 'callout' : 'text');
    if (a != null && a.isTextual) _restyleAll((x) => x.copyWith(textFormat: f));
    setState(() => _textFormats[kind] = f);
    Native.setDataString('style.textFormat.$kind', jsonEncode(f.toJson()));
  }

  // ---- UI ----

  /// Single-key tool shortcuts, as in the Swift app.
  static final _toolKeys = <LogicalKeyboardKey, Tool>{
    LogicalKeyboardKey.keyV: Tool.select, LogicalKeyboardKey.keyA: Tool.arrow, LogicalKeyboardKey.keyL: Tool.line,
    LogicalKeyboardKey.keyR: Tool.box, LogicalKeyboardKey.keyO: Tool.ellipse, LogicalKeyboardKey.keyP: Tool.pen,
    LogicalKeyboardKey.keyH: Tool.highlight, LogicalKeyboardKey.keyT: Tool.text, LogicalKeyboardKey.keyK: Tool.callout,
    LogicalKeyboardKey.keyN: Tool.step, LogicalKeyboardKey.keyB: Tool.blur, LogicalKeyboardKey.keyS: Tool.spotlight,
    LogicalKeyboardKey.keyC: Tool.crop, LogicalKeyboardKey.keyG: Tool.grabText,
  };

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return CallbackShortcuts(
      bindings: (_textEdit != null || _editingDims) ? const {} : {
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undoAction,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): _redoAction,
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _copyImage,
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true): copyAnimatedGif,
        if (Platform.isMacOS) const SingleActivator(LogicalKeyboardKey.keyC, meta: true, control: true): copySticker,
        const SingleActivator(LogicalKeyboardKey.keyX, meta: true): _cutSelection,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _pasteClipboard,
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true): _duplicateSelection,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true): saveAs,
        _cmd(LogicalKeyboardKey.equal): zoomIn,
        _cmd(LogicalKeyboardKey.equal, shift: true): zoomIn, // ⌘+ on keyboards where + needs Shift
        _cmd(LogicalKeyboardKey.minus): zoomOut,
        _cmd(LogicalKeyboardKey.digit0): zoomToFit,
        _cmd(LogicalKeyboardKey.digit1): zoomActualSize,
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): openImageDialog,
        SingleActivator(LogicalKeyboardKey.keyT, meta: Platform.isMacOS, control: !Platform.isMacOS, alt: true):
            () => _setPinned(!_pinned),
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): AppController.instance.onWindowClose,
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): _selectAllSimilar,
        const SingleActivator(LogicalKeyboardKey.delete): _deleteSelection,
        const SingleActivator(LogicalKeyboardKey.backspace): _deleteSelection,
        if (_cropRect != null) ...{
          const SingleActivator(LogicalKeyboardKey.enter): _applyCrop,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): _applyCrop,
          const SingleActivator(LogicalKeyboardKey.escape): _cancelCrop,
        },
        for (final e in _toolKeys.entries) SingleActivator(e.key): () => _setTool(e.value),
      },
      child: Focus(focusNode: _focus, autofocus: true, child: _scaffold(state)),
    );
  }

  /// The window is the canvas: the picture sits on a plain backdrop and every control floats over it — the
  /// toolbar card at the top, the properties card on the right, the zoom pill in the corner.
  Widget _scaffold(CanvasState? state) {
    final chrome = SnapChrome.of(context);
    const m = _chromeMargin;
    final inspectorRoom = _inspectorShown ? PropertiesPanel.width + m : 0.0;
    final dragging = _toolbarDragAt != null;
    final primary = Theme.of(context).colorScheme.primary;
    // The toolbar's dock: the strip down the left edge, or across the top of what the inspector leaves free
    Positioned dock(bool left, Widget child) => left
        ? Positioned(top: m, left: m, bottom: m + widget.chromeInsets.bottom, width: _toolbarLeftWidth, child: child)
        : Positioned(top: m, left: m, right: m + inspectorRoom, height: _toolbarHeight, child: child);
    final scaffold = Scaffold(
      backgroundColor: widget.overlay ? Colors.transparent : chrome.backdrop, // draw mode: a clear glass over the live screen
      body: LayoutBuilder(builder: (context, c) => Stack(key: _chromeKey, children: [
        Positioned.fill(child: state == null ? const Center(child: CircularProgressIndicator()) : _canvasArea(state)),
        // The toolbar card, centred in its dock; dimmed while its grip is being dragged
        dock(_toolbarLeft, Opacity(opacity: dragging ? 0.35 : 1, child: Center(child: KeyedSubtree(key: _glassToolbarKey, child: _toolbar())))),
        if (_inspectorShown)
          Positioned(
            top: m,
            right: m,
            bottom: m + widget.chromeInsets.bottom,
            child: KeyedSubtree(key: _glassPanelKey, child: PropertiesPanel(host: this, onClose: _toggleInspector)),
          ),
        if (_toolbarDragAt case final at?) ...[
          // The dock the drop would land in, lit up
          if (_toolbarDropLeft case final left?)
            dock(left, IgnorePointer(child: Container(decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.12),
              border: Border.all(color: primary.withValues(alpha: 0.7)),
              borderRadius: BorderRadius.circular(14),
            )))),
          // A ghost of the card follows the pointer, already turned the way the dock under it would hold it.
          // Along its own axis it slides with the pointer but stays inside the window (aligned in proportion).
          if (_toolbarDropLeft ?? _toolbarLeft)
            Positioned(
              left: at.dx - 12, top: m, bottom: m + widget.chromeInsets.bottom,
              child: IgnorePointer(child: Align(
                alignment: Alignment(-1, (at.dy / math.max(1, c.maxHeight)).clamp(0, 1) * 2 - 1),
                child: Opacity(opacity: 0.9, child: _toolbar(vertical: true, ghost: true)),
              )),
            )
          else
            Positioned(
              top: at.dy - 12, left: m, right: m + inspectorRoom,
              child: IgnorePointer(child: Align(
                alignment: Alignment((at.dx / math.max(1, c.maxWidth)).clamp(0, 1) * 2 - 1, -1),
                child: Opacity(opacity: 0.9, child: _toolbar(vertical: false, ghost: true)),
              )),
            ),
        ],
      ])),
    );
    return widget.overlay ? _glassTheme(scaffold) : scaffold;
  }

  // ---- Draw mode glass ----
  final _glassToolbarKey = GlobalKey(), _glassPanelKey = GlobalKey();
  int _glassLevel = 100; // Settings › Draw mode › Glass, in percent (read when draw mode opens)

  /// The cards in draw mode are clear glass: their fill is a light tint (theme-coloured), and the blur behind them
  /// is a native frosted layer the window draws under Flutter, masked to these rectangles (the desktop is not
  /// visible to Flutter, so BackdropFilter cannot blur it).
  Widget _glassTheme(Widget child) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    _ToolButton.glass = true;
    final tint = (100 - _glassLevel) / 100.0;            // 0 = clear glass ... 1 = solid card
    Color mix(Color c, double clear, double solid) => c.withValues(alpha: clear + (solid - clear) * tint);
    final glass = SnapChrome.of(context).copyWith(
      card: mix(dark ? const Color(0xFF14161C) : const Color(0xFFFFFFFF), 0.04, 0.96),
      border: dark ? Color.fromARGB((0x33 + (0x40 * tint)).round(), 255, 255, 255) : Color.fromARGB((0x80 - (0x50 * tint)).round(), 255, 255, 255),
      shadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 6))],
      control: mix(dark ? const Color(0xFFFFFFFF) : const Color(0xFFFFFFFF), 0.12, dark ? 0.10 : 0.9),
      controlBorder: dark ? const Color(0x33FFFFFF) : const Color(0x33000000),
      raised: mix(const Color(0xFFFFFFFF), 0.25, dark ? 0.18 : 1.0),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportGlass(dark));
    // Secondary text and icons at full strength: on glass they have no solid card behind them to stand out from
    final scheme = theme.colorScheme.copyWith(onSurfaceVariant: theme.colorScheme.onSurface);
    return Theme(data: theme.copyWith(extensions: [glass], colorScheme: scheme), child: child);
  }

  void _reportGlass(bool dark) {
    if (!mounted) return;
    final rects = <List<double>>[];
    for (final key in [_glassToolbarKey, _glassPanelKey]) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final o = box.localToGlobal(Offset.zero);
      rects.add([o.dx, o.dy, box.size.width, box.size.height, SnapChrome.radius]);
    }
    Native.glassRects(_glassLevel == 0 ? const [] : rects, dark: dark); // solid cards need no frost behind them
  }

  /// The canvas: the image centred with a soft shadow, and one full-size input/paint layer over the whole
  /// area, so the canvas handles (just outside the image) and drags past its edges work.
  Widget _canvasArea(CanvasState state) {
    _syncMarch(state);
    return LayoutBuilder(builder: (context, constraints) {
      final pad = widget.overlay ? 0.0 : 20.0, labelGap = widget.overlay ? 0.0 : 34.0; // labelGap: room under the image for the editable dimensions
      final iw = state.image.width.toDouble(), ih = state.image.height.toDouble();
      // Display at the ORIGINAL capture's footprint, so reducing the pixel count (for a smaller file) makes
      // the picture grainier without shrinking it on the canvas. Falls back to the current size pre-load.
      final dw = _originalSize?.width ?? iw, dh = _originalSize?.height ?? ih;
      final view = Size(constraints.maxWidth, constraints.maxHeight);
      // The picture is fitted into the area the floating chrome leaves free (toolbar above, inspector at the
      // right, the host's filmstrip below); zoomed in, it may pan under the chrome, which is translucent.
      final ins = _chromeInsets;
      final free = Size(math.max(1, view.width - ins.horizontal), math.max(1, view.height - ins.vertical));
      _viewSize = view;
      _viewInsets = ins;
      final fit = math.max(0.01, math.min(math.min((free.width - pad * 2) / dw, (free.height - pad * 2 - labelGap) / dh), 1.0));
      // image→view scale that fills that footprint with however many pixels the image now has, PER AXIS, so a
      // width-only (or height-only) pixel change keeps both the width and the height of the picture on screen
      // (it just gets grainier on the reduced axis) instead of stretching the other one. A manual zoom is
      // uniform (same on both axes), so it never distorts.
      final scaleX = _zoom ?? (dw * fit / iw);
      final scaleY = _zoom ?? (dh * fit / ih);
      final scale = scaleX; // representative scale for hit-test tolerances / zoom readout
      final fitted = Size(iw * scaleX, ih * scaleY); // == (dw*fit, dh*fit): the original footprint on both axes
      final centred = _centredOrigin(Size(iw, ih), scaleX, scaleY);
      // Centred on an axis where the image fits; otherwise pannable, but never further than its edge + pad
      double axis(double c, double p, double start, double freeLen, double len) =>
          len + pad * 2 <= freeLen ? c : (c + p).clamp(start + freeLen - len - pad, start + pad).toDouble();
      final origin = Offset(axis(centred.dx, _pan.dx, ins.left, free.width, fitted.width),
          axis(centred.dy, _pan.dy, ins.top, free.height, fitted.height));
      _pan = origin - centred; // drop pan that the clamp swallowed, so panning back responds at once
      _viewScale = scale;
      _viewScaleY = scaleY;
      _viewOrigin = origin;
      Offset toImage(Offset local) => Offset((local.dx - origin.dx) / scaleX, (local.dy - origin.dy) / scaleY);
      final kind = StyleKind.ofTool(_tool);
      return ClipRect(child: DragTarget<String>(
        // A filmstrip thumbnail dropped anywhere over the canvas area
        onWillAcceptWithDetails: (d) => !d.data.toLowerCase().endsWith('.mov') && !d.data.toLowerCase().endsWith('.mp4'),
        onAcceptWithDetails: (d) => addOverlayFile(d.data, globalPosition: d.offset + const Offset(64, 48)),
        builder: (context, candidates, _) => Container(
          decoration: candidates.isEmpty ? null : BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2)),
          child: Stack(children: [
            Positioned(
              left: origin.dx, top: origin.dy, width: fitted.width, height: fitted.height,
              child: Container(
                key: _canvasKey,
                decoration: widget.overlay ? null : const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 3))]),
              ),
            ),
            Positioned.fill(
              child: MouseRegion(
                cursor: _tool == Tool.crop
                    ? _cropCursor
                    : _tool == Tool.select ? SystemMouseCursors.basic : SystemMouseCursors.precise,
                child: GestureDetector(
                  onSecondaryTapUp: (d) => _showCanvasMenu(d.globalPosition),
                  child: Listener(
                    key: const ValueKey('snaplite-canvas'), // for widget tests
                    behavior: HitTestBehavior.opaque,
                    onPointerHover: (e) { if (_tool == Tool.crop) _hoverCrop(toImage(e.localPosition)); },
                    onPointerDown: (e) {
                      _focus.requestFocus();
                      if (_startsPan(e)) {
                        _panGrab = e.localPosition;
                      } else if (e.buttons == 1) {
                        _down(toImage(e.localPosition));
                      }
                    },
                    onPointerMove: (e) {
                      if (_panGrab case final grab?) {
                        _panBy(e.localPosition - grab);
                        _panGrab = e.localPosition;
                      } else {
                        _move(toImage(e.localPosition));
                      }
                    },
                    onPointerUp: (e) {
                      if (_panGrab != null) {
                        _panGrab = null;
                      } else {
                        _up(toImage(e.localPosition));
                      }
                    },
                    onPointerSignal: _onPointerSignal,
                    onPointerPanZoomStart: _onPanZoomStart,
                    onPointerPanZoomUpdate: _onPanZoomUpdate,
                    child: Stack(children: [
                      // The picture with its committed annotations, rasterised once and kept (RepaintBoundary)
                      // until the state, zoom or an animation changes it. Pointer moves, live previews, handles
                      // and marching ants only redraw the overlay on top, which matters on a big display where the
                      // picture is tens of megapixels and blur patches and shadows are costly to re-render.
                      Positioned(
                        left: origin.dx, top: origin.dy, width: fitted.width, height: fitted.height,
                        child: ClipRect(child: RepaintBoundary(child: CustomPaint(
                          isComplex: true,
                          painter: CanvasPainter(state: state, selectionId: null, scale: scale, scaleY: scaleY,
                              hiddenTextId: _textEdit?.id, march: _march, epicycles: _playId != null && BuildUpGif.fourier,
                              envelope: _playId != null && BuildUpGif.envelope,
                              animate: state.annotations.any((a) => a.styleKind != null && a.arrowStyle.pattern.marches),
                              progress: _playId == null ? null : {for (final a in state.annotations) a.id: a.id == _playId ? _playT : 1.0}),
                        ))),
                      ),
                      Positioned.fill(child: CustomPaint(
                      painter: _PreviewPainter(
                        base: CanvasPainter(state: state, selectionId: _playId == null ? _selection : null, scale: scale, scaleY: scaleY,
                            hiddenTextId: _textEdit?.id, march: _march, epicycles: _playId != null && BuildUpGif.fourier,
                              envelope: _playId != null && BuildUpGif.envelope,
                            progress: _playId == null ? null : {for (final a in state.annotations) a.id: a.id == _playId ? _playT : 1.0}),
                        origin: origin,
                        tool: _tool, color: _color, size: _size, scale: scale, scaleY: scaleY,
                        style: kind == null ? ArrowStyle.arrow : _styleFor(kind),
                        createStart: _createStart, createCurrent: _createCurrent, penPoints: _penPoints,
                        follow: _createStart == null || _createCurrent == null ? null : _follow(_createStart!, _createCurrent!),
                        canvasChrome: _showsCanvasHandles || _canvasDrag != null,
                        ants: _copied ? _ants : null,
                        march: _march,
                        canvasResize: _canvasDrag?.$2,
                        fourier: BuildUpGif.fourier,
                        envelope: BuildUpGif.envelope,
                        trail: _trail == null || _createCurrent == null ? null : [..._trail!, _createCurrent!],
                        guides: _guides,
                        boundsOfSelection: _textEdit != null || selected == null || selected!.rect != null ? null : _bounds(selected!),
                        groupBoxes: _selection != null && _group.isNotEmpty ? _groupBoxes() : null,
                        cropRect: _cropRect,
                      ),
                      )),
                    ]),
                  ),
                ),
              ),
            ),
            // The image's own pixel size, centred just under it — editable to resize the canvas.
            if (!widget.overlay) Positioned(
              left: origin.dx, top: origin.dy + fitted.height + 4, width: fitted.width,
              child: Center(
                child: _CanvasDimsEditor(
                  width: state.image.width,
                  height: state.image.height,
                  bytesLabel: _imageBytes == null ? null : _fmtBytes(_imageBytes!),
                  originalWidth: _originalSize?.width.round(),
                  originalHeight: _originalSize?.height.round(),
                  onApply: (w, h) => _scaleCanvasTo(w, h),
                  onFocusChange: (f) { if (f != _editingDims) setState(() => _editingDims = f); },
                ),
              ),
            ),
            if (_textEdit != null) _textEditor(origin, scale),
            if (_formatBarTarget case final a?) _formatBar(a, origin, scale, Size(constraints.maxWidth, constraints.maxHeight)),
            if (_thicknessTarget case final a?) _thicknessSlider(a, origin, scale, Size(constraints.maxWidth, constraints.maxHeight)),
            if (_colorBarTarget case final a?) _colorBar(a, origin, scale, Size(constraints.maxWidth, constraints.maxHeight)),
            Positioned(right: ins.right + 12, bottom: ins.bottom + 12, child: _zoomPill()),
            if (_gifPreview case final gif?) Positioned.fill(child: _gifPreviewCard(gif)),
          ]),
        ),
      ));
    });
  }

  /// The copied GIF playing over the dimmed canvas, so you see what you'll paste; a click or Esc closes it.
  Widget _gifPreviewCard(Uint8List gif) {
    final scheme = Theme.of(context).colorScheme;
    void close() => setState(() => _gifPreview = null);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(
        autofocus: true,
        child: GestureDetector(
          key: const ValueKey('snaplite-gif-preview'),
          behavior: HitTestBehavior.opaque,
          onTap: close,
          child: ColoredBox(
            // Opaque, so the live editor canvas (the same capture) doesn't ghost through behind the GIF.
            color: const Color(0xFF17171A),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Flexible(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 4))]),
                    child: Image.memory(gif, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium),
                  ),
                ),
                const SizedBox(height: 12),
                Material(
                  color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
                  shape: const StadiumBorder(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Text('Copied as animated GIF: paste it anywhere, or Share (top-right) to AirDrop it  ·  Esc to close',
                        style: TextStyle(fontSize: 12, color: scheme.onSurface)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// − / percent / + in the corner; clicking the percent switches between Fit and 100%.
  Widget _zoomPill() {
    final scheme = Theme.of(context).colorScheme;
    final label = _zoomed ? '${zoomPercent.round()}%' : 'Fit';
    Widget icon(IconData i, String tip, VoidCallback onTap) => IconButton(
        icon: Icon(i, size: 16), tooltip: tip, onPressed: onTap, visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28), padding: EdgeInsets.zero);
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl+';
    return Container(
      key: const ValueKey('snaplite-zoom'),
      decoration: SnapChrome.of(context).pill(),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            icon(Icons.remove, 'Zoom out ($mod−)', zoomOut),
            InkWell(
              onTap: _zoomed ? zoomToFit : zoomActualSize,
              customBorder: const StadiumBorder(),
              child: Tooltip(
                message: _zoomed ? 'Fit to window (${mod}0)' : 'Actual size (${mod}1)',
                child: SizedBox(width: 48, child: Text(label, textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, fontFeatures: const [FontFeature.tabularFigures()], color: scheme.onSurface))),
              ),
            ),
            icon(Icons.add, 'Zoom in ($mod+)', zoomIn),
          ]),
        ),
      ),
    );
  }

  /// The path a new arrow or line takes when it follows the drag (null when not following, or too short):
  /// a true circular arc when the drag is close to one (anything curved one way), otherwise a smooth
  /// least-squares curve through the drag (smoothed first, each point averaged with its neighbours) with as
  /// few bends as keep it within a few points of the drag, at most 4; hand wobble is fitted away.
  ({Offset from, Offset to, List<Offset> points, List<Offset?> tangents})? _follow(Offset start, Offset end) {
    final t = _trail;
    if (t == null || t.length < 3) return null;
    final pts = CurveFit.smoothed([...t, end]);
    // Nearly straight stays straight
    final chord = pts.last - pts.first, chordLen = chord.distance;
    var bulge = 0.0;
    for (final q in pts) {
      final v = q - pts.first;
      bulge = math.max(bulge, chordLen == 0 ? v.distance : (chord.dx * v.dy - chord.dy * v.dx).abs() / chordLen);
    }
    if (bulge < math.max(3 / _viewScale, chordLen * 0.02)) return null;
    final arc = _arc(pts);
    if (arc != null) return arc;
    // Within 5 screen points (or 3% of the chord on a long drag) of the drag: a shape you drew stays, a
    // shaky hand does not
    final f = CurveFit.fit(pts, math.max(5 / _viewScale, chordLen * 0.03));
    return (from: start, to: end, points: f.points.sublist(1, f.points.length - 1), tangents: f.tangents);
  }

  /// A circular arc through the drag, if it's close to one: a least-squares circle (Kåsa) that the points
  /// stay within 7% of, bending at least 25°. Drawn as Bézier pieces of at most 90° whose handles are the
  /// circle's (4/3·tan(θ/4)·r), so it's a true arc; the ends sit on the circle.
  ({Offset from, Offset to, List<Offset> points, List<Offset?> tangents})? _arc(List<Offset> pts) {
    final n = pts.length;
    if (n < 5) return null;
    // A circle through the drag's own ends (so they stay exactly where you pressed and let go): its centre is
    // on their perpendicular bisector; each point picks a centre there, and the median wins
    final a = pts.first, b = pts.last, mid = (a + b) / 2, half = (b - a).distance / 2;
    if (half < 1e-6) return null;
    final normal = Offset(-(b - a).dy, (b - a).dx) / (2 * half);
    final picks = <double>[];
    for (final q in pts.sublist(1, n - 1)) {
      final v = q - mid, along = v.dx * normal.dx + v.dy * normal.dy;
      if (along.abs() < 1e-6) continue;
      picks.add((v.distanceSquared - half * half) / (2 * along));
    }
    if (picks.length < 3) return null;
    picks.sort();
    final c = mid + normal * picks[picks.length ~/ 2];
    final r = (a - c).distance;
    var err = 0.0;
    for (final q in pts) {
      final e = (q - c).distance - r;
      err += e * e;
    }
    if (math.sqrt(err / n) > r * 0.07) return null;

    // Which way round, and how far: from the start's angle to the end's, the way the middle of the drag went
    double ang(Offset q) => math.atan2(q.dy - c.dy, q.dx - c.dx);
    double wrap(double x) => (x % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
    final a0 = ang(pts.first), a1 = ang(pts.last), am = ang(pts[n ~/ 2]);
    final ccw = wrap(a1 - a0);
    final sweep = wrap(am - a0) < ccw ? ccw : ccw - 2 * math.pi;
    if (sweep.abs() < 25 * math.pi / 180 || sweep.abs() > 350 * math.pi / 180) return null;

    final pieces = (sweep.abs() / (math.pi / 2)).ceil();
    final step = sweep / pieces;
    final len = 4 * r * math.tan(step.abs() / 4); // |tangent| = 3 × the Bézier handle
    final dir = sweep.sign;
    final on = [for (var i = 0; i <= pieces; i++) c + Offset(math.cos(a0 + step * i), math.sin(a0 + step * i)) * r];
    final tg = <Offset?>[
      for (var i = 0; i <= pieces; i++)
        Offset(-math.sin(a0 + step * i), math.cos(a0 + step * i)) * (len * dir),
    ];
    return (from: a, to: b, points: on.sublist(1, on.length - 1), tangents: tg);
  }

  @override
  bool get followDrag => _followDrag;

  @override
  void setFollowDrag(bool on) {
    setState(() => _followDrag = on);
    Native.setBool('followDrag', on);
  }

  @override
  Entrance get gifEntrance => BuildUpGif.entrance;

  @override
  void setGifEntrance(Entrance e) {
    setState(() => BuildUpGif.entrance = e);
    Native.setString('gifEntrance', e.name);
  }



  @override
  int get gifMaxSide => BuildUpGif.maxSide;

  @override
  void setGifMaxSide(int px) {
    setState(() => BuildUpGif.setMaxSide(px));
    Native.setString('gifMaxSide', '${BuildUpGif.maxSide}'); // persist the clamped value
  }

  /// Clicking an arrow, line, box, ellipse or pen stroke shows the thickness slider beside it.
  Annotation? get _thicknessTarget {
    final a = selected;
    return a != null && a.styleKind != null && _dragId == null && _textEdit == null ? a : null;
  }

  /// The area an annotation covers (image coords), for placing things beside it.
  Rect _boxOf(Annotation a) {
    final pts = a.curve ?? switch (a.shape) { PenShape(:final points) => points, _ => null };
    if (pts == null || pts.isEmpty) return a.rect ?? Rect.zero;
    final samples = a.curve != null ? CanvasPainter.curveSamples(pts, tangents: a.curveTangents) : pts;
    var r = Rect.fromPoints(samples.first, samples.first);
    for (final p in samples) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r;
  }

  CanvasState? _thicknessSnapshot; // state before a slider drag, for one undo step

  /// The part of the canvas area not under floating chrome, where the floating bars are kept.
  Rect _freeRect(Size area) => _viewInsets.deflateRect(Offset.zero & area);

  Widget _thicknessSlider(Annotation a, Offset origin, double scale, Size area) {
    final b = _boxOf(a);
    final box = Rect.fromLTRB(origin.dx + b.left * scale, origin.dy + b.top * scale, origin.dx + b.right * scale,
        origin.dy + b.bottom * scale);
    const w = _ThicknessCard.width, gap = 14.0;
    final free = _freeRect(area);
    // As tall as the window allows (up to the preferred height): a long track makes fine-tuning easy
    final h = math.min(_ThicknessCard.height, math.max(_ThicknessCard.minHeight, free.height - 16));
    var left = box.right + gap;
    if (left + w > free.right - 8) left = box.left - gap - w;
    left = left.clamp(free.left + 8, math.max(free.left + 8, free.right - w - 8));
    final top = (box.center.dy - h / 2).clamp(free.top + 8, math.max(free.top + 8, free.bottom - h - 8)).toDouble();
    return Positioned(
      left: left,
      top: top,
      child: _ThicknessCard(
        cardHeight: h,
        value: (a.arrowStyle.width ?? a.size.line).clamp(1.0, 40.0),
        color: a.color,
        onStart: () => _thicknessSnapshot = _state,
        onChanged: _setThickness,
        onEnd: () {
          final before = _thicknessSnapshot;
          _thicknessSnapshot = null;
          if (before != null && !identical(before, _state)) {
            _undo.add(before);
            _redo.clear();
          }
          final k = selected?.styleKind;
          if (k != null) Native.setDataString('style.${k.name}', jsonEncode(_styleFor(k).toJson())); // remembered
        },
      ),
    );
  }

  /// Live while the slider moves: restyles the selection and becomes the default for its kind.
  void _setThickness(double points) {
    final a = selected;
    final k = a?.styleKind;
    if (a == null || k == null) return;
    final style = a.arrowStyle.withWidth(points);
    _replace(a.copyWith(arrowStyle: style), snapshot: false);
    setState(() => _styleDefaults[k] = style);
  }

  /// Clicking anything that has a colour shows the colour bar above it (as in Snagit).
  Annotation? get _colorBarTarget {
    final a = selected;
    if (a == null || _dragId != null || _textEdit != null) return null;
    return a.shape is BlurShape || a.shape is SpotlightShape || a.shape is ImageShape ? null : a;
  }

  /// The colour bar sits centred above the annotation (below if there's no room), inside the canvas area.
  Widget _colorBar(Annotation a, Offset origin, double scale, Size area) {
    final b = _boxOf(a);
    final box = Rect.fromLTRB(origin.dx + b.left * scale, origin.dy + b.top * scale, origin.dx + b.right * scale,
        origin.dy + b.bottom * scale);
    final lines = a.styleKind == StyleKind.arrow || a.styleKind == StyleKind.line;
    final w = _ColorBar.widthFor(lines), h = _ColorBar.heightFor(lines);
    const gap = 12.0;
    var top = box.top - gap - h;
    if (top < 8) top = box.bottom + gap;
    final free = _freeRect(area);
    top = top.clamp(free.top + 8, math.max(free.top + 8, free.bottom - h - 8));
    final left = (box.center.dx - w / 2).clamp(free.left + 8, math.max(free.left + 8, free.right - w - 8)).toDouble();
    return Positioned(
      left: left,
      top: top,
      child: _ColorBar(selected: a.color, onPick: pickColor, onMore: openColorPanel,
          style: lines ? a.arrowStyle : null, onStyle: setArrowStyle),
    );
  }

  /// The format bar appears only while some of the typed text is highlighted (like a mini toolbar).
  Annotation? get _formatBarTarget {
    final e = _textEdit;
    if (e == null) return null;
    final sel = _textController.selection;
    if (!sel.isValid || sel.isCollapsed) return null;
    return _annotation(e.id);
  }

  /// The format bar sits just right of the text (left if there's no room), kept inside the canvas area.
  Widget _formatBar(Annotation a, Offset origin, double scale, Size area) {
    final b = _bounds(a) ?? Rect.zero;
    final box = Rect.fromLTRB(origin.dx + b.left * scale, origin.dy + b.top * scale, origin.dx + b.right * scale,
        origin.dy + b.bottom * scale);
    const gap = 12.0, width = TextFormatBar.width, height = 120.0;
    var left = box.right + gap;
    final free = _freeRect(area);
    if (left + width > free.right - 8) left = box.left - gap - width;
    left = left.clamp(free.left + 8, math.max(free.left + 8, free.right - width - 8));
    final top = box.top.clamp(free.top + 8, math.max(free.top + 8, free.bottom - height - 8)).toDouble();
    return Positioned(left: left, top: top, child: TextFormatBar(host: this));
  }

  /// The inline text field, laid exactly over the text of the annotation being typed into.
  Widget _textEditor(Offset origin, double scale) {
    final a = _annotation(_textEdit!.id);
    if (a == null) return const SizedBox.shrink();
    final (at, isCallout) = switch (a.shape) {
      TextShape(:final at) => (at, false),
      CalloutShape(:final at) => (at, true),
      _ => (Offset.zero, false),
    };
    final color = isCallout ? CanvasPainter.calloutTextColor(a) : a.color;
    // Same style as the drawn text (font, weight, line height, alignment), scaled to the view
    final viewA = Annotation(id: a.id, shape: a.shape, color: a.color, size: a.size, scale: a.scale * scale, textFormat: a.textFormat);
    final style = CanvasPainter.textStyle(viewA, color, halo: !isCallout);
    final fs = viewA.fontSize;
    final measure = CanvasPainter.textLayout(_textController.text.isEmpty ? CanvasPainter.typeHint : _textController.text, viewA, color);
    final align = a.textFormat.align;
    final extra = fs * 0.6; // room for the caret, kept on the side that doesn't move the text
    final shift = switch (align) { TextAlign.center => extra / 2, TextAlign.right => extra, _ => 0.0 };
    return Positioned(
      left: origin.dx + at.dx * scale - shift,
      top: origin.dy + at.dy * scale,
      width: measure.width + extra,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => _endTextEdit(cancel: true),
          // Return keeps the text; Option+Return (Alt+Enter on Windows/Linux) or Shift+Return adds a line
          const SingleActivator(LogicalKeyboardKey.enter): _endTextEdit,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): _endTextEdit,
          const SingleActivator(LogicalKeyboardKey.enter, alt: true): _insertNewline,
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): _insertNewline,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, alt: true): _insertNewline,
        },
        child: TextField(
          key: const ValueKey('snaplite-inline-text'), // for widget tests
          controller: _textController,
          focusNode: _textFocus,
          style: style,
          textAlign: align,
          maxLines: null, // grows with each new line
          keyboardType: TextInputType.multiline,
          cursorColor: color,
          cursorWidth: math.max(1.5, fs / 14),
          decoration: InputDecoration.collapsed(hintText: CanvasPainter.typeHint, hintStyle: style.copyWith(color: color.withValues(alpha: 0.55))),
          onTapOutside: (_) {}, // a click on the canvas ends typing (see _down)
        ),
      ),
    );
  }

  static const _toolInfo = <Tool, (IconData, String)>{
    Tool.select: (Icons.near_me_outlined, 'Select'),
    Tool.arrow: (Icons.north_east, 'Arrow'),
    Tool.text: (Icons.text_fields, 'Text'),
    Tool.callout: (Icons.chat_bubble_outline, 'Callout'),
    Tool.box: (Icons.category_outlined, 'Shape'),
    Tool.ellipse: (Icons.circle_outlined, 'Ellipse'),
    Tool.line: (Icons.horizontal_rule, 'Line'),
    Tool.pen: (Icons.gesture, 'Pen'),
    Tool.step: (Icons.looks_one_outlined, 'Step'),
    Tool.highlight: (Icons.border_color_outlined, 'Highlight'),
    Tool.blur: (Icons.blur_on, 'Blur'),
    Tool.spotlight: (Icons.flashlight_on_outlined, 'Spotlight'),
    Tool.crop: (Icons.crop, 'Crop'),
  };

  /// [ghost]: the copy that follows the pointer while the grip is dragged (no GlobalKey, so the real one keeps it).
  Widget _toolbar({bool? vertical, bool ghost = false}) {
    // Every tool can appear: the preferred ones (Settings visibility) come first, then the rest. The toolbar
    // fits as many as the width allows and only the overflow goes into "More" — so a wider window shows more
    // tools, not a half-empty bar with a needless More button.
    final barTool = _tool == Tool.ellipse ? Tool.box : _tool; // both are the Shape button
    // Everything that can live on the bar, in priority order: preferred tools, the rest, then the actions.
    // The bar fits as many as the width allows; only the leftover goes into "More", which is dropped entirely
    // when nothing overflows. (On macOS, saving/opening/GIF live in the menu bar, so only Add Image + Logo.)
    final items = <(String, IconData, String)>[
      for (final t in _toolOrder) if (_visibleTools.contains(t)) (t.name, _toolInfo[t]!.$1, _toolInfo[t]!.$2),
      for (final t in _toolOrder) if (!_visibleTools.contains(t)) (t.name, _toolInfo[t]!.$1, _toolInfo[t]!.$2),
      ('overlay', Icons.add_photo_alternate_outlined, 'Image'),
      ('logo', Icons.business_outlined, 'Logo'),
      ('excalidraw', Icons.dashboard_outlined, 'Excalidraw'), // this picture into the whiteboard
      // A blank whiteboard is File › New Excalidraw Drawing on macOS, like Manim
      if (!Platform.isMacOS) ...[
        ('whiteboard', Icons.draw_outlined, 'New Excalidraw Drawing'),
        ('open', Icons.folder_open_outlined, 'Open Image…'),
        ('flatten', Icons.layers_clear_outlined, 'Flatten All'),
        ('export', Icons.ios_share, 'Save As…'),
        ('gif', Icons.gif_box_outlined, 'Save as Animated GIF…'),
        ('copyGif', Icons.gif_outlined, 'Copy as Animated GIF  ⇧⌘C'),
      ],
    ];
    void run(String v) {
      final t = Tool.values.where((t) => t.name == v).firstOrNull;
      if (t != null) return _setTool(t == Tool.box ? _shapeKind.tool : t);
      switch (v) {
        case 'open': openImageDialog();
        case 'overlay': _addOverlay();
        case 'logo': _showLogoPicker();
        case 'whiteboard': _openWhiteboard();
        case 'excalidraw': _openInWhiteboard();
        case 'flatten': _flattenInPlace();
        case 'export': saveAs();
        case 'gif': saveAnimatedGif();
        case 'copyGif': copyAnimatedGif();
        case 'copySticker': copySticker();
        case 'copyStillSticker': copyStillSticker();
        case 'settings': Native.shell('settings');
      }
    }
    // The fixed groups: the host's leading button, Undo/Redo, then Share (and Copy/Save off macOS, where
    // there is no menu bar for them) and the inspector toggle.
    final leading = widget.leading;
    final trailing = <Widget>[
      _ToolButton(icon: Icons.undo, label: 'Undo', onTap: _undo.isEmpty ? null : _undoAction),
      _ToolButton(icon: Icons.redo, label: 'Redo', onTap: _redo.isEmpty ? null : _redoAction),
      _ToolbarGap(vertical: _toolbarLeft),
      if (Platform.isMacOS) KeyedSubtree(key: ghost ? null : _shareKey, child: _ToolButton(icon: Icons.ios_share, label: 'Share', onTap: share)),
      if (!Platform.isMacOS) ...[
        _ToolButton(icon: Icons.content_copy, label: 'Copy', onTap: _copyImage),
        _ToolButton(icon: Icons.save_outlined, label: 'Save', onTap: save, primary: hasUnsavedChanges),
      ],
      _ToolButton(
        icon: _inspectorShown ? Icons.view_sidebar : Icons.view_sidebar_outlined,
        label: 'Inspector',
        active: _inspectorShown,
        tooltip: _inspectorShown ? 'Hide the properties panel' : 'Show the properties panel',
        onTap: _toggleInspector,
      ),
    ];
    final fixedButtons = trailing.where((w) => w is! _ToolbarGap).length + (leading != null ? 1 : 0);
    final fixedGaps = 2 + (leading != null ? 1 : 0); // leading | tools | undo/redo | share
    final down = vertical ?? _toolbarLeft; // the card as a column down the left edge
    return LayoutBuilder(builder: (context, c) {
      final vertical = down;
      // per-button footprint along the bar; More only when something overflows
      final toolW = (vertical ? _ToolButton.height : _ToolButton.width) + 2, moreW = toolW;
      final room = (vertical ? c.maxHeight : c.maxWidth) - _ToolbarCard.padding * 2 - _ToolbarCard.border * 2 -
          _ToolbarGrip.extent - fixedButtons * toolW - fixedGaps * _ToolbarGap.width;
      final int n; // how many items show as buttons
      if (items.length * toolW <= room) {
        n = items.length; // everything fits: no More
      } else {
        n = ((room - moreW) / toolW).floor().clamp(0, items.length); // leave room for More
      }
      final shown = items.sublist(0, n);
      final hidden = items.sublist(n);
      final moreActive = hidden.any((i) => i.$1 == barTool.name);
      return GestureDetector(onSecondaryTapUp: (d) => _showToolbarMenu(d.globalPosition), child: _ToolbarCard(vertical: vertical, children: [
        _ToolbarGrip(vertical: vertical, onDrag: _toolbarDragTo, onDrop: _toolbarDragEnd),
        if (leading != null) ...[leading, _ToolbarGap(vertical: vertical)],
        for (final i in shown)
          _ToolButton(icon: i.$2, label: i.$3, active: i.$1 == barTool.name, onTap: () => run(i.$1)),
        if (hidden.isNotEmpty)
          _MoreButton(
            active: moreActive,
            label: moreActive ? _toolInfo[barTool]!.$2 : 'More',
            icon: moreActive ? _toolInfo[barTool]!.$1 : Icons.more_horiz,
            items: hidden,
            onSelected: run,
          ),
        _ToolbarGap(vertical: vertical),
        ...trailing,
      ]));
    });
  }
}

/// The floating toolbar: one chrome card holding the tool buttons, hugging its content — a row across the
/// top, or a column down the left edge.
class _ToolbarCard extends StatelessWidget {
  static const padding = 4.0;
  static const border = 0.8; // SnapChrome.decoration()'s hairline, which the Container adds to the padding
  final bool vertical;
  final List<Widget> children;
  const _ToolbarCard({required this.children, this.vertical = false});

  @override
  Widget build(BuildContext context) => Container(
        height: vertical ? null : EditorPageState._toolbarHeight,
        width: vertical ? EditorPageState._toolbarLeftWidth : null,
        padding: vertical ? const EdgeInsets.symmetric(vertical: padding) : const EdgeInsets.symmetric(horizontal: padding),
        decoration: SnapChrome.of(context).decoration(),
        child: vertical
            ? Column(mainAxisSize: MainAxisSize.min, children: children)
            : Row(mainAxisSize: MainAxisSize.min, children: children),
      );
}

/// The grip at the start of the toolbar: drag it to the top or the left edge of the window to dock the
/// toolbar there (the editor lights up the dock under the pointer and moves the card on release).
class _ToolbarGrip extends StatelessWidget {
  static const extent = 18.0; // along the bar
  static const tooltip = 'Drag to the top or the left edge';
  final bool vertical;
  final ValueChanged<Offset> onDrag; // the pointer's global position, from the first move on
  final VoidCallback onDrop;
  const _ToolbarGrip({required this.vertical, required this.onDrag, required this.onDrop});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => onDrag(d.globalPosition),
        onPanUpdate: (d) => onDrag(d.globalPosition),
        onPanEnd: (_) => onDrop(),
        onPanCancel: onDrop,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: vertical ? _ToolButton.width : extent,
            height: vertical ? extent : _ToolButton.height,
            child: RotatedBox(quarterTurns: vertical ? 1 : 0, child: Icon(Icons.drag_indicator, size: 16, color: color)),
          ),
        ),
      ),
    );
  }
}

/// A hairline between toolbar groups (its footprint along the bar is [width] either way).
class _ToolbarGap extends StatelessWidget {
  static const width = 13.0;
  final bool vertical;
  const _ToolbarGap({this.vertical = false});
  @override
  Widget build(BuildContext context) => Container(
      width: vertical ? 24 : 1,
      height: vertical ? 1 : 24,
      margin: vertical ? const EdgeInsets.symmetric(vertical: 6) : const EdgeInsets.symmetric(horizontal: 6),
      color: Theme.of(context).colorScheme.outlineVariant);
}

/// A toolbar button: the icon over a small label. The active tool sits in a tinted capsule; hovering lifts
/// the others slightly. Used by the Library for its back button too.
class ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;
  const ToolbarButton({super.key, required this.icon, required this.label, this.onTap, this.tooltip});
  @override
  Widget build(BuildContext context) => _ToolButton(icon: icon, label: label, onTap: onTap, tooltip: tooltip);
}

class _ToolButton extends StatefulWidget {
  /// True while draw mode's glass chrome is up (set by EditorPageState).
  static bool glass = false;
  static const width = 52.0;
  static const height = EditorPageState._toolbarHeight - 8;
  final IconData icon;
  final String label;
  final String? tooltip;
  final bool active, primary;
  final VoidCallback? onTap;
  const _ToolButton({required this.icon, required this.label, this.active = false, this.primary = false, this.onTap, this.tooltip});
  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    final glass = _ToolButton.glass; // draw mode: icons and labels lead, at full strength with a soft shadow
    final fg = !enabled ? s.onSurface.withValues(alpha: glass ? 0.4 : 0.28)
        : widget.active || widget.primary ? s.primary : (_hover || glass) ? s.onSurface : s.onSurfaceVariant;
    final shadows = glass ? const [Shadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1))] : null;
    final button = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: _ToolButton.width,
          height: _ToolButton.height,
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            color: widget.active ? s.primary.withValues(alpha: 0.14)
                : _hover && enabled ? s.onSurface.withValues(alpha: 0.07) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(widget.icon, size: glass ? 22 : 19, color: fg, shadows: shadows),
            const SizedBox(height: 2),
            Text(widget.label, maxLines: 1, overflow: TextOverflow.clip, softWrap: false,
                style: TextStyle(fontSize: glass ? 10.5 : 10, height: 1.1, color: fg, letterSpacing: -0.1, shadows: shadows,
                    fontWeight: widget.active || glass ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      ),
    );
    final tip = widget.tooltip;
    return tip == null ? button : Tooltip(message: tip, child: button);
  }
}

/// "More ▾": hidden tools and less-used actions.
class _MoreButton extends StatelessWidget {
  final bool active;
  final String label;
  final IconData icon;
  final List<(String, IconData, String)?> items;
  final ValueChanged<String> onSelected;
  const _MoreButton({required this.active, required this.label, required this.icon, required this.items, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      padding: EdgeInsets.zero, // the button's own footprint only, so the bar's overflow count is exact
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final i in items)
          if (i == null)
            const PopupMenuDivider(height: 8)
          else
            PopupMenuItem(value: i.$1, height: 32, child: Row(children: [
              Icon(i.$2, size: 17), const SizedBox(width: 10), Text(i.$3, style: const TextStyle(fontSize: 13)),
            ])),
      ],
      child: IgnorePointer(child: _ToolButton(icon: icon, label: label, active: active, onTap: () {})),
    );
  }
}

/// The image's pixel size shown just under it, as two editable fields (`W × H px`). Committing resizes the
/// canvas to those dimensions from the top-left (the same operation as the drag handles / Resize dialog),
/// clamped to 16..10000. The fields re-sync whenever the image changes (resize by handles, crop, undo…).
class _CanvasDimsEditor extends StatefulWidget {
  final int width, height;
  final String? bytesLabel; // the image's encoded size (null while being measured)
  final int? originalWidth, originalHeight; // the capture's own size, for the "fit to original" button
  final void Function(int w, int h) onApply;
  final ValueChanged<bool> onFocusChange; // true while either field holds focus (editor mutes its shortcuts)
  const _CanvasDimsEditor({
    required this.width,
    required this.height,
    required this.bytesLabel,
    required this.originalWidth,
    required this.originalHeight,
    required this.onApply,
    required this.onFocusChange,
  });

  @override
  State<_CanvasDimsEditor> createState() => _CanvasDimsEditorState();
}

class _CanvasDimsEditorState extends State<_CanvasDimsEditor> {
  late final TextEditingController _w = TextEditingController(text: '${widget.width}');
  late final TextEditingController _h = TextEditingController(text: '${widget.height}');

  @override
  void didUpdateWidget(_CanvasDimsEditor old) {
    super.didUpdateWidget(old);
    if (widget.width != old.width && '${widget.width}' != _w.text) _w.text = '${widget.width}';
    if (widget.height != old.height && '${widget.height}' != _h.text) _h.text = '${widget.height}';
  }

  @override
  void dispose() {
    _w.dispose();
    _h.dispose();
    super.dispose();
  }

  void _apply() {
    final w = int.tryParse(_w.text.trim()), h = int.tryParse(_h.text.trim());
    if (w == null || h == null) {
      _w.text = '${widget.width}';
      _h.text = '${widget.height}';
      return;
    }
    final cw = w.clamp(16, 10000), ch = h.clamp(16, 10000);
    _w.text = '$cw';
    _h.text = '$ch';
    if (cw != widget.width || ch != widget.height) widget.onApply(cw, ch);
  }

  Widget _field(TextEditingController c) => SizedBox(
        width: 54,
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _apply(),
          onTapOutside: (_) => _apply(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final col = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = TextStyle(fontSize: 11, color: col);
    final ow = widget.originalWidth, oh = widget.originalHeight;
    final canFit = ow != null && oh != null && (ow != widget.width || oh != widget.height);
    // Reports focus for the whole group (either field) so the editor can mute its Backspace/Delete/letter
    // shortcuts while a number is being edited.
    return Focus(
      canRequestFocus: false,
      onFocusChange: widget.onFocusChange,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _field(_w),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text('×', style: style)),
        _field(_h),
        Padding(padding: const EdgeInsets.only(left: 4), child: Text('px', style: style)),
        if (widget.bytesLabel != null)
          Padding(padding: const EdgeInsets.only(left: 8), child: Text('· ${widget.bytesLabel}', style: style)),
        if (canFit)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Tooltip(
              message: 'Fit to original $ow × $oh',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => widget.onApply(ow, oh),
                child: Padding(padding: const EdgeInsets.all(3), child: Icon(Icons.fit_screen_outlined, size: 15, color: col)),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Paints the committed state plus the in-progress gesture (drawn with the real style) and the canvas
/// chrome: the image's dashed border and square handles when it is selected, marching ants after Copy,
/// and the new outline while the canvas is being resized. `origin` is where the image sits in the area.
class _PreviewPainter extends CustomPainter {
  final CanvasPainter base;
  final Offset origin;
  final Tool tool;
  final Color color;
  final StrokeSize size;
  final ArrowStyle style;
  final double scale;
  final double? scaleY; // vertical scale (defaults to `scale`); differs after a non-proportional resize
  final Offset? createStart, createCurrent;
  final List<Offset>? penPoints;
  final ({Offset from, Offset to, List<Offset> points, List<Offset?> tangents})? follow; // Curve: the path so far
  final bool canvasChrome;
  final ValueNotifier<double>? ants;
  final ValueNotifier<double> march;
  final Rect? canvasResize;
  final Rect? boundsOfSelection;
  final List<Rect>? groupBoxes; // ⌘A group peers: a thin accent outline round each (image coords)
  final List<Guide> guides;
  final bool fourier; // Fourier drawing: spinning circles trace the stroke as it's drawn
  final bool envelope; // String art: the tangent fan follows the stroke as it's drawn
  final List<Offset>? trail; // the drag so far, every point (Fourier drawing traces it)
  final Rect? cropRect; // the pending Crop-tool region (image coords): dotted outline + draggable handles

  _PreviewPainter({required this.base, required this.origin, required this.tool, required this.color, required this.size,
      required this.scale, this.scaleY, required this.style, this.createStart, this.createCurrent, this.penPoints, this.follow,
      this.canvasChrome = false, this.ants, required this.march, this.canvasResize, this.boundsOfSelection, this.groupBoxes,
      this.guides = const [], this.fourier = false, this.envelope = false, this.trail, this.cropRect})
      : super(repaint: Listenable.merge([ants, march]));

  static const _accent = Color(0xFF2F7CF6);

  // The picture itself is the cached layer underneath (see the editor's canvas Stack): this paints only what
  // moves — the selection's handles, the stroke being drawn, guides, ants, crop and canvas-resize chrome.
  @override
  void paint(Canvas canvas, Size size) => base.withMarch(() => _paintOverlay(canvas));

  void _paintOverlay(Canvas canvas) {
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    final sy = scaleY ?? scale;
    base.paintSelection(canvas); // handles may sit on the image's edge, so not clipped to it

    canvas.save();
    canvas.scale(scale, sy);
    Annotation ann(Shape s) => Annotation(id: -1, shape: s, color: color, size: this.size, arrowStyle: style, scale: base.state.density);
    // The stroke being drawn; with Fourier drawing on, its circles follow the pointer in real time
    void live(Annotation a) {
      if (envelope && CanvasPainter.hasOutline(a)) {
        CanvasPainter.drawAnnotation(canvas, a);
        return CanvasPainter.tangentFan(canvas, a); // the string art builds under the pen
      }
      if (!fourier) return CanvasPainter.drawAnnotation(canvas, a);
      CanvasPainter.drawAnnotation(canvas, Epicycles.fourierized(a)); // what you'll get: the curve the circles trace
      Epicycles.proper(a)?.paint(canvas, 1, color, scale); // the same circles that make that curve
    }
    if (penPoints != null && penPoints!.length > 1) {
      live(ann(PenShape(penPoints!)));
    } else if (createStart != null && createCurrent != null) {
      final a = createStart!, b = createCurrent!, r = Rect.fromPoints(a, b);
      switch (tool) {
        case Tool.arrow || Tool.line when fourier:
          final raw = EditorPageState._rawStroke(tool, a, b, trail);
          if (raw != null) live(ann(raw));
        case Tool.arrow:
          final f = follow;
          live(ann(f == null ? ArrowShape(a, b) : ArrowShape(f.from, f.to, points: f.points, tangents: f.tangents)));
        case Tool.line:
          final f = follow;
          live(ann(f == null ? LineShape(a, b) : LineShape(f.from, f.to, points: f.points, tangents: f.tangents)));
        case Tool.box:
          live(ann(RectShape(r)));
        case Tool.ellipse:
          live(ann(EllipseShape(r)));
        case Tool.highlight:
          CanvasPainter.drawAnnotation(canvas, ann(HighlightShape(r)));
        case Tool.blur:
          CanvasPainter.drawAnnotation(canvas, ann(BlurShape(r, null)), base: base.state.image);
        case Tool.callout:
          // Where the pointer will point, and a line to where the bubble will go
          final line = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2 / scale;
          canvas.drawPath(CanvasPainter.dashed(Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy), [6 / scale, 4 / scale]), line);
          canvas.drawCircle(a, 4 / scale, Paint()..color = color);
        case Tool.spotlight || Tool.crop:
          final dim = Path()..addRect(Offset.zero & Size(base.state.image.width.toDouble(), base.state.image.height.toDouble()))
            ..addRect(r)..fillType = PathFillType.evenOdd;
          canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.45));
          canvas.drawRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5 / scale);
        default:
          break;
      }
    }
    canvas.restore();

    // Selected text, callouts and steps have no handles: a dashed box shows they are selected
    if (boundsOfSelection != null) {
      final r = Rect.fromLTRB(boundsOfSelection!.left * scale, boundsOfSelection!.top * scale,
          boundsOfSelection!.right * scale, boundsOfSelection!.bottom * scale).inflate(4);
      _border(canvas, r, 0, accent: true);
    }

    // ⌘A group peers: a thin accent outline around each, so you see the whole group that moves/restyles together.
    for (final b in groupBoxes ?? const <Rect>[]) {
      final r = Rect.fromLTRB(b.left * scale, b.top * scale, b.right * scale, b.bottom * scale).inflate(4);
      _border(canvas, r, 0, accent: true);
    }

    // Alignment guides for a dragged image, 1 px in the accent colour, a little past both ends
    final guide = Paint()..color = _accent..strokeWidth = 1;
    for (final g in guides) {
      final at = g.at * scale, from = g.from * scale - 6, to = g.to * scale + 6;
      canvas.drawLine(g.vertical ? Offset(at, from) : Offset(from, at), g.vertical ? Offset(at, to) : Offset(to, at), guide);
    }

    final frame = Offset.zero & Size(base.state.image.width * scale, base.state.image.height * sy);
    final resize = canvasResize;
    if (resize != null) {
      final target = Rect.fromLTRB(resize.left * scale, resize.top * scale, resize.right * scale, resize.bottom * scale);
      canvas.drawPath(Path()..addRect(target)..addRect(frame)..fillType = PathFillType.evenOdd,
          Paint()..color = Colors.white.withValues(alpha: 0.85)); // new white space (and what will be cut)
      final keep = target.intersect(frame);
      canvas.drawPath(Path()..addRect(frame)..addRect(keep)..fillType = PathFillType.evenOdd,
          Paint()..color = Colors.black.withValues(alpha: 0.4)); // area that will be cropped away
      _border(canvas, target, 0, accent: true);
    } else if (canvasChrome) {
      _border(canvas, frame.inflate(1), ants?.value ?? 0);
      for (final h in CanvasPainter.rectHandles(frame.inflate(4))) {
        final sq = Rect.fromCenter(center: h, width: 7, height: 7);
        canvas.drawRect(sq, Paint()..color = Colors.white);
        canvas.drawRect(sq, Paint()..color = const Color(0xFF737373)..style = PaintingStyle.stroke..strokeWidth = 1);
      }
    }

    // The pending crop region: dim outside, a dotted outline, and draggable corner/edge handles.
    if (cropRect != null) {
      final r = Rect.fromLTRB(cropRect!.left * scale, cropRect!.top * scale, cropRect!.right * scale, cropRect!.bottom * scale);
      canvas.drawPath(Path()..addRect(frame)..addRect(r)..fillType = PathFillType.evenOdd,
          Paint()..color = Colors.black.withValues(alpha: 0.45));
      _border(canvas, r, march.value); // marching-ants dotted outline
      for (final h in CanvasPainter.rectHandles(cropRect!)) {
        final c = Offset(h.dx * scale, h.dy * scale);
        canvas.drawCircle(c, 5, Paint()..color = Colors.white);
        canvas.drawCircle(c, 5, Paint()..color = _accent..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
    }
    canvas.restore();
  }

  /// A one-point dashed line, white under dark gray (or the accent): marching ants when `phase` moves.
  static void _border(Canvas canvas, Rect rect, double phase, {bool accent = false}) {
    final r = rect.deflate(0.5);
    canvas.drawRect(r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1);
    canvas.drawPath(CanvasPainter.dashed(Path()..addRect(r), const [4, 4], phase: phase),
        Paint()..color = accent ? _accent : const Color(0xFF333333)..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter old) => true;
}

/// A checkerboard: the swatch for a transparent canvas.
class _Checker extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final grey = Paint()..color = const Color(0xFFCCCCCC);
    const cell = 6.0;
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = ((y / cell).round().isOdd ? cell : 0.0); x < size.width; x += cell * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), grey);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

/// The inline text field's controller: shows each run's formatting while typing.
class _RichTextController extends TextEditingController {
  List<TextRun> runs = const [];

  void setRuns(List<TextRun> value) {
    runs = value;
    notifyListeners(); // repaint the field and update the annotation
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (runs.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    return CanvasPainter.richSpan(text, runs, style ?? const TextStyle());
  }
}

/// The thickness slider shown beside a selected arrow, line or shape: a slim pill, drag up for thicker,
/// down for thinner.
class _ThicknessCard extends StatelessWidget {
  static const width = 30.0, height = 340.0, minHeight = 156.0; // height: preferred (≈8 pt of track per point)
  final double value; // points
  final Color color;
  final VoidCallback onStart, onEnd;
  final ValueChanged<double> onChanged;
  final double cardHeight;
  const _ThicknessCard({this.cardHeight = height, required this.value, required this.color, required this.onStart,
      required this.onChanged, required this.onEnd});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: cardHeight,
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      decoration: SnapChrome.of(context).pill(),
      child: Column(children: [
        Text('${value.round()}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: s.onSurfaceVariant)),
        Expanded(
          child: Tooltip(
            message: 'Thickness (pt): drag up for thicker, down for thinner',
            waitDuration: const Duration(milliseconds: 700),
            child: RotatedBox(
              quarterTurns: 3, // bottom = thin, top = thick
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  activeTrackColor: color,
                  inactiveTrackColor: s.outlineVariant,
                  thumbColor: Colors.white,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 1.5, pressedElevation: 2),
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  key: const ValueKey('snaplite-thickness'),
                  min: 1,
                  max: 40,
                  value: value,
                  onChangeStart: (_) => onStart(),
                  onChanged: onChanged,
                  onChangeEnd: (_) => onEnd(),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The bar shown above a selected annotation (as in Snagit): the colours plus "any colour", one click each;
/// for arrows and lines a second row with the arrowheads, head size, Swap Ends and the line pattern.
class _ColorBar extends StatelessWidget {
  static const _dot = 20.0, _gap = 6.0, _pad = 8.0, _menu = 62.0, _row2 = 28.0;
  static double widthFor(bool lines) => math.max(_pad * 2 + (PropertiesPanel.colors.length + 1) * (_dot + _gap) - _gap,
      lines ? _pad * 2 + 3 * _menu + 2 * 4 + 28 + 28 + 6 : 0);
  static double heightFor(bool lines) => _dot + _pad * 2 + (lines ? _row2 + 6 : 0);
  final Color selected;
  final ValueChanged<Color> onPick;
  final VoidCallback onMore;
  final ArrowStyle? style; // an arrow or line: also show its arrowheads and pattern
  final ValueChanged<ArrowStyle> onStyle;
  const _ColorBar({required this.selected, required this.onPick, required this.onMore, this.style, required this.onStyle});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final st = style;
    final colours = Row(mainAxisSize: MainAxisSize.min, children: [
      for (final (name, c) in PropertiesPanel.colors) ...[
        Tooltip(
          message: name,
          waitDuration: const Duration(milliseconds: 600),
          child: InkResponse(
            onTap: () => onPick(c),
            radius: 13,
            child: Container(
              width: _dot, height: _dot,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                    color: c.toARGB32() == selected.toARGB32() ? s.primary : s.outlineVariant,
                    width: c.toARGB32() == selected.toARGB32() ? 2.5 : 0.8),
              ),
            ),
          ),
        ),
        const SizedBox(width: _gap),
      ],
      Tooltip(
        message: 'Any color',
        waitDuration: const Duration(milliseconds: 600),
        child: InkResponse(
          onTap: onMore,
          radius: 13,
          child: Container(
            width: _dot, height: _dot,
            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: SweepGradient(colors: [
              Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red])),
          ),
        ),
      ),
    ]);
    return Container(
      key: const ValueKey('snaplite-colorbar'),
      width: widthFor(st != null),
      padding: const EdgeInsets.all(_pad),
      decoration: SnapChrome.of(context).decoration(radius: st != null ? 14 : heightFor(false) / 2),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        colours,
        if (st != null) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: _row2,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final atStart in [true, false]) ...[
                _MiniMenu<Object>(
                  key: ValueKey(atStart ? 'snaplite-bar-start' : 'snaplite-bar-end'),
                  tooltip: atStart ? 'Start (and head size)' : 'End (and head size)',
                  value: atStart ? st.start : st.end,
                  checked: (v) => v == st.headSize,
                  items: PropertiesPanel.headChoices(st, start: atStart),
                  onChanged: (v) => onStyle(v is HeadSize
                      ? st.copyWith(headSize: v)
                      : atStart ? st.copyWith(start: v as ArrowHead) : st.copyWith(end: v as ArrowHead)),
                ),
                const SizedBox(width: 4),
              ],
              _MiniMenu<LinePattern>(
                tooltip: 'Pattern',
                value: st.pattern.still,
                items: [for (final p in LinePattern.menu) (p, p.label, StylePreview(ArrowStyle(end: ArrowHead.none, pattern: p)))],
                onChanged: (p) => onStyle(st.copyWith(pattern: p.marching(st.pattern.marches))),
              ),
              SizedBox(
                width: 28,
                child: st.pattern.canMarch
                    ? Tooltip(
                        message: 'Marching: the dashes keep running toward the end',
                        child: Checkbox(
                          key: const ValueKey('snaplite-bar-marching'),
                          value: st.pattern.marches,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (v) => onStyle(st.copyWith(pattern: st.pattern.marching(v ?? false))),
                        ),
                      )
                    : null,
              ),
              SizedBox(
                width: 28,
                child: IconButton(
                  tooltip: 'Swap Ends',
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  onPressed: () => onStyle(st.copyWith(start: st.end, end: st.start)),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// A small picker in the bar: shows the current choice's preview; the menu lists preview + name.
class _MiniMenu<T> extends StatelessWidget {
  final String tooltip;
  final T value;
  final List<(T, String, Widget?)> items;
  final ValueChanged<T> onChanged;
  final bool Function(T)? checked; // a second ticked choice (the head size in a head menu)
  const _MiniMenu({super.key, required this.tooltip, required this.value, required this.items, required this.onChanged,
      this.checked});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final current = items.firstWhere((i) => i.$1 == value, orElse: () => items.first);
    return PopupMenuButton<T>(
      tooltip: tooltip,
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => PropertiesPanel.menuEntries(items, checked),
      child: Container(
        width: _ColorBar._menu,
        height: _ColorBar._row2,
        padding: const EdgeInsets.only(left: 4, right: 2),
        decoration: SnapChrome.of(context).controlBox(),
        child: Row(children: [
          Expanded(child: FittedBox(child: SizedBox(width: 48, height: 18, child: current.$3 ?? Text(current.$2)))),
          Icon(Icons.unfold_more, size: 12, color: s.onSurfaceVariant),
        ]),
      ),
    );
  }
}
