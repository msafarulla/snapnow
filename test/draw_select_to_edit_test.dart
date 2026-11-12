import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Draw mode (the glass): a shape just drawn is not selected, so no colour bar or thickness slider pops up and the next
/// shape can be drawn at once; clicking a drawn shape selects it and shows them. The editor keeps selecting what was drawn.
void main() {
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  Future<EditorPageState> pump(WidgetTester tester, {required bool overlay}) async {
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
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key, overlay: overlay)));
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

  testWidgets('on the glass a new shape is not selected; a click on it selects it and shows its bars', (tester) async {
    final editor = await pump(tester, overlay: true);
    await tester.tap(find.text('Arrow').hitTestable());
    await tester.pump();
    final from = at(tester, 0.3, 0.6), to = at(tester, 0.45, 0.45);
    await tester.dragFrom(from, to - from);
    await tester.pump();
    expect(editor.selected, isNull, reason: 'a new arrow on the glass is not selected');
    expect(colorBar, findsNothing, reason: 'no colour bar after drawing');
    expect(thickness, findsNothing, reason: 'no thickness slider after drawing');

    // The next arrow straight away, elsewhere: still nothing pops up
    final from2 = at(tester, 0.6, 0.6);
    await tester.dragFrom(from2, at(tester, 0.75, 0.7) - from2);
    await tester.pump();
    expect(editor.selected, isNull);
    expect(colorBar, findsNothing);

    // A click on the first arrow selects it: its bars appear
    await tester.tapAt(Offset.lerp(from, to, 0.5)!);
    await tester.pump();
    expect(editor.selected, isNotNull, reason: 'a click on a drawn shape selects it');
    expect(colorBar, findsOneWidget, reason: 'its colour bar shows');
    expect(thickness, findsOneWidget, reason: 'its thickness slider shows');

    // A click on empty glass lets it go again
    await tester.tapAt(at(tester, 0.85, 0.2));
    await tester.pump();
    expect(editor.selected, isNull);
    expect(colorBar, findsNothing);
  });

  testWidgets('in the editor a new shape is still selected with its bars', (tester) async {
    final editor = await pump(tester, overlay: false);
    await tester.tap(find.text('Arrow').hitTestable());
    await tester.pump();
    final from = at(tester, 0.3, 0.6);
    await tester.dragFrom(from, at(tester, 0.45, 0.45) - from);
    await tester.pump();
    expect(editor.selected, isNotNull);
    expect(colorBar, findsOneWidget);
    expect(thickness, findsOneWidget);
  });
}
