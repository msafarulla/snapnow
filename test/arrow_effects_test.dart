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

  // Along the straight test arrow's line, well clear of both heads: where a picture is clearly darker than the same
  // arrow drawn solid, i.e. where the pattern's gaps are (a glow may spill into a gap, so not "the bare background")
  int light(int rgba) => (rgba & 0xFF) + ((rgba >> 8) & 0xFF) + ((rgba >> 16) & 0xFF);
  List<bool> gaps(Uint32List px, Uint32List solid) => [
        for (var i = 0; i <= 200; i++)
          () {
            final f = 0.15 + 0.6 * i / 200;
            final at = (170 - 140 * f).round() * 400 + (30 + 340 * f).round();
            return light(px[at]) < light(solid[at]) - 90;
          }()
      ];
  int count(List<bool> g) => g.where((x) => x).length;

  Future<Uint32List> patterned(ArrowEffect e, LinePattern p, double phase) => paint((c) => CanvasPainter.drawEffect(
      c, plain.curve!, plain.arrowStyle.copyWith(effect: e, pattern: p), Colors.cyan, plain.lineWidth, phase: phase));

  for (final e in effects) {
    test('${e.label}: follows the line pattern - gaps in a dashed or dotted line, none in a solid one', () async {
      final solid = await effect(e, 0.2);
      for (final p in [LinePattern.dashed, LinePattern.dotted, LinePattern.dashDot, LinePattern.longDash]) {
        final n = count(gaps(await patterned(e, p, 0.2), solid));
        expect(n, greaterThan(8), reason: '${p.label}: the line is missing in the gaps');
        expect(n, lessThan(190), reason: '${p.label}: the dashes are still there');
      }
    });

    test('${e.label}: a Marching pattern moves its dashes and loops; a still pattern keeps them in place', () async {
      final solid2 = await effect(e, 0.2), solid7 = await effect(e, 0.7);
      final a = await patterned(e, LinePattern.ants, 0.2), b = await patterned(e, LinePattern.ants, 0.7);
      int moved(List<bool> x, List<bool> y) => [for (var i = 0; i < x.length; i++) x[i] != y[i]].where((d) => d).length;
      final marching = moved(gaps(a, solid2), gaps(b, solid7));
      final still = moved(gaps(await patterned(e, LinePattern.dashed, 0.2), solid2), gaps(await patterned(e, LinePattern.dashed, 0.7), solid7));
      // (the effect itself moves, so a still pattern is not pixel-still: it must just move clearly less)
      expect(marching, greaterThan(45), reason: 'half a loop later the dashes are elsewhere');
      expect(still, lessThan(marching - 25), reason: 'a still pattern stays where it is');
      final loop = e == ArrowEffect.neon ? CanvasPainter.neonLoops : 1;
      expect(differing(a, await patterned(e, LinePattern.ants, 0.2 + loop)), 0, reason: 'seamless loop');
    });
  }

  for (final e in effects) {
    test('${e.label}: looks unlike the plain arrow, moves with the phase and loops seamlessly', () async {
      final still = await paint((c) => CanvasPainter.drawAnnotation(c, plain));
      final a = await effect(e, 0.2);
      expect(differing(still, a), greaterThan(1500));
      final later = await effect(e, 0.45);
      expect(differing(a, later), greaterThan(150), reason: 'it moves');
      // Neon breathes once per CanvasPainter.neonLoops march loops; every other effect once per loop
      final loop = e == ArrowEffect.neon ? CanvasPainter.neonLoops : 1;
      final wrapped = await effect(e, 0.2 + loop);
      expect(differing(a, wrapped), 0, reason: 'phase ${0.2 + loop} is phase 0.2: the loop is seamless');
      final again = await effect(e, 0.2);
      expect(differing(a, again), 0, reason: 'the same phase always draws the same frame');
    });
  }

  test('Neon breathes three times slower than the march loop; the other effects keep one breath per loop', () async {
    expect(CanvasPainter.neonLoops, 3);
    // one march loop (0.8 s in the editor) is a third of a breath: 2.4 s a breath
    final start = await effect(ArrowEffect.neon, 0);
    expect(differing(start, await effect(ArrowEffect.neon, 1)), greaterThan(150), reason: 'not back after one loop');
    expect(differing(start, await effect(ArrowEffect.neon, 2)), greaterThan(150), reason: 'not back after two loops');
    expect(differing(start, await effect(ArrowEffect.neon, 3)), 0, reason: 'back after three loops: one whole breath');
    // the glow is the same at the same point of the breath, and peaks a quarter in (0.75 loops), lowest at 2.25
    final glowAt = <double, int>{};
    for (final p in [0.0, 0.75, 1.5, 2.25]) {
      final px = await effect(ArrowEffect.neon, p);
      glowAt[p] = px.where((c) => c != 0xFF403020).length; // not the background (rgba 20 30 40 read as a uint32)
    }
    expect(glowAt[0.75]!, greaterThan(glowAt[0]!), reason: 'the glow swells for the first 0.75 loops (a quarter breath)');
    expect(glowAt[0.75]!, greaterThan(glowAt[1.5]!));
    expect(glowAt[2.25]!, lessThan(glowAt[1.5]!), reason: 'and is dimmest at three quarters of the breath');
    expect(glowAt[2.25]!, lessThan(glowAt[0]!));
    // the other effects: unchanged, a loop of 1
    for (final e in effects.where((e) => e != ArrowEffect.neon)) {
      expect(differing(await effect(e, 0.3), await effect(e, 1.3)), 0, reason: '${e.label} still loops once per march loop');
      expect(differing(await effect(e, 0.3), await effect(e, 0.8)), greaterThan(0), reason: '${e.label} moves');
    }
  });

  test('a breath of Neon is seamless: the frame after the last is the first', () async {
    const steps = 60; // the editor's ticker: 20 steps per loop, three loops
    final first = await effect(ArrowEffect.neon, 0);
    final last = await effect(ArrowEffect.neon, (steps - 1) / 20);
    final next = await effect(ArrowEffect.neon, steps / 20);
    expect(differing(next, first), 0);
    expect(differing(last, first), greaterThan(0), reason: 'the last step is still short of the start');
    // the step to the loop point is no bigger than any other step (no jump)
    final steps1 = await effect(ArrowEffect.neon, 1 / 20);
    final normal = differing(first, steps1), wrap = differing(last, next);
    expect(wrap, lessThanOrEqualTo(normal * 2 + 50));
  });

  test('the export loop holds one whole Neon breath, and is unchanged without one', () async {
    final base = await () async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = Colors.white);
      return rec.endRecording().toImage(400, 200);
    }();
    CanvasState with_(ArrowEffect e) => CanvasState(
        image: base, annotations: [plain.copyWith(arrowStyle: plain.arrowStyle.copyWith(effect: e))]);
    expect(BuildUpGif.marchLoops(with_(ArrowEffect.neon)), 3);
    for (final e in effects.where((e) => e != ArrowEffect.neon)) {
      expect(BuildUpGif.marchLoops(with_(e)), 1, reason: e.label);
    }
    expect(BuildUpGif.marchLoops(CanvasState(image: base, annotations: [plain])), 1);
    // the loop's length in frames: three times as long with Neon, the same as before without
    final old = BuildUpGif.fps;
    addTearDown(() => BuildUpGif.fps = old);
    BuildUpGif.fps = 15;
    final neon = await ui.instantiateImageCodec(await BuildUpGif.renderMarching(with_(ArrowEffect.neon)));
    final fire = await ui.instantiateImageCodec(await BuildUpGif.renderMarching(with_(ArrowEffect.fire)));
    expect(neon.frameCount, 3 * fire.frameCount, reason: '2.4 s against 0.8 s');
    expect(fire.frameCount, (BuildUpGif.marchCycle * 15).round());
    expect(neon.frameCount, 36);
    // the build-up GIF's final hold already runs three loops (3 s - 0.6 s = 2.4 s): one whole breath, length unchanged
    expect((BuildUpGif.finalHold - BuildUpGif.pauseAfterEach).inMilliseconds,
        (BuildUpGif.marchCycle * 1000 * CanvasPainter.neonLoops).round());
  });

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

  test('a short, sharply bent arrow: the line follows the drawn curve into the head, effect or not', () async {
    // As draw mode fits a quick hook: explicit end tangents much longer than what is left behind the head
    const shape = ArrowShape(Offset(40, 160), Offset(150, 70), tangents: [Offset(150, 0), Offset(30, -150)]);
    // Clearly painted (not just an effect's faint dark shadow or an antialiased fringe)
    bool painted(int a, int b) => [0, 8, 16].any((sh) => (((a >> sh) & 255) - ((b >> sh) & 255)).abs() > 60);
    final curve = CanvasPainter.curveSamples([shape.from, shape.to], tangents: shape.tangents, perSegment: 200);
    for (final e in [ArrowEffect.none, ArrowEffect.flow]) {
      final a = Annotation(id: 3, color: Colors.cyan, size: StrokeSize.medium,
          arrowStyle: ArrowStyle(end: ArrowHead.swept, shadow: false, effect: e), shape: shape);
      final px = await paint((c) => CanvasPainter.drawAnnotation(c, a));
      final bg = await paint((c) {});
      var off = 0, gap = 0;
      for (var i = 0; i < px.length; i++) {
        if (!painted(px[i], bg[i])) continue;
        final p = Offset((i % 400).toDouble(), (i ~/ 400).toDouble());
        if ((p - shape.to).distance < 34) continue; // the head
        final near = curve.map((q) => (q - p).distance).reduce((x, y) => x < y ? x : y);
        if (near > a.lineWidth / 2 + 4) off++;
      }
      // No gap: every point of the curve from 30 to 18 px before the tip is painted
      for (final q in curve) {
        final d = (q - shape.to).distance;
        if (d < 18 || d > 30) continue;
        final i = q.dy.round() * 400 + q.dx.round();
        if (!painted(px[i], bg[i])) gap++;
      }
      expect(off, lessThan(20), reason: '${e.label}: the line strays from the drawn curve');
      expect(gap, 0, reason: '${e.label}: a gap between the line and the head');
    }
  });
}
