import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Opening another picture (the Library's filmstrip: click a tile, or ✕ the one being edited) must not carry
/// anything mid-way on the old one onto the new one: text being typed, a pending crop frame, a ⌘A group.
void main() {
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  final inlineField = find.byKey(const ValueKey('snaplite-inline-text'));

  Future<String> capture(Color color) async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 400, 240), Paint()..color = color);
    final png = (await (await rec.endRecording().toImage(400, 240)).toByteData(format: ui.ImageByteFormat.png))!;
    final file = File('${Directory.systemTemp.createTempSync().path}/capture.png')..writeAsBytesSync(png.buffer.asUint8List());
    return file.path;
  }

  Future<(EditorPageState, String, String)> pumpTwo(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    final key = GlobalKey<EditorPageState>();
    late String a, b;
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      a = await capture(Colors.white);
      b = await capture(Colors.black);
      await key.currentState!.openFile(a);
    });
    await tester.pump();
    return (key.currentState!, a, b);
  }

  /// A point on the (centred, 400×240) picture, offset from its middle.
  Offset onPicture(WidgetTester tester, double dx, double dy) =>
      tester.getRect(find.byKey(const ValueKey('snaplite-canvas'))).center + Offset(dx, dy);

  testWidgets('a callout being typed does not land on the next picture', (tester) async {
    final (editor, _, b) = await pumpTwo(tester);
    await tester.tap(find.text('Callout'));
    await tester.pump();
    await tester.dragFrom(onPicture(tester, -120, -60), const Offset(100, 60));
    await tester.pump();
    expect(inlineField, findsOneWidget);
    await tester.enterText(inlineField, 'Not for the next one');
    await tester.pump();
    expect(editor.debugInteracting, isTrue);

    await tester.runAsync(() => editor.openFile(b));
    await tester.pump();
    expect(inlineField, findsNothing, reason: 'the text box closed with the old picture');
    expect(editor.state!.annotations, isEmpty, reason: 'nothing typed carried over');
    expect(editor.debugInteracting, isFalse);
    expect(editor.hasUnsavedChanges, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a pending crop frame does not land on the next picture', (tester) async {
    final (editor, _, b) = await pumpTwo(tester);
    await tester.tap(find.text('Crop'));
    await tester.pump();
    await tester.dragFrom(onPicture(tester, -120, -60), const Offset(160, 90));
    await tester.pump();
    expect(editor.debugInteracting, isTrue, reason: 'a crop frame is pending');

    await tester.runAsync(() => editor.openFile(b));
    await tester.pump();
    expect(editor.debugInteracting, isFalse, reason: 'the frame went with the old picture');
    expect(editor.state!.image.width, 400, reason: 'and nothing got cropped');
    await tester.pumpWidget(const SizedBox());
  });
}
