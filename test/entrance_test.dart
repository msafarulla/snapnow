import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The Bézier entrance for the build-up GIF: an arrow appears by its de Casteljau construction.
void main() {
  final arrow = Annotation(id: 1, color: Colors.red, size: StrokeSize.large,
      shape: const ArrowShape(Offset(40, 160), Offset(340, 60), points: [Offset(120, 40), Offset(240, 180)]));

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

  test('Bézier: scaffolding shows while the curve builds, and is gone once it is complete', () async {
    final plain = await paint((c) => CanvasPainter.drawPartial(c, arrow, 0.5));
    final built = await paint((c) => CanvasPainter.drawPartial(c, arrow, 0.5, bezier: true));
    expect(differing(plain, built), greaterThan(300), reason: 'the control polygon and sliding points are drawn');
    final early = await paint((c) => CanvasPainter.drawPartial(c, arrow, 0.2, bezier: true));
    final late = await paint((c) => CanvasPainter.drawPartial(c, arrow, 0.7, bezier: true));
    expect(inked(late), greaterThan(inked(early)), reason: 'more of the curve is there later');
    final done = await paint((c) => CanvasPainter.drawPartial(c, arrow, 1));
    final doneBezier = await paint((c) => CanvasPainter.drawPartial(c, arrow, 1, bezier: true));
    expect(differing(done, doneBezier), 0, reason: 'the finished arrow is the plain arrow, heads and all');
  });

  test('settings: the Entrance choice, the old Fourier flag, and the Bézier timing', () {
    addTearDown(() => BuildUpGif.entrance = Entrance.draw);
    BuildUpGif.entrance = Entrance.bezier;
    expect(BuildUpGif.fourier, isFalse);
    expect(BuildUpGif.bezier, isTrue);
    expect(BuildUpGif.appearing(arrow), BuildUpGif.bezierDraw, reason: 'slower, so the construction can be followed');
    BuildUpGif.fourier = true;
    expect(BuildUpGif.entrance, Entrance.fourier);
    BuildUpGif.fourier = false;
    expect(BuildUpGif.entrance, Entrance.draw, reason: 'turning Fourier off goes back to the plain draw-on');
    expect(BuildUpGif.appearing(arrow), BuildUpGif.lineDraw);
  });
}
