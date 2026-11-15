import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/app/app_controller.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Draw mode (the glass): Esc lifts it, as ⌘W and a double-tap of Option do. A callout being typed takes the Esc first
/// (the typing is cancelled, the glass stays), and so does a crop frame; only the next Esc lifts the glass.
void main() {
  final shell = <String>[];
  setUp(() {
    shell.clear();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      if (call.method == 'shell') shell.add((call.arguments as Map)['action'] as String);
      return null;
    });
    AppController.instance.drawing = true;
  });
  tearDown(() => AppController.instance.drawing = false);

  Future<EditorPageState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      // Esc bound window-wide the way the Library binds it
      await tester.pumpWidget(MaterialApp(
          home: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): AppController.instance.saveAndClose},
              child: EditorPage(key: key, overlay: true))));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    return key.currentState!;
  }

  Offset at(WidgetTester tester, double fx, double fy) {
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    return Offset(area.left + area.width * fx, area.top + area.height * fy);
  }

  final inlineField = find.byKey(const ValueKey('snaplite-inline-text'));

  testWidgets('Esc on the glass lifts it, also with something drawn', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Arrow').hitTestable());
    await tester.pump();
    await tester.dragFrom(at(tester, 0.3, 0.6), const Offset(200, -120));
    await tester.pump();
    expect(shell, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(shell, ['endDraw'], reason: 'the same exit as ⌘W');
  });

  testWidgets('Esc while typing cancels only the typing; the next Esc lifts the glass', (tester) async {
    final editor = await pump(tester);
    await tester.tap(find.text('Callout').hitTestable());
    await tester.pump();
    await tester.dragFrom(at(tester, 0.3, 0.3), const Offset(150, 100));
    await tester.pump();
    expect(inlineField, findsOneWidget);
    await tester.enterText(inlineField, 'nope');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(inlineField, findsNothing, reason: 'the typing is cancelled');
    expect(editor.hasUnsavedChanges, isFalse, reason: 'the cancelled callout is gone');
    expect(shell, isEmpty, reason: 'the glass stays');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(shell, ['endDraw']);
  });

  testWidgets('Esc with a crop frame takes the frame away first', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC); // the Crop tool: its frame covers the picture
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(shell, isEmpty, reason: 'the first Esc only cancels the crop frame');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(shell, ['endDraw']);
  });
}
