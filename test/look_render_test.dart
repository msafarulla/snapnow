import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/app/theme.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Renders the editor in each theme to PNGs for eyeballing the look (set SNAPNOW_LOOK_DIR to a folder).
/// Loads a real system font so text is readable instead of Ahem boxes. Skipped without the variable.
void main() {
  renderMarkers();
  final outDir = Platform.environment['SNAPNOW_LOOK_DIR'];

  testWidgets('render the editor look', (tester) async {
    if (outDir == null) return;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    // A real font (the Mac's Helvetica) stands in for the system font
    await tester.runAsync(() async {
      final data = File('/System/Library/Fonts/Helvetica.ttc').readAsBytesSync();
      final loader = FontLoader('Roboto')..addFont(Future.value(ByteData.view(data.buffer)));
      await loader.load();
      final fira = File('${Platform.environment['HOME']}/Library/Fonts/FiraMonoNerdFontMono-Regular.otf');
      if (fira.existsSync()) {
        final mono = FontLoader('FiraMono Nerd Font Mono')..addFont(Future.value(ByteData.view(fira.readAsBytesSync().buffer)));
        await mono.load();
      }
    });
    tester.view.physicalSize = const Size(1240, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) { if (!d.exceptionAsString().contains('overflowed')) original?.call(d); };
    addTearDown(() => FlutterError.onError = original);

    for (final (name, theme) in [('light', SnapTheme.light), ('dark', SnapTheme.dark), ('tokyo', SnapTheme.tokyoNight)]) {
      final key = GlobalKey<EditorPageState>();
      final boundary = GlobalKey();
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: RepaintBoundary(key: boundary, child: EditorPage(key: key, chromeInsets: const EdgeInsets.only(bottom: 112))),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pump();
      // Draw an arrow and a box, select the arrow so the colour bar / thickness slider show
      final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
      await tester.tap(find.text('Arrow'));
      await tester.pump();
      await tester.dragFrom(area.topLeft + const Offset(420, 420), const Offset(220, -140));
      await tester.pump();
      await tester.tap(find.text('Shape'));
      await tester.pump();
      await tester.dragFrom(area.topLeft + const Offset(300, 220), const Offset(260, 150));
      await tester.pump();
      await tester.tap(find.text('Select'));
      await tester.pump();
      await tester.tapAt(area.topLeft + const Offset(530, 350));
      await tester.pump(const Duration(milliseconds: 300));
      expect(key.currentState!.state!.annotations.length, 2);

      await tester.runAsync(() async {
        final ro = boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await ro.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$outDir/editor-$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}

/// All six step markers side by side, for eyeballing (same SNAPNOW_LOOK_DIR).
void renderMarkers() {
  final outDir = Platform.environment['SNAPNOW_LOOK_DIR'];
  test('render the step markers', () async {
    if (outDir == null) return;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 480, 140), Paint()..color = Colors.white);
    for (final (i, m) in StepMarker.values.indexed) {
      final a = Annotation(id: i + 1, shape: StepShape(Offset(40 + i * 72.0, 50), style: m), color: const Color(0xFFE8332A), size: StrokeSize.large);
      CanvasPainter.drawAnnotation(canvas, a, number: i + 1);
      final b = CanvasPainter.stepBounds(Offset(40 + i * 72.0, 50), a.stepDiameter, m);
      canvas.drawRect(b, Paint()..style = PaintingStyle.stroke..color = Colors.blue.withValues(alpha: 0.5));
    }
    final img = await rec.endRecording().toImage(480, 140);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$outDir/markers.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
