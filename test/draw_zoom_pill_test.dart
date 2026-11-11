import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Draw mode (overlay) has no zoom pill (Fit, minus, plus) and cannot be zoomed; the normal editor keeps both.
void main() {
  Future<GlobalKey<EditorPageState>> pump(WidgetTester tester, {required bool overlay}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async => null);
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
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key, overlay: overlay)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    return key;
  }

  testWidgets('the normal editor shows the zoom pill and zooms', (tester) async {
    final key = await pump(tester, overlay: false);
    expect(find.byKey(const ValueKey('snaplite-zoom')), findsOneWidget);
    final before = key.currentState!.viewScale;
    key.currentState!.zoomIn();
    await tester.pump();
    expect(key.currentState!.viewScale, greaterThan(before));
  });

  testWidgets('draw mode has no zoom pill and stays 1:1', (tester) async {
    final key = await pump(tester, overlay: true);
    expect(find.byKey(const ValueKey('snaplite-zoom')), findsNothing, reason: 'no Fit / minus / plus on the glass');
    expect(find.text('Fit'), findsNothing);
    final before = key.currentState!.viewScale;
    key.currentState!.zoomIn();
    key.currentState!.zoomOut();
    key.currentState!.zoomActualSize();
    await tester.pump();
    expect(key.currentState!.viewScale, before, reason: 'zoom commands do nothing in draw mode');
  });
}
