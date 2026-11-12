import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../app/app_controller.dart';
import '../app/app_menu.dart';
import '../app/theme.dart';
import '../editor/editor_page.dart';
import '../platform/native.dart';
import 'transcripts.dart';

/// The Library window, as in the Swift app: a grid of every capture (search, multi-select, right-click
/// menu), and an edit mode (double-click) with the editor above a filmstrip of all captures. Dragging a
/// filmstrip thumbnail onto the canvas drops that image in.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  static const _images = {'png', 'jpg', 'jpeg'};
  static const _movies = {'mov', 'mp4'};
  static const _all = {..._images, ..._movies, 'gif'};

  List<File> _files = [];
  String _query = '';
  final _selected = <String>{};
  String? _anchor; // last clicked, for shift-click ranges
  bool _editing = false;
  String? _editingPath;
  final _thumbs = <String, Future<Uint8List?>>{};
  final _gridFocus = FocusNode();
  final _filmScroll = ScrollController();
  final _transcripts = <String, TranscriptInfo>{};

  EditorPageState? get _editor => AppController.instance.editorKey.currentState;

  // ---- The menu bar (lib/app/app_menu.dart) ----

  bool get editing => _editing;
  bool get hasSelection => _selection.isNotEmpty;

  /// Grid-mode menu commands (the same as its keys); in edit mode the menu talks to the editor.
  void runMenu(String id) {
    switch (id) {
      case 'openSelected': _open(_selection);
      case 'copyFiles': Native.copyFiles(_selection);
      case 'selectAll': setState(() => _selected.addAll(_shown.map((f) => f.path)));
      case 'trash': _trash(_selection);
      case 'library': showGrid();
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
    AppController.instance.capturesVersion.addListener(_reload);
    Native.onTranscriptChanged = _transcriptChanged;
  }

  @override
  void dispose() {
    AppController.instance.capturesVersion.removeListener(_reload);
    if (Native.onTranscriptChanged == _transcriptChanged) Native.onTranscriptChanged = null;
    super.dispose();
  }

  static String _ext(String path) => path.split('.').last.toLowerCase();
  static String _name(String path) {
    final file = path.split('/').last;
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
  }

  bool _isImage(String path) => _images.contains(_ext(path));

  /// Newest first; thumbnails are cached per file and modification time.
  void _reload() {
    final dir = Directory(AppController.capturesFolder);
    final entries = <(File, DateTime)>[];
    for (final e in dir.listSync()) {
      if (e is File && !e.path.split('/').last.startsWith('.') && _all.contains(_ext(e.path))) {
        entries.add((e, e.lastModifiedSync()));
      }
    }
    entries.sort((a, b) => b.$2.compareTo(a.$2));
    if (!mounted) return;
    setState(() {
      _files = [for (final e in entries) e.$1];
      _selected.removeWhere((p) => !_files.any((f) => f.path == p));
    });
    _loadTranscripts();
  }

  // ---- Transcripts (made natively, on this Mac only; see TranscriptInfo) ----

  void _transcriptChanged(Map<Object?, Object?> info) {
    final path = info['path'];
    if (path is! String || !mounted) return;
    setState(() => _transcripts[path] = TranscriptInfo.fromMap(info));
  }

  /// Each movie's transcript state: a badge on its tile, or progress while one is being made.
  Future<void> _loadTranscripts() async {
    final movies = [for (final f in _files) if (_movies.contains(_ext(f.path))) f.path];
    if (movies.isEmpty) return;
    try {
      final states = await Native.transcriptStates(movies);
      if (!mounted) return;
      setState(() {
        for (final e in states.entries) {
          _transcripts[e.key] = TranscriptInfo.fromMap(e.value);
        }
      });
    } catch (_) {} // no native side (tests): no badges
  }

  Future<void> _showTranscript(String movie) async {
    final String text;
    try {
      text = await File(TranscriptFiles.textPath(movie)).readAsString();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_name(movie), maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 640,
          height: 420,
          child: Scrollbar(child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontSize: 13, height: 1.45)))),
        ),
        actions: [
          TextButton(onPressed: () => Native.reveal(TranscriptFiles.textPath(movie)), child: const Text('Show in Finder')),
          TextButton(onPressed: () => Native.copyText(text), child: const Text('Copy')),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _copyTranscript(String movie) async {
    try {
      await Native.copyText(await File(TranscriptFiles.textPath(movie)).readAsString());
    } catch (_) {}
  }

  /// A new name for a capture; a movie's transcript files are renamed with it.
  Future<void> _rename(String path) async {
    final controller = TextEditingController(text: _name(path));
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: SizedBox(
          width: 380,
          child: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Rename')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || name.trim() == _name(path)) return;
    try {
      final moved = await Native.renameCapture(path, name.trim());
      _transcripts.remove(path);
      _reload();
      if (moved != null && mounted) setState(() => _selected..clear()..add(moved));
    } on PlatformException catch (e) {
      await Native.toast(e.message ?? 'Could not rename it', symbol: 'exclamationmark.triangle.fill');
    }
  }

  List<File> get _shown {
    final q = _query.trim().toLowerCase();
    return q.isEmpty ? _files : _files.where((f) => _name(f.path).toLowerCase().contains(q)).toList();
  }

  Future<Uint8List?> _thumb(String path) {
    DateTime? m;
    try { m = File(path).lastModifiedSync(); } catch (_) {}
    return _thumbs.putIfAbsent('$path|$m', () => Native.thumbnail(path, size: 240));
  }

  // ---- Modes ----

  /// Draw mode (double-tap Option): the editor alone, full-window, over the frozen screen; no filmstrip, no Library button.
  bool _draw = false;

  /// What the window showed when draw mode began (the grid, or the editor on a picture): it comes back afterwards.
  ({bool editing, String? path})? _beforeDraw;
  /// That picture being loaded back (closeDraw): a new draw session waits for it, so it can never land on the glass.
  Future<void>? _restoring;

  Future<void> openDraw(String path) async {
    if (!_draw) {
      await _restoring;
      _restoring = null;
      _beforeDraw = (editing: _editing, path: _editingPath);
      await confirmDiscard(); // the glass takes over the editor: the open picture's edits are saved first, as on any switch
    }
    setState(() { _draw = true; _editing = true; _editingPath = path; });
    await WidgetsBinding.instance.endOfFrame;
    await _editor?.openFile(path, fresh: true);
    _editor?.focus();
  }

  /// Leaves draw mode WITHOUT saving: the drawing was only on top of a snapshot; ⌘S / Copy / Share inside draw
  /// mode are how it is kept.
  void closeDraw() {
    if (!_draw) return;
    final before = _beforeDraw;
    _beforeDraw = null;
    final back = before != null && before.editing && before.path != null && File(before.path!).existsSync() ? before.path : null;
    setState(() { _draw = false; _editing = false; _editingPath = null; });
    _reload();
    if (back != null) _restoring = _restore(back); // the picture that was open before draw mode, as it was
  }

  /// Straight into the editor, without waiting for a frame: the window is usually hidden now and paints none.
  Future<void> _restore(String path) async {
    setState(() { _editing = true; _editingPath = path; });
    await _editor?.openFile(path);
    _scrollFilmstripTo(path);
  }

  /// Enters (or switches within) edit mode, saving any unsaved edits first.
  Future<void> openForEditing(String path, {bool fresh = false}) async {
    if (_editing && _editingPath == path) return _editor?.focus();
    if (!await confirmDiscard()) return;
    if (fresh) {
      // Saving the capture we are leaving just stamped it "now", which would sort it ahead of the capture
      // that triggered this: the new one must be the newest, first in the filmstrip.
      try { File(path).setLastModifiedSync(DateTime.now()); } catch (_) {}
      _reload();
    }
    setState(() { _editing = true; _editingPath = path; });
    await WidgetsBinding.instance.endOfFrame;
    await _editor?.openFile(path, fresh: fresh);
    _editor?.focus(); // keys (⌘Z, ⌘C, Delete, tool letters) now go to the editor
    _scrollFilmstripTo(path);
  }

  Future<void> showGrid() async {
    if (_editing && !await confirmDiscard()) return;
    setState(() { _editing = false; _editingPath = null; });
    _reload();
    await windowManager.setTitle('SnapNow Library');
    _gridFocus.requestFocus();
  }

  /// Saves the editor's unsaved edits without asking (switching images, back to the grid, closing). Always
  /// safe: the saved PNG keeps the original capture and every annotation, so anything can be undone later.
  /// Returns true (go ahead), as the old Save / Don't Save / Cancel question did.
  Future<bool> confirmDiscard() async {
    final editor = _editor;
    if (_editing && editor != null && editor.hasUnsavedChanges) await editor.save();
    return true;
  }


  static const _filmTileWidth = 112.0, _filmGap = 8.0, _filmHeight = 92.0;

  void _scrollFilmstripTo(String path) {
    final i = _files.indexWhere((f) => f.path == path);
    if (i < 0 || !_filmScroll.hasClients) return;
    final target = (i * (_filmTileWidth + _filmGap) - (_filmScroll.position.viewportDimension - _filmTileWidth) / 2)
        .clamp(0.0, _filmScroll.position.maxScrollExtent);
    _filmScroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  // ---- Actions ----

  List<String> get _selection => [for (final f in _shown) if (_selected.contains(f.path)) f.path];

  void _open(List<String> paths) {
    final image = paths.where(_isImage).firstOrNull;
    if (image != null) openForEditing(image);
    for (final p in paths.where((p) => !_isImage(p))) {
      Native.openPath(p); // movies and GIFs open externally
    }
  }

  Future<void> _trash(List<String> paths) async {
    if (paths.isEmpty) return;
    await Native.trash(paths);
    _reload();
  }

  /// Deleting the capture being edited moves on to the next one, or back to the grid.
  Future<void> _trashFromFilmstrip(String path) async {
    if (path != _editingPath) return _trash([path]);
    final i = _files.indexWhere((f) => f.path == path); // its edits aren't saved: it's being deleted
    final rest = [for (final f in _files) if (f.path != path && _isImage(f.path)) f.path];
    await _trash([path]);
    if (rest.isEmpty) {
      setState(() { _editing = false; _editingPath = null; });
      return;
    }
    final next = rest[i.clamp(0, rest.length - 1)];
    setState(() => _editingPath = null); // straight to the next one, without saving the deleted one
    await _editor?.openFile(next);
    setState(() => _editingPath = next);
    _editor?.focus();
  }

  void _click(String path, {required bool meta, required bool shift}) {
    _gridFocus.requestFocus();
    setState(() {
      if (shift && _anchor != null) {
        final shown = _shown.map((f) => f.path).toList();
        final a = shown.indexOf(_anchor!), b = shown.indexOf(path);
        if (a >= 0 && b >= 0) {
          _selected.addAll(shown.sublist(a < b ? a : b, (a < b ? b : a) + 1));
          return;
        }
      }
      if (meta) {
        _selected.contains(path) ? _selected.remove(path) : _selected.add(path);
      } else {
        _selected..clear()..add(path);
      }
      _anchor = path;
    });
  }

  Future<void> _contextMenu(String path, Offset position) async {
    if (!_selected.contains(path)) setState(() { _selected..clear()..add(path); _anchor = path; });
    final paths = _selection;
    final single = paths.length == 1 ? paths.first : null;
    final movie = single != null && _movies.contains(_ext(single)) ? single : null;
    final transcript = movie == null ? const TranscriptInfo() : _transcripts[movie] ?? const TranscriptInfo();
    final hasText = movie != null && TranscriptFiles.hasText(movie);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 'open', child: Text('Open')),
        const PopupMenuItem(value: 'copy', child: Text('Copy')),
        if (single != null && _isImage(single)) const PopupMenuItem(value: 'text', child: Text('Copy Text')),
        const PopupMenuItem(value: 'reveal', child: Text('Show in Finder')),
        if (single != null && _movies.contains(_ext(single))) const PopupMenuItem(value: 'gif', child: Text('Export as GIF')),
        if (movie != null) ...[
          const PopupMenuDivider(),
          if (hasText) const PopupMenuItem(value: 'showTranscript', child: Text('Show Transcript')),
          if (hasText) const PopupMenuItem(value: 'copyTranscript', child: Text('Copy Transcript')),
          if (transcript.busy)
            PopupMenuItem(enabled: false, child: Text(transcript.label))
          else ...[
            if (transcript.state == TranscriptState.failed)
              PopupMenuItem(enabled: false, child: Text(transcript.label, maxLines: 2, overflow: TextOverflow.ellipsis)),
            PopupMenuItem(value: 'makeTranscript', child: Text(hasText ? 'Make Transcript Again' : 'Make Transcript')),
          ],
        ],
        if (single != null && single != _editingPath) const PopupMenuItem(value: 'rename', child: Text('Rename…')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'trash', child: Text('Move to Trash')),
      ],
    );
    switch (choice) {
      case 'open': _open(paths);
      case 'copy': await Native.copyFiles(paths);
      case 'text': await Native.copyTextOfFile(single!);
      case 'reveal': await Native.reveal(paths.first);
      case 'gif': await Native.exportGif(single!);
      case 'showTranscript': await _showTranscript(single!);
      case 'copyTranscript': await _copyTranscript(single!);
      case 'makeTranscript': await Native.makeTranscript(single!);
      case 'rename': await _rename(single!);
      case 'trash': await _trash(paths);
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    // Esc from anywhere in the window (grid, filmstrip, editor) saves and closes
    return AppMenuBar(library: this, child: CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): AppController.instance.saveAndClose},
      child: IndexedStack(
        index: _editing ? 1 : 0,
        children: [_gridMode(context), _editMode(context)],
      ),
    ));
  }

  Widget _gridMode(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _shown;
    return Scaffold(
      backgroundColor: SnapChrome.of(context).backdrop,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): () => _open(_selection),
          const SingleActivator(LogicalKeyboardKey.backspace, meta: true): () => _trash(_selection),
          const SingleActivator(LogicalKeyboardKey.delete): () => _trash(_selection),
          const SingleActivator(LogicalKeyboardKey.backspace): () => _trash(_selection),
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () => Native.copyFiles(_selection),
          const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
              setState(() => _selected.addAll(shown.map((f) => f.path))),
          const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () => windowManager.hide(),
        },
        child: Focus(
          focusNode: _gridFocus,
          autofocus: true,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 6),
              child: Row(children: [
                Text('Library', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(shown.length == 1 ? '1 capture' : '${shown.length} captures',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
                const Spacer(),
                SizedBox(
                  width: 220,
                  height: 30,
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'Search',
                      prefixIcon: Icon(Icons.search, size: 16, color: scheme.onSurfaceVariant),
                      prefixIconConstraints: const BoxConstraints(minWidth: 30),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: SnapChrome.of(context).controlBorder, width: 0.8)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Show in Finder',
                  onPressed: () => Native.openPath(AppController.capturesFolder),
                  icon: const Icon(Icons.folder_outlined, size: 18),
                ),
              ]),
            ),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.photo_library_outlined, size: 36, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                        const SizedBox(height: 10),
                        Text(_files.isEmpty ? 'No captures yet' : 'No matches',
                            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
                      ]),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 236, mainAxisExtent: 176, crossAxisSpacing: 14, mainAxisSpacing: 14),
                      itemCount: shown.length,
                      itemBuilder: (context, i) => _gridTile(shown[i].path),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _gridTile(String path) {
    return GestureDetector(
      onTap: () {
        final keys = HardwareKeyboard.instance;
        _click(path, meta: keys.isMetaPressed, shift: keys.isShiftPressed);
      },
      onDoubleTap: () => _open([path]),
      onSecondaryTapUp: (d) => _contextMenu(path, d.globalPosition),
      child: _Tile(
        path: path,
        name: _name(path),
        thumb: _thumb(path),
        selected: _selected.contains(path),
        badge: _movies.contains(_ext(path)) ? Icons.videocam : _ext(path) == 'gif' ? Icons.gif_box_outlined : null,
        transcript: _transcripts[path],
        onDelete: () => _trash([path]),
      ),
    );
  }

  /// Edit mode: the editor fills the window; its floating toolbar starts with the back button, and the
  /// filmstrip of all captures floats along the bottom (the editor keeps the picture clear of it).
  Widget _editMode(BuildContext context) {
    const m = 10.0;
    if (_draw) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: EditorPage(key: AppController.instance.editorKey, overlay: true),
      );
    }
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: EditorPage(
            key: AppController.instance.editorKey,
            chromeInsets: const EdgeInsets.only(bottom: _filmHeight + m * 2),
            leading: ToolbarButton(icon: Icons.photo_library_outlined, label: 'Library', tooltip: 'Back to the Library (Esc saves and closes)', onTap: showGrid),
          ),
        ),
        Positioned(
          left: m,
          right: m,
          bottom: m,
          height: _filmHeight,
          child: Container(
            decoration: SnapChrome.of(context).decoration(),
            clipBehavior: Clip.antiAlias,
            child: ListView.separated(
              controller: _filmScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: _files.length,
              separatorBuilder: (_, __) => const SizedBox(width: _filmGap),
              itemBuilder: (context, i) => _filmTile(_files[i].path),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _filmTile(String path) {
    final tile = SizedBox(
      width: _filmTileWidth,
      child: _Tile(
        path: path,
        name: _name(path),
        thumb: _thumb(path),
        selected: path == _editingPath,
        compact: true,
        badge: _movies.contains(_ext(path)) ? Icons.videocam : null,
        transcript: _transcripts[path],
        onDelete: () => _trashFromFilmstrip(path),
      ),
    );
    final clickable = Tooltip(
      message: _isImage(path) ? '${_name(path)}\nClick to edit · drag onto the picture to insert it' : _name(path),
      waitDuration: const Duration(milliseconds: 900),
      child: GestureDetector(
        onTap: () => _isImage(path) ? openForEditing(path) : Native.openPath(path),
        onSecondaryTapUp: (d) => _contextMenu(path, d.globalPosition),
        child: tile,
      ),
    );
    if (!_isImage(path)) return clickable;
    return Draggable<String>(
      data: path,
      feedback: Opacity(opacity: 0.85, child: Material(color: Colors.transparent, child: SizedBox(height: 76, child: tile))),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: clickable,
    );
  }
}

/// A capture thumbnail card: the picture on a rounded, borderless tile, its name underneath, a video/GIF
/// badge, and an accent ring when selected. Hovering lifts it and shows a ✕ that moves it to the Trash.
class _Tile extends StatefulWidget {
  final String path, name;
  final Future<Uint8List?> thumb;
  final bool selected, compact;
  final IconData? badge;
  final VoidCallback? onDelete;
  /// A movie's transcript: a CC mark when it has one, a progress ring while it is being made.
  final TranscriptInfo? transcript;

  const _Tile({required this.path, required this.name, required this.thumb, required this.selected,
      this.compact = false, this.badge, this.onDelete, this.transcript});

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chrome = SnapChrome.of(context);
    final w = widget;
    final radius = w.compact ? 8.0 : 10.0;
    final picture = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.all(w.compact ? 3 : 6),
      decoration: BoxDecoration(
        color: w.selected ? scheme.primary.withValues(alpha: 0.12) : chrome.raised.withValues(alpha: w.compact ? 0.6 : 1),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
            color: w.selected ? scheme.primary : (_hover ? scheme.outline : chrome.border), width: w.selected ? 2 : 0.8),
        boxShadow: _hover && !w.compact
            ? const [BoxShadow(color: Color(0x2E000000), blurRadius: 14, offset: Offset(0, 5))]
            : const [BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 4),
        child: Stack(fit: StackFit.expand, children: [
          FutureBuilder<Uint8List?>(
            future: w.thumb,
            builder: (context, snap) => snap.data == null
                ? const SizedBox()
                : Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium),
          ),
          if (w.badge != null)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                child: Icon(w.badge, size: 12, color: Colors.white),
              ),
            ),
          if (w.transcript case final t? when t.busy || t.state == TranscriptState.done || t.state == TranscriptState.failed)
            Positioned(
              right: 4,
              bottom: 4,
              child: Tooltip(
                message: t.label,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                  child: t.busy
                      ? SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white, value: t.state == TranscriptState.running && t.progress > 0 ? t.progress : null),
                        )
                      : Icon(t.state == TranscriptState.failed ? Icons.closed_caption_disabled_outlined : Icons.closed_caption,
                          size: 12, color: Colors.white),
                ),
              ),
            ),
        ]),
      ),
    );
    final card = Column(children: [
      Expanded(child: picture),
      if (!w.compact) ...[
        const SizedBox(height: 7),
        Text(w.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: w.selected ? scheme.onSurface : scheme.onSurfaceVariant,
                fontWeight: w.selected ? FontWeight.w500 : FontWeight.w400)),
      ],
    ]);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(children: [
        Positioned.fill(child: card),
        if (_hover && w.onDelete != null)
          Positioned(
            left: w.compact ? 2 : 4,
            top: w.compact ? 2 : 4,
            child: Tooltip(
              message: 'Move to Trash',
              waitDuration: const Duration(milliseconds: 600),
              child: GestureDetector(
                onTap: w.onDelete,
                child: Container(
                  width: 20, height: 20,
                  decoration: BoxDecoration(
                    color: const Color(0xEE3A3A3C),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                    boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 3, offset: Offset(0, 1))],
                  ),
                  child: const Icon(Icons.close, size: 12, color: Colors.white),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
