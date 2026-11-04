import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Entrance effects for the build-up GIF: Comet (a glowing head leads the line) and Spring head (the tip
/// overshoots and settles), beside the plain draw-on and Fourier circles.
void main() {
  final arrow = Annotation(id: 1, shape: ArrowShape(const Offset(40, 100), const Offset(300, 100)), color: Colors.red, size: StrokeSize.large);

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

  /// The right-most column with ink (not white) in the picture.
  int inkRight(Uint32List px) {
    for (var x = 399; x >= 0; x--) {
      for (var y = 0; y < 200; y++) {
        if (px[y * 400 + x] != 0xFFFFFFFF) return x;
      }
    }
    return -1;
  }

  test('Comet: a glow leads the line while it draws on, and is gone once it is complete', () async {
    final plain = await paint((c) => CanvasPainter.drawPartial(c, arrow, 0.5));
    final comet = await paint((c) => CanvasPainter.drawPartial(c, arrow, 0.5, comet: true));
    expect(differing(plain, comet), greaterThan(200), reason: 'the comet head and tail add ink around the tip');
    final done = await paint((c) => CanvasPainter.drawPartial(c, arrow, 1));
    final doneComet = await paint((c) => CanvasPainter.drawPartial(c, arrow, 1, comet: true));
    expect(differing(done, doneComet), 0, reason: 'nothing of the comet is left on the finished arrow');
  });

  test('Spring head: the tip overshoots past where it was drawn, then settles back exactly', () async {
    final finished = await paint((c) => CanvasPainter.drawPartial(c, arrow, 1));
    final overshoot = await paint((c) => CanvasPainter.drawPartial(c, arrow, 0.79, spring: true));
    expect(inkRight(overshoot), greaterThan(inkRight(finished)), reason: 'at the start of the settle the tip is past its mark');
    expect(CanvasPainter.sprung(arrow, 1), arrow.curve, reason: 'at rest it is the arrow as drawn');
    final midway = await paint((c) => CanvasPainter.drawPartial(c, arrow, 0.4, spring: true));
    expect(inkRight(midway), lessThan(inkRight(finished)), reason: 'still drawing on during the first three quarters');
  });

  test('settings: the Entrance choice, the old Fourier flag, and the sprung arrow timing', () {
    addTearDown(() { BuildUpGif.entrance = Entrance.draw; BuildUpGif.spring = false; });
    BuildUpGif.entrance = Entrance.comet;
    expect(BuildUpGif.fourier, isFalse);
    BuildUpGif.fourier = true;
    expect(BuildUpGif.entrance, Entrance.fourier);
    BuildUpGif.fourier = false;
    expect(BuildUpGif.entrance, Entrance.draw, reason: 'turning Fourier off goes back to the plain draw-on');
    expect(BuildUpGif.appearing(arrow), BuildUpGif.lineDraw);
    BuildUpGif.spring = true;
    expect(BuildUpGif.appearing(arrow), BuildUpGif.springDraw, reason: 'a little longer so the settle shows');
  });
}
