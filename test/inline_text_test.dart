import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/editor/properties_panel.dart';
import 'package:snaplite_flutter/editor/quick_styles.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Typing straight into Callout bubbles and Text boxes (no dialog).
final inlineField = find.byKey(const ValueKey('snaplite-inline-text'));

void main() {
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  Future<EditorPageState> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The test font is wider than the real one, so fixed-width panel rows report "overflowed": ignore only those
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    final key = GlobalKey<EditorPageState>();
    // Real async, so the blank canvas image (toImage) finishes loading
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    return key.currentState!;
  }

  /// A point inside the canvas image, as a fraction of the canvas area left of the panel.
  Offset onCanvas(WidgetTester tester, double fx, double fy) {
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    return Offset(area.left + area.width * fx, area.top + area.height * fy);
  }

  testWidgets('drag a callout, type into the bubble, Return keeps it', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();

    final tip = onCanvas(tester, 0.3, 0.3);
    await tester.dragFrom(tip, const Offset(160, 120));
    await tester.pump();

    expect(inlineField, findsOneWidget, reason: 'an inline text field opens in the bubble');
    await tester.enterText(inlineField, 'Look here');
    await tester.pump();
    final live = editor.selected!.shape as CalloutShape;
    expect(live.string, 'Look here', reason: 'the bubble follows what is typed');
    expect(live.tail, isNotNull, reason: 'it points at where the drag started');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // Return
    await tester.pump();
    expect(inlineField, findsNothing);
    expect((editor.selected!.shape as CalloutShape).string, 'Look here');
    expect(editor.hasUnsavedChanges, isTrue);
  });

  testWidgets('Esc cancels a new callout; an empty one disappears', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();

    await tester.dragFrom(onCanvas(tester, 0.3, 0.3), const Offset(150, 100));
    await tester.pump();
    await tester.enterText(inlineField, 'nope');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(inlineField, findsNothing);
    expect(editor.selected, isNull, reason: 'Esc removes the new callout');
    expect(editor.hasUnsavedChanges, isFalse);

    await tester.dragFrom(onCanvas(tester, 0.4, 0.4), const Offset(150, 100));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // Return with nothing typed
    await tester.pump();
    expect(editor.selected, isNull, reason: 'an empty new callout is dropped');
    expect(editor.hasUnsavedChanges, isFalse);
  });

  testWidgets('Text tool types in place too', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Text'));
    await tester.pump();
    await tester.tapAt(onCanvas(tester, 0.5, 0.5));
    await tester.pump();
    expect(inlineField, findsOneWidget);
    await tester.enterText(inlineField, 'Hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((editor.selected!.shape as TextShape).string, 'Hello');
  });

  testWidgets('double-click a callout to change its text', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();
    final tip = onCanvas(tester, 0.3, 0.3);
    const drag = Offset(160, 120);
    await tester.dragFrom(tip, drag);
    await tester.pump();
    await tester.enterText(inlineField, 'Look here');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // The bubble is centred where the drag ended
    final bubble = tip + drag;
    await tester.tapAt(bubble);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(bubble);
    await tester.pump();
    expect(inlineField, findsOneWidget, reason: 'double-click opens the text for editing');
    expect(tester.widget<TextField>(inlineField).controller!.text, 'Look here');

    await tester.enterText(inlineField, 'Changed');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((editor.selected!.shape as CalloutShape).string, 'Changed');
  });

  testWidgets('Option+Return (Alt+Enter) and Shift+Return add a new line; Return finishes', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.3, 0.3), const Offset(160, 120));
    await tester.pump();
    await tester.enterText(inlineField, 'First line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.alt);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.alt);
    await tester.pump();
    expect(inlineField, findsOneWidget, reason: 'Option+Return keeps typing');
    final field = tester.widget<TextField>(inlineField);
    expect(field.controller!.text, 'First line\n');
    // keep typing on the new line
    field.controller!.value = TextEditingValue(text: 'First line\nSecond', selection: const TextSelection.collapsed(offset: 17));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(field.controller!.text, 'First line\nSecond\n');
    field.controller!.value = TextEditingValue(text: 'First line\nSecond\nThird', selection: const TextSelection.collapsed(offset: 23));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // plain Return finishes
    await tester.pump();
    expect(inlineField, findsNothing);
    expect((editor.selected!.shape as CalloutShape).string, 'First line\nSecond\nThird');
  });

  testWidgets('while typing several lines, the text box matches the bubble (no spill)', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.3, 0.3), const Offset(160, 120));
    await tester.pump();
    final field = tester.widget<TextField>(inlineField);
    field.controller!.value = const TextEditingValue(text: 'one\ntwo\nthree\nfour', selection: TextSelection.collapsed(offset: 18));
    await tester.pump();

    // The blank canvas is 1200 x 800, fitted into the canvas area with 20 px padding (at most 1:1)
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    final scale = [(area.width - 40) / 1200, (area.height - 40) / 800, 1.0].reduce((a, b) => a < b ? a : b);
    final a = editor.selected!;
    final drawn = CanvasPainter.textLayout((a.shape as CalloutShape).string, a, Colors.white).height * scale;
    final typed = tester.getSize(inlineField).height;
    expect(typed, closeTo(drawn, 2), reason: 'four typed lines take the same height as the four drawn lines');
  });

  testWidgets('formatting applies while typing and keeps the text field open', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.3, 0.3), const Offset(160, 120));
    await tester.pump();
    await tester.enterText(inlineField, 'Styled');
    editor.setTextFormat(editor.textFormat.copyWith(italic: true, align: TextAlign.center, family: 'Georgia').withPoints(40));
    await tester.pump();
    await tester.pump();
    expect(inlineField, findsOneWidget, reason: 'still typing');
    final f = editor.selected!.textFormat;
    expect([f.italic, f.align, f.family, f.points], [true, TextAlign.center, 'Georgia', 40]);
    expect(tester.widget<TextField>(inlineField).textAlign, TextAlign.center);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect((editor.selected!.shape as CalloutShape).string, 'Styled');
    expect(editor.selected!.textFormat.italic, isTrue);
    expect(editor.textFormat.family, 'Georgia', reason: 'remembered for the next callout');
  });

  testWidgets('the format bar appears only when text is highlighted, right of the text', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.3, 0.3), const Offset(160, 120));
    await tester.pump();
    await tester.enterText(inlineField, 'Next to me');
    await tester.pump();
    expect(find.byType(TextFormatBar), findsNothing, reason: 'not while just typing');

    // Highlight "Next"
    final controller = tester.widget<TextField>(inlineField).controller!;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();
    expect(find.byType(TextFormatBar), findsOneWidget, reason: 'shown once text is highlighted');
    final bar = tester.getRect(find.byType(TextFormatBar));
    final field = tester.getRect(inlineField);
    expect(bar.left, greaterThan(field.right), reason: 'to the right of the text');
    expect((bar.top - field.top).abs(), lessThan(60), reason: 'level with the text');

    await tester.tap(find.descendant(of: find.byType(TextFormatBar), matching: find.byTooltip('Italic')));
    await tester.pump();
    await tester.pump();
    expect(inlineField, findsOneWidget, reason: 'clicking the bar does not end typing');
    expect(editor.selected!.textFormat.italic, isFalse, reason: 'not the whole text');
    final runs = (editor.selected!.shape as CalloutShape).runs;
    expect(runs.length, 1);
    expect([runs.first.start, runs.first.end, runs.first.style.italic], [0, 4, true], reason: 'only "Next" is italic');

    controller.selection = const TextSelection.collapsed(offset: 10);
    await tester.pump();
    expect(find.byType(TextFormatBar), findsNothing, reason: 'gone when nothing is highlighted');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byType(TextFormatBar), findsNothing, reason: 'not for a merely selected callout');
  });

  testWidgets('colour and bold apply to just the highlighted words and follow edits', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.3, 0.3), const Offset(160, 120));
    await tester.pump();
    await tester.enterText(inlineField, 'Next to me');
    final controller = tester.widget<TextField>(inlineField).controller!;
    controller.selection = const TextSelection(baseOffset: 5, extentOffset: 7); // "to"
    await tester.pump();

    Finder bar(String tip) => find.descendant(of: find.byType(TextFormatBar), matching: find.byTooltip(tip));
    await tester.tap(bar('Red'));
    await tester.pump();
    await tester.pump();
    await tester.tap(bar('Bold')); // the callout default is bold, so this makes "to" regular
    await tester.pump();
    await tester.pump();
    List<TextRun> runs() => (editor.selected!.shape as CalloutShape).runs;
    expect(runs().length, 1);
    expect([runs().first.start, runs().first.end], [5, 7], reason: 'only "to"');
    expect(runs().first.style.color, const Color(0xFFFF3B30));
    expect(runs().first.style.bold, isFalse);

    // Typing before it (one edit at a time, like a person) keeps the formatting on "to"
    controller.value = const TextEditingValue(text: '>> Next to me', selection: TextSelection.collapsed(offset: 3));
    await tester.pump();
    controller.value = const TextEditingValue(text: '>> Next to me.', selection: TextSelection.collapsed(offset: 14));
    await tester.pump();
    expect(controller.text.substring(runs().first.start, runs().first.end), 'to', reason: 'moved with the text');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final shape = editor.selected!.shape as CalloutShape;
    expect(shape.string, '>> Next to me.');
    expect(shape.string.substring(shape.runs.first.start, shape.runs.first.end), 'to', reason: 'kept after finishing');
  });

  testWidgets('drag the bubble alone (pointer stays), the tip alone (bubble stays), or both with Option', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();
    final tip = onCanvas(tester, 0.3, 0.3);
    const toBubble = Offset(160, 120);
    await tester.dragFrom(tip, toBubble);
    await tester.pump();
    await tester.enterText(inlineField, 'Look here');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    CalloutShape shape() => editor.selected!.shape as CalloutShape;
    final start = shape();

    // 1. Drag the bubble: only the bubble moves
    await tester.dragFrom(tip + toBubble, const Offset(60, 40));
    await tester.pump();
    expect(shape().tail, start.tail, reason: 'the pointer tip stays anchored');
    expect(shape().at.dx, greaterThan(start.at.dx));
    final afterBubble = shape();

    // 2. Drag the tip handle: only the tip moves
    await tester.dragFrom(tip, const Offset(-30, 25));
    await tester.pump();
    expect(shape().at, afterBubble.at, reason: 'the bubble stays put');
    expect(shape().tail, isNot(afterBubble.tail));
    final afterTip = shape();

    // 3. Option-drag the bubble: both move together
    await tester.sendKeyDownEvent(LogicalKeyboardKey.alt);
    await tester.dragFrom(tip + toBubble + const Offset(60, 40), const Offset(40, 30));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.alt);
    await tester.pump();
    final moved = shape();
    expect(moved.at - afterTip.at, isNot(Offset.zero));
    expect((moved.tail! - afterTip.tail!).dx, closeTo((moved.at - afterTip.at).dx, 0.01), reason: 'tip moved by the same amount');
  });

  testWidgets('a new arrow has a Swept head by default', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.3, 0.6), const Offset(150, -100));
    await tester.pump();
    expect(editor.selected!.shape, isA<ArrowShape>());
    expect(editor.selected!.arrowStyle.end, ArrowHead.swept);
    expect(ArrowStyle.arrow.end, ArrowHead.swept, reason: 'also what Reset Style goes back to');
  });

  testWidgets('My Styles sits under the presets; + saves the current look', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    expect(find.text('MY STYLES'), findsOneWidget, reason: 'always shown below the built-in styles');
    final before = QuickStyles.saved(QuickKind.arrow).length;
    await tester.tap(find.byTooltip('Save the current style to My Styles'));
    await tester.pump();
    await tester.pump();
    expect(QuickStyles.saved(QuickKind.arrow).length, before + 1);
    expect(QuickStyles.saved(QuickKind.arrow).first.style.end, ArrowHead.swept, reason: 'your current arrow look');
    expect(find.byTooltip('This style is already in My Styles'), findsOneWidget);
  });

  testWidgets('arrows bend through points on the curve: drag a +, double-click to add or remove', (tester) async {
    final editor = await pumpEditor(tester);
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    final scale = editor.viewScale; // the editor fits the picture into the space its floating chrome leaves free
    final origin = area.topLeft + editor.viewOrigin;
    Offset screen(Offset img) => origin + img * scale;

    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(screen(const Offset(300, 500)), const Offset(300, -150));
    await tester.pump();
    ArrowShape arrow() => editor.selected!.shape as ArrowShape;
    final straight = arrow();
    expect(straight.points, isEmpty);

    // Drag the "+" in the middle of the arrow: a bend point appears there and follows the drag
    final plus = CanvasPainter.addHandles([straight.from, straight.to]).single;
    await tester.dragFrom(screen(plus), const Offset(0, 80));
    await tester.pump();
    expect(arrow().points.length, 1);
    expect([arrow().from, arrow().to], [straight.from, straight.to], reason: 'the ends stay put');
    final bend = arrow().points.single;
    expect((bend - (plus + const Offset(0, 80) / 1)).distance, lessThan(80 / scale + 1), reason: 'moved with the drag');
    final samples = CanvasPainter.curveSamples(editor.selected!.curve!);
    expect(samples.any((s) => (s - bend).distance < 1), isTrue, reason: 'the curve passes through the point');

    // Double-click elsewhere on the curve: a second point
    final onCurve = samples[samples.length ~/ 4 + 5]; // on the curve, away from the + handles
    await tester.tapAt(screen(onCurve));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(screen(onCurve));
    await tester.pump();
    expect(arrow().points.length, 2);

    // Double-click a point: removed
    await tester.tapAt(screen(arrow().points.first));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(screen(arrow().points.first));
    await tester.pump();
    expect(arrow().points.length, 1);

    editor.straighten();
    await tester.pump();
    expect(arrow().points, isEmpty);
  });

  testWidgets('each point has a tangent line; dragging its handle steers the curve, double-click resets', (tester) async {
    final editor = await pumpEditor(tester);
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    final scale = editor.viewScale; // the editor fits the picture into the space its floating chrome leaves free
    final origin = area.topLeft + editor.viewOrigin;
    Offset screen(Offset img) => origin + img * scale;

    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(screen(const Offset(250, 500)), const Offset(320, -120));
    await tester.pump();
    // Bend it once through the middle "+"
    final plus = CanvasPainter.addHandles(editor.selected!.curve!).single;
    await tester.dragFrom(screen(plus), const Offset(0, 70));
    await tester.pump();
    final a = editor.selected!;
    final grips = CanvasPainter.curveGrips(a);
    final tangents = grips.where((g) => g.kind == GripKind.tangent).toList();
    expect(tangents.length, 4, reason: 'one inward at each end, two through the bend point');
    final bendTangent = tangents.firstWhere((g) => g.index == 1 && g.side == 1);
    final bendBefore = a.curve![1];

    // Drag the bend point's tangent handle: the curve's direction there changes, the point stays
    await tester.dragFrom(screen(bendTangent.at), const Offset(0, -50));
    await tester.pump();
    final b = editor.selected!;
    expect(b.curveTangents[1], isNotNull, reason: 'a tangent was set');
    expect(b.curve![1], bendBefore, reason: 'the bend point does not move');
    final mirrored = CanvasPainter.curveGrips(b).firstWhere((g) => g.kind == GripKind.tangent && g.index == 1 && g.side == -1);
    expect((mirrored.at - bendBefore).direction, closeTo((bendBefore - CanvasPainter.curveGrips(b)
        .firstWhere((g) => g.kind == GripKind.tangent && g.index == 1 && g.side == 1).at).direction, 0.001),
        reason: 'both sides move together, so the curve stays smooth');

    // Double-click the tangent handle: automatic again
    final handle = CanvasPainter.curveGrips(b).firstWhere((g) => g.kind == GripKind.tangent && g.index == 1 && g.side == 1).at;
    await tester.tapAt(screen(handle));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(screen(handle));
    await tester.pump();
    expect(editor.selected!.curveTangents[1], isNull);
  });

  testWidgets('clicking an arrow shows a thickness slider beside it; drag up = thicker, one undo step', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.3, 0.6), const Offset(150, -100));
    await tester.pump();
    final slider = find.byKey(const ValueKey('snaplite-thickness'));
    expect(slider, findsOneWidget, reason: 'shown for the selected arrow');
    final before = editor.selected!.lineWidth;
    expect(editor.selected!.arrowStyle.width, isNull, reason: 'starts from the S/M/L size');

    await tester.drag(slider, const Offset(0, -70)); // up
    await tester.pump();
    expect(editor.selected!.lineWidth, greaterThan(before), reason: 'thicker');
    expect(editor.selected!.arrowStyle.width, isNotNull);
    expect(editor.currentArrowStyle.width, editor.selected!.arrowStyle.width, reason: 'remembered for the next arrow');

    // One undo step for the whole drag
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    final undone = editor.selected ?? (editor.hasUnsavedChanges ? null : null);
    expect(undone == null || undone.arrowStyle.width == null, isTrue, reason: 'back to before the drag');

    // S / M / L replace a slider thickness
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.5, 0.6), const Offset(150, -100));
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('snaplite-thickness')), const Offset(0, -50));
    await tester.pump();
    expect(editor.selected!.arrowStyle.width, isNotNull);
    editor.pickSize(StrokeSize.large);
    await tester.pump();
    expect(editor.selected!.arrowStyle.width, isNull);
    expect(editor.selected!.size, StrokeSize.large);
  });

  testWidgets('clicking an arrow shows a colour bar above it; a bubble recolours the arrow, the second row sets its heads', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(onCanvas(tester, 0.3, 0.6), const Offset(150, -100));
    await tester.pump();
    final bar = find.byKey(const ValueKey('snaplite-colorbar'));
    expect(bar, findsOneWidget, reason: 'shown for the selected arrow');
    expect(tester.getBottomLeft(bar).dy, lessThan(tester.getCenter(find.byKey(const ValueKey('snaplite-thickness'))).dy),
        reason: 'above the arrow');

    await tester.tap(find.descendant(of: bar, matching: find.byTooltip('Blue')));
    await tester.pump();
    expect(editor.selected!.color.toARGB32(), const Color(0xFF007AFF).toARGB32());
    expect(bar, findsOneWidget, reason: 'stays up for another pick');

    // Arrowheads in the same bar
    await tester.tap(find.byKey(const ValueKey('snaplite-bar-end')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ArrowHead.dot.label).last);
    await tester.pumpAndSettle();
    expect(editor.selected!.arrowStyle.end, ArrowHead.dot);
    await tester.tap(find.descendant(of: bar, matching: find.byTooltip('Swap Ends')));
    await tester.pump();
    expect(editor.selected!.arrowStyle.start, ArrowHead.dot);

    // Head size lives in the same menu, under the heads
    await tester.tap(find.byKey(const ValueKey('snaplite-bar-end')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${HeadSize.large.label} head').last);
    await tester.pumpAndSettle();
    expect(editor.selected!.arrowStyle.headSize, HeadSize.large);

    // Marching is a checkbox beside the pattern, once the line has gaps
    expect(find.byKey(const ValueKey('snaplite-bar-marching')), findsNothing, reason: 'solid line');
    editor.setArrowStyle(editor.selected!.arrowStyle.copyWith(pattern: LinePattern.dotted));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('snaplite-bar-marching')));
    await tester.pump();
    expect(editor.selected!.arrowStyle.pattern, LinePattern.antsDotted);
  });

  testWidgets('Fourier drawing: circles follow the curve live while drawing; Play replays it', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Arrow').first);
    await tester.pump();
    editor.setFollowDrag(true);
    editor.setGifEntrance(Entrance.fourier);
    addTearDown(() => BuildUpGif.entrance = Entrance.draw);
    await tester.pump();
    expect(find.text('Fourier'), findsOneWidget, reason: 'the Entrance choice is in the panel');
    dynamic preview() => tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((c) => c.painter).firstWhere((p) => p.runtimeType.toString() == '_PreviewPainter');
    CanvasPainter painter() => preview().base as CanvasPainter;

    final start = onCanvas(tester, 0.2, 0.6);
    final g = await tester.startGesture(start);
    for (var i = 1; i <= 30; i++) {
      final t = i / 30;
      await g.moveTo(start + Offset(400 * t, -200 * (1 - (2 * t - 1) * (2 * t - 1))));
      await tester.pump();
      if (i == 15) {
        expect(preview().fourier, isTrue, reason: 'the circles trace it while dragging');
        expect(preview().follow, isNotNull, reason: 'a curve is being drawn');
      }
    }
    await g.up();
    await tester.pump();
    expect(painter().progress, isNull, reason: 'already drawn live: no replay on release');
    final curve = editor.selected!;
    expect(curve.curve!.length, 13, reason: 'kept as the Fourier curve: a dozen stretches with its own tangents');
    final top = curve.curve!.map((p) => p.dy).reduce(math.min);
    expect(curve.curve!.first.dy - top, greaterThan(100), reason: 'a curve, rising with the drag');

    // A straight drag stays exactly straight
    await tester.tap(find.text('Arrow').first);
    await tester.pump();
    final s2 = onCanvas(tester, 0.2, 0.85);
    final g2 = await tester.startGesture(s2);
    for (var i = 1; i <= 12; i++) { await g2.moveTo(s2 + Offset(30.0 * i, 0)); await tester.pump(); }
    await g2.up();
    await tester.pump();
    final straight = editor.selected!.curve!;
    for (final p in straight) {
      expect((p.dy - straight.first.dy).abs(), lessThan(0.5), reason: 'no wobble on a straight line');
    }

    expect(find.text('Play'), findsOneWidget);
    await tester.tap(find.text('Play'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500))); // the timer reads the real clock
    await tester.pump(const Duration(milliseconds: 20));
    expect(painter().epicycles, isTrue, reason: 'Play draws it again');
    expect(painter().progress![editor.selected!.id], inExclusiveRange(0, 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(painter().progress, isNull, reason: 'done: the curve stays, the circles go');
  });

  testWidgets('Curve: a new arrow follows the dragged path; off, it goes straight', (tester) async {
    final editor = await pumpEditor(tester);
    await tester.tap(find.text('Arrow').first);
    await tester.pump();
    editor.setFollowDrag(true);
    await tester.pump();
    expect(find.text('Curve: follow my drag'), findsOneWidget, reason: 'the option is in the panel');

    // An arc: right and up, then right and down
    final start = onCanvas(tester, 0.2, 0.6);
    final g = await tester.startGesture(start);
    for (var i = 1; i <= 30; i++) {
      final t = i / 30;
      await g.moveTo(start + Offset(400 * t, -200 * (1 - (2 * t - 1) * (2 * t - 1))));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    final arc = editor.selected!;
    final pts = arc.curve!;
    expect(pts.length, lessThanOrEqualTo(6), reason: 'a smooth fit with at most 4 bends');
    expect(arc.curveTangents.every((t) => t != null), isTrue, reason: 'the fit sets every tangent');
    final samples = CanvasPainter.curveSamples(pts, tangents: arc.curveTangents);
    final top = samples.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
    expect(pts.first.dy - top, greaterThan(100), reason: 'the curve rises with the drag (image coords)');

    // A straight drag stays straight even with Curve on
    await tester.tap(find.text('Arrow').first);
    await tester.pump();
    final s2 = onCanvas(tester, 0.2, 0.8);
    final g2 = await tester.startGesture(s2);
    for (var i = 1; i <= 10; i++) { await g2.moveTo(s2 + Offset(30.0 * i, 0)); await tester.pump(); }
    await g2.up();
    await tester.pump();
    expect(editor.selected!.curve!.length, 2);

    // Off: an arc drag makes a straight arrow
    editor.setFollowDrag(false);
    await tester.tap(find.text('Arrow').first);
    await tester.pump();
    final s3 = onCanvas(tester, 0.7, 0.4); // clear of the arrows above
    final g3 = await tester.startGesture(s3);
    for (var i = 1; i <= 10; i++) { await g3.moveTo(s3 + Offset(20.0 * i, -60.0 * (i < 5 ? i : 10 - i))); await tester.pump(); }
    await g3.up();
    await tester.pump();
    expect(editor.selected!.curve!.length, 2);
  });

  testWidgets('after bending an arrow, the thickness slider is back (and on clicking it again)', (tester) async {
    final editor = await pumpEditor(tester);
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    final scale = editor.viewScale; // the editor fits the picture into the space its floating chrome leaves free
    final origin = area.topLeft + editor.viewOrigin;
    Offset screen(Offset img) => origin + img * scale;
    final slider = find.byKey(const ValueKey('snaplite-thickness'));

    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(screen(const Offset(300, 500)), const Offset(300, -150));
    await tester.pump();
    final plus = CanvasPainter.addHandles(editor.selected!.curve!).single;
    await tester.dragFrom(screen(plus), const Offset(0, 80)); // bend it
    await tester.pump();
    expect(editor.selected!.curve!.length, 3);
    expect(slider, findsOneWidget, reason: 'back right after the drag');

    // Click away (deselect), then click on the arrow's curve
    await tester.tap(find.text('Select'));
    await tester.pump();
    await tester.tapAt(screen(const Offset(1100, 100)));
    await tester.pump();
    expect(slider, findsNothing);
    final samples = CanvasPainter.curveSamples(editor.state!.annotations.last.curve!);
    await tester.tapAt(screen(samples[samples.length ~/ 6]));
    await tester.pump();
    expect(editor.selected, isNotNull);
    expect(slider, findsOneWidget, reason: 'clicking the bent arrow shows the slider');
  });
}
