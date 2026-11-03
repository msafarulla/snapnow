import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/editor_page.dart';
import '../library/library_page.dart';
import '../manim/manim_doc.dart';
import '../manim/manim_studio_page.dart';
import '../model/annotation.dart';
import '../platform/native.dart';
import 'app_controller.dart';

/// The macOS menu bar while SnapNow is in front, as in any Mac app: SnapNow · File · Edit · View · Image ·
/// Tools · Window · Help. The window itself keeps only the annotating tools.
///
/// The shortcuts shown here are the editor's own keys: Flutter handles a key first and only hands it to the
/// menu when nothing in the window wants it, so a shortcut never runs twice, and while you're typing in a
/// text box ⌘C / ⌘V / ⌘Z stay with the text.
class AppMenuBar extends StatelessWidget {
  final LibraryPageState library;
  final Widget child;
  const AppMenuBar({super.key, required this.library, required this.child});

  static const _tools = <(Tool, String)>[
    (Tool.select, 'Select'), (Tool.arrow, 'Arrow'), (Tool.text, 'Text'), (Tool.callout, 'Callout'),
    (Tool.box, 'Shape'), (Tool.line, 'Line'), (Tool.pen, 'Pen'), (Tool.step, 'Step'), (Tool.highlight, 'Highlight'),
    (Tool.blur, 'Blur'), (Tool.spotlight, 'Spotlight'), (Tool.crop, 'Crop'), (Tool.grabText, 'Copy Text Tool'),
  ];

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) return child;
    // Manim Studio, while open, gets its own menus
    return ValueListenableBuilder<ManimStudioPageState?>(
      valueListenable: ManimStudioPage.active,
      builder: (context, studio, _) => studio != null
          ? _studioMenus(studio)
          // Rebuilt when the toolbar changes side, so View › Move Toolbar… names the other edge
          : ValueListenableBuilder<bool>(valueListenable: EditorPageState.toolbarLeft, builder: (context, _, _) => _menus(context)),
    );
  }

  Widget _studioMenus(ManimStudioPageState studio) {
    PlatformMenuItem item(String label, VoidCallback? onSelected, [MenuSerializableShortcut? shortcut]) =>
        PlatformMenuItem(label: label, onSelected: onSelected, shortcut: shortcut);
    PlatformProvidedMenuItem? provided(PlatformProvidedMenuItemType t) =>
        PlatformProvidedMenuItem.hasMenu(t) ? PlatformProvidedMenuItem(type: t) : null;
    PlatformMenuItemGroup? group(List<PlatformMenuItem> members) =>
        members.isEmpty ? null : PlatformMenuItemGroup(members: members);
    return PlatformMenuBar(
      menus: [
        PlatformMenu(label: 'SnapNow', menus: [
          ?group([?provided(PlatformProvidedMenuItemType.about)]),
          ?group([?provided(PlatformProvidedMenuItemType.hide), ?provided(PlatformProvidedMenuItemType.quit)]),
        ]),
        PlatformMenu(label: 'File', menus: [
          ?group([
            item('New Manim Video', () => ManimStudioPage.open(studio.context)),
            item('Open Manim Project…', () => ManimStudioPage.pickAndOpen(studio.context)),
          ]),
          ?group([
            item('Save As…', studio.saveAs),
            item('Render', studio.render, const SingleActivator(LogicalKeyboardKey.enter, meta: true)),
            item('Show Code', studio.showCode),
          ]),
          ?group([item('Close Studio', () => Navigator.of(studio.context).maybePop(), const SingleActivator(LogicalKeyboardKey.keyW, meta: true))]),
        ]),
        PlatformMenu(label: 'Edit', menus: [
          ?group([
            item('Duplicate', studio.duplicate, const SingleActivator(LogicalKeyboardKey.keyD, meta: true)),
            item('Delete', studio.delete),
          ]),
        ]),
        PlatformMenu(label: 'Insert', menus: [
          for (final k in MKind.values) item(k == MKind.image ? 'Image…' : k.label, () => studio.add(k)),
        ]),
        PlatformMenu(label: 'Window', menus: [
          ?group([?provided(PlatformProvidedMenuItemType.minimizeWindow), ?provided(PlatformProvidedMenuItemType.zoomWindow)]),
        ]),
      ],
      child: child,
    );
  }

  Widget _menus(BuildContext context) {
    final editing = library.editing;
    final editor = AppController.instance.editorKey.currentState;
    // Editor commands while editing; grid commands otherwise
    void ed(String id) => editor?.runMenu(id);
    void grid(String id) => library.runMenu(id);

    PlatformMenuItem item(String label, VoidCallback? onSelected, [MenuSerializableShortcut? shortcut]) =>
        PlatformMenuItem(label: label, onSelected: onSelected, shortcut: shortcut);
    SingleActivator cmd(LogicalKeyboardKey k, {bool shift = false, bool alt = false, bool ctrl = false}) =>
        SingleActivator(k, meta: true, shift: shift, alt: alt, control: ctrl);
    PlatformProvidedMenuItem? provided(PlatformProvidedMenuItemType t) =>
        PlatformProvidedMenuItem.hasMenu(t) ? PlatformProvidedMenuItem(type: t) : null;
    // Groups whose items all depend on the platform can come out empty (tests), which isn't allowed
    PlatformMenuItemGroup? group(List<PlatformMenuItem> members) =>
        members.isEmpty ? null : PlatformMenuItemGroup(members: members);

    return PlatformMenuBar(
      menus: [
        PlatformMenu(label: 'SnapNow', menus: [
          ?group([?provided(PlatformProvidedMenuItemType.about)]),
          ?group([item('Settings…', () => Native.shell('settings'), cmd(LogicalKeyboardKey.comma))]),
          ?group([?provided(PlatformProvidedMenuItemType.servicesSubmenu)]),
          ?group([
            ?provided(PlatformProvidedMenuItemType.hide),
            ?provided(PlatformProvidedMenuItemType.hideOtherApplications),
            ?provided(PlatformProvidedMenuItemType.showAllApplications),
          ]),
          ?group([?provided(PlatformProvidedMenuItemType.quit)]),
        ]),
        PlatformMenu(label: 'File', menus: [
          ?group([
            PlatformMenu(label: 'New Capture', menus: [
              item('Area  (⌃⇧C)', () => Native.shell('region')),
              item('Window  (⌃⇧W)', () => Native.shell('window')),
              item('Full Screen  (⌃⇧F)', () => Native.shell('screen')),
              item('Record Screen  (⌃⇧R)', () => Native.shell('record')),
              item('Copy Text from Screen  (⌃⇧T)', () => Native.shell('text')),
            ]),
            item('Open Image…', editing ? () => ed('open') : () => Native.shell('openImage'), cmd(LogicalKeyboardKey.keyO)),
            if (!editing) item('Open Selected', () => grid('openSelected')),
          ]),
          ?group([
            // While editing, the drawing lands on the canvas; from the Library it becomes a new capture
            item('New Excalidraw Drawing', () => editing ? ed('whiteboard') : AppController.instance.newDrawing(library.context)),
            item('New Manim Video', () => ManimStudioPage.open(library.context)),
            item('Open Manim Project…', () => ManimStudioPage.pickAndOpen(library.context)),
          ]),
          ?group([
            item('Close', AppController.instance.saveAndClose, cmd(LogicalKeyboardKey.keyW)),
            if (editing) ...[
              item('Save', () => ed('save'), cmd(LogicalKeyboardKey.keyS)),
              item('Save As…', () => ed('saveAs'), cmd(LogicalKeyboardKey.keyS, shift: true)),
              item('Save as Animated GIF…', () => ed('saveGif')),
              item('Open in Excalidraw…', () => ed('excalidraw')),
              item('Open in Manim Studio…', () => ed('manim')),
            ],
          ]),
          if (editing)
            ?group([
              item('Share…', () => ed('share')),
              item('Show in Finder', () => ed('reveal')),
            ]),
        ]),
        PlatformMenu(label: 'Edit', menus: [
          if (editing) ...[
            ?group([
              item('Undo', () => ed('undo'), cmd(LogicalKeyboardKey.keyZ)),
              item('Redo', () => ed('redo'), cmd(LogicalKeyboardKey.keyZ, shift: true)),
            ]),
            ?group([
              item('Cut', () => ed('cut'), cmd(LogicalKeyboardKey.keyX)),
              item('Copy', () => ed('copy'), cmd(LogicalKeyboardKey.keyC)),
              item('Paste', () => ed('paste'), cmd(LogicalKeyboardKey.keyV)),
              item('Duplicate', () => ed('duplicate'), cmd(LogicalKeyboardKey.keyD)),
              item('Copy as Animated GIF', () => ed('copyGif'), cmd(LogicalKeyboardKey.keyC, shift: true)),
              item('Copy as WhatsApp Sticker', () => ed('copySticker'), cmd(LogicalKeyboardKey.keyC, ctrl: true)),
              item('Copy as Still Sticker', () => ed('copyStillSticker')),
              item('Copy All Text', () => ed('copyText')),
            ]),
            ?group([
              item('Delete', () => ed('delete')),
              item('Select Same Shapes', () => ed('selectAll'), cmd(LogicalKeyboardKey.keyA)),
            ]),
          ] else ...[
            ?group([
              item('Copy', () => grid('copyFiles'), cmd(LogicalKeyboardKey.keyC)),
              item('Select All', () => grid('selectAll'), cmd(LogicalKeyboardKey.keyA)),
            ]),
            ?group([item('Move to Trash', () => grid('trash'), cmd(LogicalKeyboardKey.backspace))]),
          ],
        ]),
        PlatformMenu(label: 'View', menus: [
          if (editing)
            ?group([
              item('Zoom In', () => ed('zoomIn'), cmd(LogicalKeyboardKey.equal)),
              item('Zoom Out', () => ed('zoomOut'), cmd(LogicalKeyboardKey.minus)),
              item('Zoom to Fit', () => ed('zoomFit'), cmd(LogicalKeyboardKey.digit0)),
              item('Actual Size', () => ed('zoomActual'), cmd(LogicalKeyboardKey.digit1)),
            ]),
          if (editing)
            ?group([
              item(EditorPageState.toolbarLeft.value ? 'Move Toolbar to Top' : 'Move Toolbar to Left', () => ed('toolbarSide')),
            ]),
          ?group([
            item(editing ? 'Back to Library' : 'Library', () => grid('library')),
            ?provided(PlatformProvidedMenuItemType.toggleFullScreen),
          ]),
        ]),
        if (editing) ...[
          PlatformMenu(label: 'Image', menus: [
            ?group([
              item('Flip Horizontal', () => ed('flipH')),
              item('Flip Vertically', () => ed('flipV')),
            ]),
            ?group([
              item('Trim', () => ed('trim')),
              item('Crop to Canvas', () => ed('cropCanvas')),
              item('Resize Canvas…', () => ed('resize')),
              item('Change Canvas Colour…', () => ed('canvasColor')),
            ]),
            ?group([
              item('Add Image…', () => ed('addImage')),
              item('Flatten All', () => ed('flatten')),
            ]),
          ]),
          PlatformMenu(label: 'Tools', menus: [
            for (final (t, label) in _tools) item(label, () => ed(t.name)),
          ]),
        ],
        PlatformMenu(label: 'Window', menus: [
          ?group([
            ?provided(PlatformProvidedMenuItemType.minimizeWindow),
            ?provided(PlatformProvidedMenuItemType.zoomWindow),
          ]),
          if (editing)
            ?group([
              item(editor?.pinned == true ? 'Stop Keeping on Top' : 'Keep on Top', () => ed('pin'),
                  cmd(LogicalKeyboardKey.keyT, alt: true)),
            ]),
          ?group([?provided(PlatformProvidedMenuItemType.arrangeWindowsInFront)]),
        ]),
        PlatformMenu(label: 'Help', menus: [
          item('SnapNow on GitHub', () => Native.openUrl('https://github.com/msafarulla/snapnow')),
        ]),
      ],
      child: child,
    );
  }
}
