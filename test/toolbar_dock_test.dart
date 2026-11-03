import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// The toolbar docks at the top or down the left edge: drag its grip near the left edge and it stands there
/// (pref toolbar.left saved); drag it back up and it lies across the top again. A drop in the middle changes nothing.
void main() {
  testWidgets('dragging the toolbar grip to the left edge docks the toolbar there, and back', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final saved = <bool>[];
    for (final ch in ['window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      if (call.method == 'setBool' && call.arguments['key'] == 'toolbar.left') saved.add(call.arguments['value'] as bool);
      return null;
    });
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) { if (!d.exceptionAsString().contains('overflowed')) original?.call(d); };
    addTearDown(() => FlutterError.onError = original);
    EditorPageState.toolbarLeft.value = false;
    addTearDown(() => EditorPageState.toolbarLeft.value = false);

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final grip = find.byTooltip('Drag to the top or the left edge');
    expect(grip, findsOneWidget);
    final atTop = tester.getCenter(grip);
    expect(atTop.dy, lessThan(60)); // across the top
    final share = tester.getCenter(find.text('Share'));

    // Drop in the middle of the window: nothing changes
    await tester.timedDrag(grip, Offset(700 - atTop.dx, 500 - atTop.dy), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(EditorPageState.toolbarLeft.value, isFalse);
    expect(saved, isEmpty);

    // Near the left edge: the toolbar stands down the left
    await tester.timedDrag(grip, Offset(30 - atTop.dx, 500 - atTop.dy), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(EditorPageState.toolbarLeft.value, isTrue);
    expect(saved, [true]);
    final atLeft = tester.getCenter(find.byTooltip('Drag to the top or the left edge'));
    expect(atLeft.dx, lessThan(60));
    expect(tester.getCenter(find.text('Share')).dx, lessThan(60)); // the buttons moved with it
    expect(tester.getCenter(find.text('Share')).dy, greaterThan(share.dy + 100));

    // Back near the top
    await tester.timedDrag(find.byTooltip('Drag to the top or the left edge'), Offset(600 - atLeft.dx, 30 - atLeft.dy),
        const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(EditorPageState.toolbarLeft.value, isFalse);
    expect(saved, [true, false]);
    expect(tester.getCenter(find.text('Share')).dy, lessThan(60));
  });
}
