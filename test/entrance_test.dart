import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The String art entrance for the build-up GIF: a stroke appears as the envelope of its tangent lines.
void main() {
  final arrow = Annotation(id: 1, color: Colors.red, size: StrokeSize.large,
      shape: const ArrowShape(Offset(40, 160), Offset(340, 60), points: [Offset(120, 40), Offset(240, 180)]));
  final oval = Annotation(id: 2, color: Colors.blue, size: StrokeSize.medium, shape: const EllipseShape(Rect.fromLTWH(80, 40, 240, 120)));

  Future<Uint32List> paint(void Function(Canvas) draw) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = Colors.white);
    draw(canvas);
    final img = await rec.endRecording().toImage(400, 200);
    return (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint32List();
  }

  int differing(Uint32List a, Uint32List b) {
    var n = 0;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) n++;
    }
    return n;
  }

  int inked(Uint32List px) => px.where((p) => p != 0xFFFFFFFF).length;

  for (final (name, a) in [('arrow', arrow), ('ellipse', oval)]) {
    test('String art ($name): tangent lines show while it builds, and are gone once it is complete', () async {
      final plain = await paint((c) => CanvasPainter.drawPartial(c, a, 0.5));
      final strings = await paint((c) => CanvasPainter.drawPartial(c, a, 0.5, envelope: true));
      expect(differing(plain, strings), greaterThan(400), reason: 'the tangent lines reach well past the stroke');
      final early = await paint((c) => CanvasPainter.drawPartial(c, a, 0.2, envelope: true));
      final late = await paint((c) => CanvasPainter.drawPartial(c, a, 0.7, envelope: true));
      expect(inked(late), greaterThan(inked(early)), reason: 'more lines, and more of the stroke, later on');
      final done = await paint((c) => CanvasPainter.drawPartial(c, a, 1));
      final doneStrings = await paint((c) => CanvasPainter.drawPartial(c, a, 1, envelope: true));
      expect(differing(done, doneStrings), 0, reason: 'the finished shape is the plain one, heads and all');
    });
  }

  test('settings: the Entrance choice, the old Fourier flag, and the String art timing', () {
    addTearDown(() => BuildUpGif.entrance = Entrance.draw);
    BuildUpGif.entrance = Entrance.envelope;
    expect(BuildUpGif.fourier, isFalse);
    expect(BuildUpGif.envelope, isTrue);
    expect(BuildUpGif.appearing(arrow), BuildUpGif.envelopeDraw, reason: 'slower, so the lines can be seen going down');
    expect(BuildUpGif.appearing(oval), BuildUpGif.envelopeDraw);
    BuildUpGif.fourier = true;
    expect(BuildUpGif.entrance, Entrance.fourier);
    BuildUpGif.fourier = false;
    expect(BuildUpGif.entrance, Entrance.draw, reason: 'turning Fourier off goes back to the plain draw-on');
    expect(BuildUpGif.appearing(arrow), BuildUpGif.lineDraw);
  });

  test('String art while drawing: tangentFan paints the fan over the whole stroke', () async {
    final a = Annotation(id: 1, color: const Color(0xFFE53935), size: StrokeSize.large,
        shape: ArrowShape(const Offset(20, 180), const Offset(280, 30), points: const [Offset(120, 40)]));
    Future<int> inked(void Function(Canvas) draw) async {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(const Rect.fromLTWH(0, 0, 300, 200), Paint()..color = Colors.white);
      draw(c);
      final img = await rec.endRecording().toImage(300, 200);
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      var n = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (px[i] < 250 || px[i + 1] < 250 || px[i + 2] < 250) n++;
      }
      return n;
    }
    final plain = await inked((c) => CanvasPainter.drawAnnotation(c, a));
    final fanned = await inked((c) { CanvasPainter.drawAnnotation(c, a); CanvasPainter.tangentFan(c, a); });
    expect(fanned - plain, greaterThan(2000), reason: 'the fan covers far more than the stroke');
  });
}
