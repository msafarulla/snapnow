import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';

/// Closing draw mode (finishDraw) saves the session capture quietly: no "Saved" toast. A normal save still says it.
void main() {
  testWidgets('finishDraw saves without a toast; save() still shows "Saved"', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final toasts = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('snaplite/native'), (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'toast') toasts.add(args!['message'] as String);
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
    final dir = Directory.systemTemp.createTempSync('snaplite_draw_close');
    addTearDown(() => dir.deleteSync(recursive: true));

    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    await tester.tap(find.text('Arrow'));
    await tester.pump();
    await tester.dragFrom(area.topLeft + const Offset(300, 300), const Offset(250, -150));
    await tester.pump();

    // the screen behind the glass, as LiveDraw.leave writes it
    final shot = '${dir.path}/SnapNow Session test.png';
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 64, 40), Paint()..color = const Color(0xFF3366CC));
      final img = await rec.endRecording().toImage(64, 40);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      await File(shot).writeAsBytes(png!.buffer.asUint8List(), flush: true);
    });
    final before = File(shot).lengthSync();

    final kept = await tester.runAsync(() => key.currentState!.finishDraw(shot));
    await tester.pump();
    expect(kept, isTrue, reason: 'a session with markup is kept');
    expect(File(shot).lengthSync(), isNot(before), reason: 'saved over the screen shot: picture + markup');
    expect(toasts.where((t) => t.startsWith('Saved')), isEmpty, reason: 'closing draw mode shows no notice');

    await tester.runAsync(() => key.currentState!.save());
    expect(toasts.last, 'Saved', reason: 'a normal save keeps its toast');
  });
}
