import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../editor/editor_page.dart';
import '../excalidraw/excalidraw_page.dart';
import '../library/library_page.dart';
import '../platform/hotkeys.dart';
import '../platform/native.dart';

/// The Flutter side of the app: the Library / editor window. On macOS the menu bar shell (status item,
/// capture panel, hotkeys, capture and recording flows) is native (macos/Runner/Shell) and calls in here to
/// open a file in the editor or show the Library. Other platforms get a tray + hotkeys from plugins.
class AppController with TrayListener, WindowListener {
  AppController._();
  static final instance = AppController._();

  final editorKey = GlobalKey<EditorPageState>();
  final libraryKey = GlobalKey<LibraryPageState>();
  /// Bumped whenever the captures folder changes (new capture, recording, GIF, trash).
  final capturesVersion = ValueNotifier<int>(0);

  /// Settings › Appearance (the Swift app's key "appearance"): glass, system, light, dark or tokyoNight.
  final appearance = ValueNotifier<String>('glass');
  Map<ShortcutAction, Shortcut?> shortcuts = {};
  bool _sized = false;

  /// ~/Pictures/SnapNow, or SNAPLITE_CAPTURES_DIR (demos, tests).
  static String get capturesFolder {
    final dir = Directory(Platform.environment['SNAPLITE_CAPTURES_DIR'] ?? '${Platform.environment['HOME']}/Pictures/SnapNow');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  /// A free file name, e.g. "SnapNow 2026-10-20 at 14.05.33.png", then "... 2.png".
  static String newCapturePath({String prefix = 'SnapNow', String ext = 'png'}) {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final base = '$prefix ${d.year}-${two(d.month)}-${two(d.day)} at ${two(d.hour)}.${two(d.minute)}.${two(d.second)}';
    var path = '$capturesFolder/$base.$ext';
    var n = 2;
    while (File(path).existsSync()) {
      path = '$capturesFolder/$base $n.$ext';
      n++;
    }
    return path;
  }

  /// Startup trace in ~/Library/Caches/SnapLite/trace.log (release builds have no console).
  static void trace(String msg) {
    try {
      final dir = Directory('${Platform.environment['HOME']}/Library/Caches/SnapLite')..createSync(recursive: true);
      File('${dir.path}/trace.log').writeAsStringSync('${DateTime.now().toIso8601String()} $msg\n', mode: FileMode.append);
    } catch (_) {}
  }

  Future<void> init() async {
    trace('init start');
    Native.init();
    Native.onOpenEditor = openEditor;
    Native.onOpenDraw = openDraw;
    Native.onCursorKick = () => editorKey.currentState?.kickCursor();
    Native.onCloseDraw = closeDraw;
    Native.onDrawHasMarks = () => editorKey.currentState?.hasDrawMarks ?? false;
    Native.onShowLibrary = showLibrary;
    Native.onCapturesChanged = () => capturesVersion.value++;
    Native.onAppearanceChanged = (choice) => appearance.value = choice;
    appearance.value = await Native.getString('appearance') ?? 'glass';
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    if (!Platform.isMacOS) await _initTrayAndHotkeys();
    trace('ready');
  }

  /// The menu bar shell's actions (region, window, screen, text, record, library, openImage, settings).
  void perform(String action) {
    if (action == 'library') {
      showLibrary();
    } else {
      Native.shell(action);
    }
  }

  // ---- Window ----

  Future<void> _show() async {
    if (!_sized) {
      _sized = true;
      await windowManager.setMinimumSize(const Size(720, 480));
      await windowManager.setSize(initialWindowSize(await Native.screenVisibleSize()));
      await windowManager.center();
    }
    await windowManager.show();
    await windowManager.focus();
    await Native.activate();
  }

  /// Draw mode: the native side has already sized the window to the display and removed its title bar; the editor
  /// shows the frozen screen 1:1 with its tools floating over it. (No _show(): it would resize and centre the window.)
  Future<void> openDraw(String path) async {
    _closePushedPages();
    drawing = true;
    // Pointer events aligned to the display's frames and interpolated between samples: the stroke follows the hand evenly
    GestureBinding.instance.resamplingEnabled = true;
    GestureBinding.instance.samplingOffset = const Duration(milliseconds: -8);
    // The native side has already put the window on screen (on the current Space) and activated SnapNow. A show/focus
    // from here would order it front again and could pull macOS to another Space; only a hidden window still needs it
    // (a hidden window schedules no frames, so waiting for one before showing would wait forever).
    if (!await windowManager.isVisible()) await windowManager.show();
    await libraryKey.currentState?.openDraw(path);
    editorKey.currentState?.armCursorKick();
    // Two frames: the one that lays out the new glass and the one that paints it, so the window never fades in on the
    // previous session's picture (it keeps its last frame while hidden).
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    await Native.drawReady();
  }

  bool drawing = false;

  /// Draw mode ended. When something was drawn, the editor puts the screen [shot] under the drawing and saves it as a
  /// normal capture (every mark stays editable from the Library); returns whether it was kept.
  Future<bool> closeDraw(String? shot) async {
    var kept = false;
    if (shot != null) kept = await editorKey.currentState?.finishDraw(shot) ?? false;
    drawing = false;
    GestureBinding.instance.resamplingEnabled = false;
    libraryKey.currentState?.closeDraw();
    return kept;
  }

  /// Opens a capture in the editor (Library edit mode, with the filmstrip of all captures).
  Future<void> openEditor(String path) async {
    await _show();
    _closePushedPages();
    editorKey.currentState?.closeGifPreview(); // a new capture takes over from the GIF being shown
    await libraryKey.currentState?.openForEditing(path, fresh: true); // a capture that just happened
  }

  Future<void> showLibrary() async {
    await _show();
    _closePushedPages();
    await libraryKey.currentState?.showGrid();
  }

  /// File › New Excalidraw Drawing from the Library: a blank whiteboard; "Send to SnapNow" saves the drawing
  /// as a new capture and opens it in the editor. (While editing, the editor's own whiteboard drops the
  /// drawing onto the canvas instead.)
  Future<void> newDrawing(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ExcalidrawPage(onExport: (png) async {
        final path = newCapturePath(prefix: 'SnapNow Drawing');
        await File(path).writeAsBytes(png, flush: true);
        capturesVersion.value++;
        await openEditor(path);
      }),
    ));
  }

  /// Manim Studio is a page pushed over the Library; a new capture or the Library
  /// must come up in front, not stay hidden under them. Studio saves itself as it closes, and a render
  /// already running finishes and lands in the Library.
  void _closePushedPages() {
    final context = libraryKey.currentContext;
    final navigator = context == null ? null : Navigator.maybeOf(context);
    navigator?.popUntil((r) => r.isFirst);
  }

  @override
  void onWindowClose() async {
    if (drawing) return Native.shell('endDraw');   // ⌘W / close leaves draw mode (the drawing is discarded unless saved)
    if (await libraryKey.currentState?.confirmDiscard() ?? true) await windowManager.hide();
  }

  /// Esc: saves any edits without asking (unlike ⌘W), then hides the window; with the copied GIF
  /// playing over the editor it only closes that preview.
  Future<void> saveAndClose() async {
    if (drawing) return;                           // Esc never leaves draw mode (it would lose the drawing); double-tap ⌥ or ⌘W does
    final editor = editorKey.currentState;
    if (editor?.closeGifPreview() ?? false) return;
    if (editor != null && editor.hasUnsavedChanges) await editor.save();
    await windowManager.hide();
  }

  // ---- Windows / Linux: tray and hotkeys from plugins (capture flows to be added per platform) ----

  Future<void> _initTrayAndHotkeys() async {
    trayManager.addListener(this);
    await trayManager.setIcon('assets/tray_icon.png');
    await trayManager.setToolTip('SnapNow');
    shortcuts = await HotkeyStore.load();
    await hotKeyManager.unregisterAll();
    for (final entry in shortcuts.entries) {
      final hk = entry.value?.toHotKey(entry.key.name);
      if (hk == null) continue;
      try {
        await hotKeyManager.register(hk, keyDownHandler: (_) => perform(entry.key.name));
      } catch (e) {
        trace('hotkey ${entry.key.name} failed: $e');
      }
    }
    await trayManager.setContextMenu(Menu(items: [
      for (final a in ShortcutAction.values) MenuItem(key: a.name, label: a.title),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit SnapNow'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'quit') exit(0);
    perform(menuItem.key ?? '');
  }
}

/// The editor/library window's first size: 1240×860 points at most, but never more than 74% of the
/// screen's visible width or 78% of its height, so it fits a 14" MacBook Pro (1512×982) as comfortably
/// as a 16" one, and never below the window's minimum.
Size initialWindowSize(Size? visible) {
  const max = Size(1240, 860), min = Size(720, 480);
  if (visible == null || visible.width <= 0 || visible.height <= 0) return max;
  final w = (visible.width * 0.74).clamp(min.width, max.width);
  final h = (visible.height * 0.78).clamp(min.height, max.height);
  return Size(w.roundToDouble(), h.roundToDouble());
}
