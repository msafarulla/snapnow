import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/editor/properties_panel.dart';
import 'package:snaplite_flutter/model/annotation.dart';
import 'package:snaplite_flutter/platform/native.dart';

/// Draw mode (the glass): a drawn arrow, once clicked, can be recoloured from its colour bar and from the system colour
/// panel the bar's "Any color" bubble opens (natively raised above the glass, see LiveDraw.presentOverGlass), and its
/// thickness and heads changed, all without a new stroke being drawn; the next arrow is drawn in the chosen colour.
/// Mouse pointers throughout, as on the real glass.
void main() {
  const mouse = PointerDeviceKind.mouse;
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (call) async {
        if (ch == 'snaplite/native') calls.add(call);
        return null;
      });
    }
  });

  Future<EditorPageState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The test font is wider than the real one, so fixed-width rows report "overflowed": ignore only those
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key, overlay: true)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    return key.currentState!;
  }

  Offset at(WidgetTester tester, double fx, double fy) {
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    return Offset(area.left + area.width * fx, area.top + area.height * fy);
  }

  final colorBar = find.byKey(const ValueKey('snaplite-colorbar'));
  final thickness = find.byKey(const ValueKey('snaplite-thickness'));
  Finder bubble(String name) =>
      find.descendant(of: colorBar, matching: find.byWidgetPredicate((w) => w is Tooltip && w.message == name));
  Color named(String name) => PropertiesPanel.colors.firstWhere((c) => c.$1 == name).$2;

  Future<void> arrow(WidgetTester tester, Offset from, Offset to) async {
    await tester.dragFrom(from, to - from, kind: mouse);
    await tester.pump();
  }

  /// An arrow drawn on the glass and then clicked, so its colour bar and thickness slider are up.
  Future<Annotation> drawAndSelect(WidgetTester tester, EditorPageState editor) async {
    await tester.tap(find.text('Arrow').hitTestable(), kind: mouse);
    await tester.pump();
    final from = at(tester, 0.3, 0.6), to = at(tester, 0.45, 0.45);
    await arrow(tester, from, to);
    expect(editor.selected, isNull, reason: 'a new arrow on the glass is not selected');
    await tester.tapAt(Offset.lerp(from, to, 0.5)!, kind: mouse);
    await tester.pump();
    expect(editor.selected, isNotNull, reason: 'a click on it selects it');
    expect(colorBar, findsOneWidget);
    expect(thickness, findsOneWidget);
    return editor.selected!;
  }

  testWidgets('a colour bubble recolours the selected arrow on the glass, no new stroke; the next arrow takes the colour',
      (tester) async {
    final editor = await pump(tester);
    final a = await drawAndSelect(tester, editor);
    final blue = named('Blue');
    expect(a.color.toARGB32(), isNot(blue.toARGB32()));

    await tester.tap(bubble('Blue').hitTestable(), kind: mouse);
    await tester.pump();
    expect(editor.state!.annotations.length, 1, reason: 'the click on the bar did not draw a new arrow');
    expect(editor.selected?.id, a.id, reason: 'the arrow stays selected');
    expect(editor.selected!.color.toARGB32(), blue.toARGB32(), reason: 'recoloured');
    expect(colorBar, findsOneWidget, reason: 'the bar stays up for another pick');

    // Another pick on the same arrow
    await tester.tap(bubble('Green').hitTestable(), kind: mouse);
    await tester.pump();
    expect(editor.selected!.color.toARGB32(), named('Green').toARGB32());
    expect(editor.state!.annotations.length, 1);

    // Drawing on empty glass: a new arrow in the chosen colour, as in the editor
    await arrow(tester, at(tester, 0.6, 0.7), at(tester, 0.75, 0.6));
    expect(editor.state!.annotations.length, 2, reason: 'drawing on empty glass still starts a stroke');
    expect(editor.state!.annotations.last.color.toARGB32(), named('Green').toARGB32(), reason: 'the next arrow uses the chosen colour');
  });

  testWidgets('"Any color" opens the system panel; its colour recolours the selected arrow', (tester) async {
    final editor = await pump(tester);
    final a = await drawAndSelect(tester, editor);
    await tester.tap(bubble('Any color').hitTestable(), kind: mouse);
    await tester.pump();
    final open = calls.where((c) => c.method == 'showColorPanel').toList();
    expect(open, hasLength(1), reason: 'the native panel is asked for (the native side raises it above the glass)');
    expect((open.single.arguments as Map)['color'], a.color.toARGB32() & 0xFFFFFF, reason: 'it opens at the arrow colour');
    expect(editor.state!.annotations.length, 1);

    // The panel sends its colour back as "colorPicked" (the glass keeps its selection meanwhile)
    Native.onColorPicked!(0x2266AA);
    await tester.pump();
    expect(editor.selected?.id, a.id);
    expect(editor.selected!.color.toARGB32(), 0xFF2266AA, reason: 'recoloured from the panel');
    expect(editor.state!.annotations.length, 1);
  });

  testWidgets('the thickness slider and the head menu work on the glass too, no new stroke', (tester) async {
    final editor = await pump(tester);
    final a = await drawAndSelect(tester, editor);
    final before = a.arrowStyle.width ?? a.size.line;

    await tester.drag(thickness, const Offset(0, -80), kind: mouse); // up = thicker (the slider stands upright)
    await tester.pump();
    expect(editor.selected?.id, a.id);
    expect(editor.selected!.arrowStyle.width, isNotNull);
    expect(editor.selected!.arrowStyle.width!, greaterThan(before), reason: 'thicker');
    expect(editor.state!.annotations.length, 1);

    final end = editor.selected!.arrowStyle.end;
    final other = ArrowHead.values.firstWhere((h) => h != end && h != ArrowHead.none);
    await tester.tap(find.byKey(const ValueKey('snaplite-bar-end')).hitTestable(), kind: mouse);
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuItem && w.value == other).hitTestable().first, kind: mouse);
    await tester.pumpAndSettle();
    expect(editor.selected?.id, a.id);
    expect(editor.selected!.arrowStyle.end, other, reason: 'the end head changed');
    expect(editor.state!.annotations.length, 1);
  });
}
