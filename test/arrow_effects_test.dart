import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/export/build_up_gif.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// The animated arrow effects: Neon, Colour flow, Electric, Fire trail, Pulse and Rope.
void main() {
  final effects = ArrowEffect.values.where((e) => e != ArrowEffect.none).toList();
  final plain = Annotation(id: 1, color: Colors.cyan, size: StrokeSize.large,
      arrowStyle: const ArrowStyle(end: ArrowHead.swept), shape: const ArrowShape(Offset(30, 170), Offset(370, 30)));

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

  Future<Uint32List> effect(ArrowEffect e, double phase) => paint((c) => CanvasPainter.drawEffect(
      c, plain.curve!, plain.arrowStyle.copyWith(effect: e), Colors.cyan, plain.lineWidth, phase: phase));

  for (final e in effects) {
    test('${e.label}: looks unlike the plain arrow, moves with the phase and loops seamlessly', () async {
      final still = await paint((c) => CanvasPainter.drawAnnotation(c, plain));
      final a = await effect(e, 0.2);
      expect(differing(still, a), greaterThan(1500));
      final later = await effect(e, 0.45);
      expect(differing(a, later), greaterThan(150), reason: 'it moves');
      final wrapped = await effect(e, 1.2);
      expect(differing(a, wrapped), 0, reason: 'phase 1.2 is phase 0.2: the loop is seamless');
      final again = await effect(e, 0.2);
      expect(differing(a, again), 0, reason: 'the same phase always draws the same frame');
    });
  }

  test('drawAnnotation and drawPartial route an arrow or line with an effect to it', () async {
    for (final e in effects) {
      final styled = plain.copyWith(arrowStyle: plain.arrowStyle.copyWith(effect: e));
      final a = await paint((c) => CanvasPainter.drawAnnotation(c, plain));
      final b = await paint((c) => CanvasPainter.drawAnnotation(c, styled));
      expect(differing(b, await effect(e, 0)), 0, reason: '${e.label}: a still picture is phase 0');
      expect(differing(a, b), greaterThan(1500));
      final half = await paint((c) => CanvasPainter.drawPartial(c, styled, 0.5));
      final plainHalf = await paint((c) => CanvasPainter.drawPartial(c, plain, 0.5));
      expect(differing(half, plainHalf), greaterThan(500), reason: e.label);
    }
    const line = Annotation(id: 2, color: Colors.orange, arrowStyle: ArrowStyle(end: ArrowHead.none, effect: ArrowEffect.rope),
        shape: LineShape(Offset(30, 100), Offset(370, 100)));
    final roped = await paint((c) => CanvasPainter.drawAnnotation(c, line));
    final bare = await paint((c) => CanvasPainter.drawAnnotation(c, line.copyWith(arrowStyle: ArrowStyle.line)));
    expect(differing(roped, bare), greaterThan(1000));
  });

  test('without an effect drawEffect is the plain arrow', () async {
    final a = await paint((c) => CanvasPainter.drawAnnotation(c, plain));
    final b = await paint((c) => CanvasPainter.drawEffect(c, plain.curve!, plain.arrowStyle, Colors.cyan, plain.lineWidth, phase: 0.3));
    expect(differing(a, b), 0);
  });

  test('the effect saves by name, loads and copies', () {
    const style = ArrowStyle(end: ArrowHead.swept, effect: ArrowEffect.fire);
    final json = style.toJson();
    expect(json['effect'], 'fire');
    expect(ArrowStyle.fromJson(json), style);
    expect(ArrowStyle.arrow.toJson().containsKey('effect'), isFalse);
    expect(ArrowStyle.fromJson(ArrowStyle.arrow.toJson())!.effect, ArrowEffect.none);
    expect(ArrowStyle.fromJson({...json, 'effect': 'sparkle'})!.effect, ArrowEffect.none, reason: 'unknown = none');
    for (final e in ArrowEffect.values) {
      expect(ArrowStyle.fromJson(ArrowStyle(effect: e).toJson())!.effect, e);
    }
    expect(style.copyWith(tapered: true).effect, ArrowEffect.fire);
    expect(style.copyWith(effect: ArrowEffect.none), ArrowStyle.arrow);
    expect(style.withWidth(3).effect, ArrowEffect.fire);
    expect(style.withBorderColor(Colors.red).effect, ArrowEffect.fire);
    expect(style == style.copyWith(effect: ArrowEffect.neon), isFalse);
    expect(ArrowEffect.values.map((e) => e.label), ['None', 'Neon', 'Colour flow', 'Electric', 'Fire trail', 'Pulse', 'Rope']);
  });

  test('Snake skin and an effect exclude each other', () {
    const snake = ArrowStyle(end: ArrowHead.swept, snake: true);
    final neon = snake.copyWith(effect: ArrowEffect.neon);
    expect(neon.snake, isFalse);
    expect(neon.effect, ArrowEffect.neon);
    final back = neon.copyWith(snake: true);
    expect(back.snake, isTrue);
    expect(back.effect, ArrowEffect.none);
    expect(snake.copyWith(effect: ArrowEffect.none).snake, isTrue, reason: 'choosing None leaves the snake alone');
    expect(ArrowStyle.fromJson({...neon.toJson(), 'snake': true})!.effect, ArrowEffect.none);
  });

  test('an effect counts as animated, like marching ants', () async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = Colors.white);
    final base = await rec.endRecording().toImage(400, 200);
    expect(BuildUpGif.marches(CanvasState(image: base, annotations: [plain])), isFalse);
    for (final e in effects) {
      final styled = plain.copyWith(arrowStyle: plain.arrowStyle.copyWith(effect: e));
      expect(BuildUpGif.marches(CanvasState(image: base, annotations: [styled])), isTrue);
    }
  });
}
