import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The Beam effect: an arrow as a light beam, with comets that run along it.
void main() {
  const beamStyle = ArrowStyle(end: ArrowHead.swept, beam: true);
  final plain = Annotation(id: 1, color: Colors.cyan, size: StrokeSize.large,
      shape: const ArrowShape(Offset(30, 170), Offset(370, 30)));
  final beam = plain.copyWith(arrowStyle: beamStyle);

  Future<Uint32List> paint(void Function(Canvas) draw) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = const Color(0xFF203040));
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

  test('a beam arrow looks nothing like the plain one, and its comets move with the phase', () async {
    final a = await paint((c) => CanvasPainter.drawAnnotation(c, plain));
    final b = await paint((c) => CanvasPainter.drawBeam(c, plain.curve!, beamStyle, Colors.cyan, plain.lineWidth, phase: 0.2));
    expect(differing(a, b), greaterThan(3000));
    final later = await paint((c) => CanvasPainter.drawBeam(c, plain.curve!, beamStyle, Colors.cyan, plain.lineWidth, phase: 0.45));
    expect(differing(b, later), greaterThan(500), reason: 'the comets and pellets are somewhere else');
    final wrapped = await paint((c) => CanvasPainter.drawBeam(c, plain.curve!, beamStyle, Colors.cyan, plain.lineWidth, phase: 1.2));
    expect(differing(b, wrapped), 0, reason: 'phase 1.2 is phase 0.2: the loop is seamless');
  });

  test('drawAnnotation and drawPartial route a beam-styled arrow to the beam', () async {
    final a = await paint((c) => CanvasPainter.drawAnnotation(c, plain));
    final b = await paint((c) => CanvasPainter.drawAnnotation(c, beam));
    expect(differing(a, b), greaterThan(3000));
    final half = await paint((c) => CanvasPainter.drawPartial(c, beam, 0.5));
    final plainHalf = await paint((c) => CanvasPainter.drawPartial(c, plain, 0.5));
    expect(differing(half, plainHalf), greaterThan(1000));
  });

  test('the style saves, loads and copies', () {
    final json = beamStyle.toJson();
    expect(json['beam'], isTrue);
    expect(ArrowStyle.arrow.toJson().containsKey('beam'), isFalse);
    expect(ArrowStyle.fromJson(json), beamStyle);
    expect(ArrowStyle.fromJson(ArrowStyle.arrow.toJson())!.beam, isFalse);
    expect(beamStyle.copyWith(beam: false), ArrowStyle.arrow);
    expect(beamStyle.withWidth(3).beam, isTrue);
    expect(beamStyle.withBorderColor(Colors.red).beam, isTrue);
  });

  test('a beam counts as animated, like marching ants', () async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = Colors.white);
    final base = await rec.endRecording().toImage(400, 200);
    expect(BuildUpGif.marches(CanvasState(image: base, annotations: [plain])), isFalse);
    expect(BuildUpGif.marches(CanvasState(image: base, annotations: [beam])), isTrue);
  });
}
