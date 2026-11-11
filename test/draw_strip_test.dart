import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Draw mode's tool strip has two states, driven only by the 6-dot grip: expanded (the full strip) and deflated (just
/// the dots in a small glass pill, exactly where they were), saved as draw.toolbar. A double-click on the dots toggles;
/// dragging them still docks the strip.
void main() {
  const grip = ValueKey('snaplite-strip-grip'), pill = ValueKey('snaplite-strip-pill');

  Future<List<String>> pump(WidgetTester tester, {required bool overlay, String? saved, bool left = false}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final stored = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'getString' && args!['key'] == 'draw.toolbar') return saved;
      if (call.method == 'setString' && args!['key'] == 'draw.toolbar') stored.add(args['value'] as String);
      return null;
    });
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    EditorPageState.toolbarLeft.value = left;
    addTearDown(() => EditorPageState.toolbarLeft.value = false);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(overlay: overlay)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    return stored;
  }

  /// The real gesture path: two taps on the dots within kDoubleTapTimeout, in the full draw-mode scaffold.
  Future<void> doubleClickGrip(WidgetTester tester) async {
    final at = tester.getCenter(find.byKey(grip));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(at);
    await tester.pump();
  }

  // Tools that can be seen and clicked (the deflated strip keeps the full one laid out, invisible, so the dots stay put)
  Finder tool(String label) => find.text(label).hitTestable();

  for (final left in [false, true]) {
    final dockName = left ? 'left dock' : 'top dock';
    testWidgets('$dockName: a double-click on the dots deflates the strip to them and back; the dots stay put', (tester) async {
      final stored = await pump(tester, overlay: true, left: left);
      expect(tool('Arrow'), findsOneWidget, reason: 'expanded: the full strip (first run)');
      expect(tool('Undo'), findsOneWidget);
      expect(tool('Inspector'), findsOneWidget);
      expect(find.byIcon(Icons.unfold_less), findsNothing, reason: 'no chevron');
      expect(find.byIcon(Icons.close), findsNothing, reason: 'no close button');
      final dots = tester.getCenter(find.byKey(grip));

      await doubleClickGrip(tester);
      expect(find.byKey(pill), findsOneWidget, reason: 'deflated: the dots in their pill');
      expect(tool('Arrow'), findsNothing, reason: 'deflated: no tool buttons');
      expect(tool('Undo'), findsNothing);
      expect(tool('Inspector'), findsNothing, reason: 'the Inspector button goes with the rest');
      expect(tester.getCenter(find.byKey(grip)), offsetMoreOrLessEquals(dots, epsilon: 0.01), reason: 'the dots did not move');
      final pillSize = tester.getSize(find.byKey(pill));
      expect(pillSize.width, lessThan(40));
      expect(pillSize.height, lessThan(40));
      expect(stored.last, 'deflated');

      await tester.pump(const Duration(seconds: 1)); // a fresh double-click
      await doubleClickGrip(tester);
      expect(find.byKey(pill), findsNothing);
      expect(tool('Arrow'), findsOneWidget, reason: 'expanded again');
      expect(tester.getCenter(find.byKey(grip)), offsetMoreOrLessEquals(dots, epsilon: 0.01), reason: 'still the same place');
      expect(stored.last, 'expanded');
    });
  }

  testWidgets('one click on the dots changes nothing', (tester) async {
    await pump(tester, overlay: true);
    await tester.tapAt(tester.getCenter(find.byKey(grip)));
    await tester.pump(const Duration(seconds: 1));
    expect(tool('Arrow'), findsOneWidget);
  });

  testWidgets('dragging the dots still docks the strip, deflated or not, and is never taken for a double-click', (tester) async {
    final stored = await pump(tester, overlay: true, saved: 'deflated');
    expect(EditorPageState.toolbarLeft.value, isFalse);
    final g = await tester.startGesture(tester.getCenter(find.byKey(grip)));
    await g.moveBy(const Offset(3, 3)); // within the slop: no drag yet
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await g.moveTo(Offset(40, 300 + i * 20.0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(EditorPageState.toolbarLeft.value, isTrue, reason: 'dropped at the left edge: docked there');
    expect(find.byKey(pill), findsOneWidget, reason: 'a drag never toggles the strip');
    expect(stored, isEmpty);
  });

  testWidgets('a saved deflated strip opens deflated; old collapsed and closed values read as deflated', (tester) async {
    for (final saved in ['deflated', 'collapsed', 'closed']) {
      await pump(tester, overlay: true, saved: saved);
      expect(find.byKey(pill), findsOneWidget, reason: saved);
      expect(tool('Arrow'), findsNothing, reason: saved);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the normal editor toolbar is unchanged', (tester) async {
    await pump(tester, overlay: false, saved: 'deflated');
    expect(find.byKey(grip), findsNothing);
    expect(find.byKey(pill), findsNothing);
    expect(tool('Arrow'), findsOneWidget);
    expect(tool('Undo'), findsOneWidget);
  });
}
