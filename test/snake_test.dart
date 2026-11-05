import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The Snake skin effect: an arrow as a dark glass tube with glowing scales that drift along it.
void main() {
  const snakeStyle = ArrowStyle(end: ArrowHead.swept, snake: true);
  final plain = Annotation(id: 1, color: Colors.cyan, size: StrokeSize.large,
      shape: const ArrowShape(Offset(30, 170), Offset(370, 30)));
  final snake = plain.copyWith(arrowStyle: snakeStyle);

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

  test('a snake arrow looks nothing like the plain one, and its scales move with the phase', () async {
    final a = await paint((c) => CanvasPainter.drawAnnotation(c, plain));
    final b = await paint((c) => CanvasPainter.drawSnake(c, plain.curve!, snakeStyle, Colors.cyan, plain.lineWidth, phase: 0.2));
    expect(differing(a, b), greaterThan(3000));
    final later = await paint((c) => CanvasPainter.drawSnake(c, plain.curve!, snakeStyle, Colors.cyan, plain.lineWidth, phase: 0.45));
    expect(differing(b, later), greaterThan(500), reason: 'the scales are somewhere else');
    final wrapped = await paint((c) => CanvasPainter.drawSnake(c, plain.curve!, snakeStyle, Colors.cyan, plain.lineWidth, phase: 1.2));
    expect(differing(b, wrapped), 0, reason: 'phase 1.2 is phase 0.2: the loop is seamless');
  });

  test('drawAnnotation and drawPartial route a snake-styled arrow to the snake', () async {
    final a = await paint((c) => CanvasPainter.drawAnnotation(c, plain));
    final b = await paint((c) => CanvasPainter.drawAnnotation(c, snake));
    expect(differing(a, b), greaterThan(3000));
    final half = await paint((c) => CanvasPainter.drawPartial(c, snake, 0.5));
    final plainHalf = await paint((c) => CanvasPainter.drawPartial(c, plain, 0.5));
    expect(differing(half, plainHalf), greaterThan(1000));
  });

  test('the style saves, loads and copies', () {
    final json = snakeStyle.toJson();
    expect(json['snake'], isTrue);
    expect(ArrowStyle.arrow.toJson().containsKey('snake'), isFalse);
    expect(ArrowStyle.fromJson(json), snakeStyle);
    expect(ArrowStyle.fromJson(ArrowStyle.arrow.toJson())!.snake, isFalse);
    expect(snakeStyle.copyWith(snake: false), ArrowStyle.arrow);
    expect(snakeStyle.withWidth(3).snake, isTrue);
    expect(snakeStyle.withBorderColor(Colors.red).snake, isTrue);
  });

  test('a snake skin counts as animated, like marching ants', () async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = Colors.white);
    final base = await rec.endRecording().toImage(400, 200);
    expect(BuildUpGif.marches(CanvasState(image: base, annotations: [plain])), isFalse);
    expect(BuildUpGif.marches(CanvasState(image: base, annotations: [snake])), isTrue);
  });
}
