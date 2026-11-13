import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/editor/canvas_painter.dart';
import 'package:snaplite_flutter/editor/editor_page.dart';
import 'package:snaplite_flutter/model/annotation.dart';

/// Lifting draw mode: the tools go and the marks fade away one by one, newest first, within the chosen speed's cap however many there are;
/// the marks stay in the drawing (the capture saved next has them all) and show again afterwards. Nothing drawn: done at once.
void main() {
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['snaplite/native', 'window_manager', 'pasteboard']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  Future<EditorPageState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) original?.call(d);
    };
    addTearDown(() => FlutterError.onError = original);
    final key = GlobalKey<EditorPageState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: EditorPage(key: key, overlay: true)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    return key.currentState!;
  }

  Offset at(WidgetTester tester, double fx, double fy) {
    final area = tester.getRect(find.byKey(const ValueKey('snaplite-canvas')));
    return Offset(area.left + area.width * fx, area.top + area.height * fy);
  }

  Future<void> arrows(WidgetTester tester, int n) async {
    await tester.tap(find.text('Arrow').hitTestable());
    await tester.pump();
    for (var i = 0; i < n; i++) {
      final from = at(tester, 0.2 + 0.6 * i / n, 0.7);
      await tester.dragFrom(from, at(tester, 0.25 + 0.6 * i / n, 0.4) - from);
      await tester.pump();
    }
  }

  double opacityOf(WidgetTester tester, Finder f) =>
      tester.widgetList<Opacity>(find.ancestor(of: f, matching: find.byType(Opacity))).fold(1.0, (o, w) => o * w.opacity);

  testWidgets('marks fade one by one, newest first; the drawing keeps them', (tester) async {
    final editor = await pump(tester);
    await arrows(tester, 3);
    expect(editor.hasDrawMarks, isTrue);
    expect(opacityOf(tester, find.text('Arrow').first), 1.0, reason: 'the tools show while drawing');

    late Future<bool> fading;
    final clock = Stopwatch()..start();
    await tester.runAsync(() async {
      fading = editor.fadeOutDraw();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    final mid = Map.of(editor.drawFade!);
    final ids = mid.keys.toList(); // newest first
    expect(ids.length, 3);
    expect(mid[ids.first]!, lessThan(1.0), reason: 'the newest is already fading');
    expect(mid[ids.last], 1.0, reason: 'the oldest has not started yet');
    expect(opacityOf(tester, find.text('Arrow').first), 0.0, reason: 'the tools went at once');

    final done = (await tester.runAsync(() => fading))!;
    expect(done, isTrue);
    expect(clock.elapsedMilliseconds, lessThan(1100), reason: '3 marks: 350 ms + 2 × 110 ms');
    expect(editor.drawFade!.values.every((o) => o == 0), isTrue, reason: 'every mark faded away');
    expect(editor.hasDrawMarks, isTrue, reason: 'only on screen: the drawing (and so the saved capture) keeps every mark');

    editor.clearDrawFade();
    await tester.pump();
    expect(editor.drawFade, isNull);
    expect(opacityOf(tester, find.text('Arrow').first), 1.0, reason: 'the tools are back for the next session');
  });

  testWidgets('with the menu bar icon as target each mark flies there in turn', (tester) async {
    final editor = await pump(tester);
    await arrows(tester, 3);
    late Future<bool> flying;
    await tester.runAsync(() async {
      flying = editor.fadeOutDraw(flyTo: const Offset(1500, 10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(); // paints the marks mid-flight
    expect(tester.takeException(), isNull);
    final mid = Map.of(editor.drawFade!);
    expect(mid.values.first, lessThan(1.0), reason: 'the newest is on its way');
    expect(mid.values.last, 1.0, reason: 'the oldest has not set off yet');
    // The icon point (window coordinates) lands on the same spot in image coordinates, and every arrow has a box to leave from
    final to = editor.drawFlyTo!;
    expect(to.dx * editor.debugViewScale + editor.viewOrigin.dx, closeTo(1500, 0.5));
    expect(to.dy * editor.debugViewScaleY + editor.viewOrigin.dy, closeTo(10, 0.5));
    expect(editor.drawFlyFrom!.length, 3);
    expect(editor.drawFlyFrom!.values.every((r) => r.width > 0), isTrue);
    expect((await tester.runAsync(() => flying))!, isTrue);
    await tester.pump();
    expect(editor.hasDrawMarks, isTrue);
    editor.clearDrawFade();
  });

  testWidgets('many marks still finish within the cap', (tester) async {
    final editor = await pump(tester);
    await arrows(tester, 30);
    final clock = Stopwatch()..start();
    final done = (await tester.runAsync(() => editor.fadeOutDraw()))!;
    expect(done, isTrue);
    expect(clock.elapsedMilliseconds, lessThan(1700), reason: 'capped at 1.2 s (plus timer slack)');
    expect(editor.drawFade!.length, 30);
    editor.clearDrawFade();
  });

  testWidgets('nothing drawn: answers at once, nothing hidden', (tester) async {
    final editor = await pump(tester);
    final done = (await tester.runAsync(() => editor.fadeOutDraw()))!;
    expect(done, isFalse);
    expect(editor.drawFade, isNull);
    await tester.pump();
    expect(opacityOf(tester, find.text('Arrow').first), 1.0);
  });

  testWidgets('late in its flight a mark is painted small near the icon, and is gone from where it was', (tester) async {
    const w = 400, h = 300;
    const to = Offset(380, 12);
    final box = Rect.fromLTRB(60, 216, 160, 224);
    Future<ByteData> paint(double opacity) async {
      final empty = ui.PictureRecorder();
      Canvas(empty);
      final blank = await empty.endRecording().toImage(w, h);
      final s = CanvasState(image: blank, annotations: [
        Annotation(id: 1, shape: const ArrowShape(Offset(60, 220), Offset(160, 220)), arrowStyle: const ArrowStyle(shadow: false)),
      ]);
      final rec = ui.PictureRecorder();
      CanvasPainter(state: s, selectionId: null, scale: 1, clearBase: true, fade: {1: opacity}, flyFrom: {1: box}, flyTo: to)
          .paint(Canvas(rec), Size(w.toDouble(), h.toDouble()));
      return (await (await rec.endRecording().toImage(w, h)).toByteData(format: ui.ImageByteFormat.rawRgba))!;
    }
    // Where the arrow is painted: the box and centroid of its visible pixels
    (Rect, Offset)? inked(ByteData px) {
      var n = 0; var sx = 0.0, sy = 0.0;
      double l = w.toDouble(), t = h.toDouble(), r = 0, b = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (px.getUint8((y * w + x) * 4 + 3) < 24) continue;
          n++; sx += x; sy += y;
          l = l < x ? l : x.toDouble(); t = t < y ? t : y.toDouble(); r = r > x ? r : x.toDouble(); b = b > y ? b : y.toDouble();
        }
      }
      return n == 0 ? null : (Rect.fromLTRB(l, t, r + 1, b + 1), Offset(sx / n, sy / n));
    }

    await tester.runAsync(() async {
      final home = inked(await paint(1))!;
      expect(home.$1.overlaps(box.inflate(4)), isTrue, reason: 'before it sets off it is where it was drawn');

      const p = 0.8; // 80% of the way (easing already applied): opacity left 1 - p
      final late = inked(await paint(1 - p))!;
      final from = box.center, q = 1 - p;
      final bend = Offset(from.dx + (to.dx - from.dx) * 0.2, from.dy + (to.dy - from.dy) * 0.95);
      final expected = from * (q * q) + bend * (2 * q * p) + to * (p * p);
      expect((late.$2 - expected).distance, lessThan(8), reason: 'on the arc towards the icon (expected $expected, got ${late.$2})');
      expect((late.$2 - to).distance, lessThan((from - to).distance * 0.4), reason: 'most of the way to the icon');
      expect(late.$1.width, lessThan(home.$1.width * 0.4), reason: 'shrunk on the way (3% at the end)');
      expect(late.$1.overlaps(box.inflate(4)), isFalse, reason: 'nothing left where it was');
    });
  });

  group('speed (Settings › Draw mode › Speed)', () {
    // The pace before there was a choice (1.82.8), for Fast to reproduce
    ({double each, double gap}) old(int n, {required bool fly}) {
      var each = 350.0, gap = 110.0;
      if (n > 1 && each + gap * (n - 1) > 1300) {
        gap = (1300 - each) / (n - 1);
        each = math.max(fly ? 220.0 : 60.0, math.min(each, gap * 2.5));
        gap = (1300 - each) / (n - 1);
      }
      return (each: each, gap: gap);
    }

    test('Fast is the old pace, for any number of marks, flying or only fading', () {
      const fast = DrawCloseSpeed.fast;
      expect([fast.each, fast.gap, fast.cap, fast.minEach], [350, 110, 1300, 220]);
      expect(fast.curve, Curves.easeIn);
      for (var n = 1; n <= 80; n++) {
        for (final fly in [true, false]) {
          final now = fast.timing(n, minEach: fly ? null : 60), then = old(n, fly: fly);
          expect(now.each, closeTo(then.each, 1e-9), reason: '$n marks, fly $fly');
          expect(now.gap, closeTo(then.gap, 1e-9), reason: '$n marks, fly $fly');
        }
      }
    });

    test('the default is Normal: a longer flight and a longer gap than Fast, easing into the icon', () {
      expect(DrawCloseSpeed.byId(null), DrawCloseSpeed.standard);
      expect(DrawCloseSpeed.byId('normal'), DrawCloseSpeed.standard);
      expect(DrawCloseSpeed.byId('nonsense'), DrawCloseSpeed.standard);
      expect(DrawCloseSpeed.standard.id, 'normal');
      for (final s in DrawCloseSpeed.values) {
        expect(DrawCloseSpeed.byId(s.id), s);
      }
      const order = [DrawCloseSpeed.fast, DrawCloseSpeed.standard, DrawCloseSpeed.relaxed, DrawCloseSpeed.slow];
      for (var i = 1; i < order.length; i++) {
        final a = order[i - 1], b = order[i];
        expect(b.each, greaterThan(a.each), reason: '${b.id} flies longer than ${a.id}');
        expect(b.gap, greaterThan(a.gap), reason: '${b.id} leaves more time between marks than ${a.id}');
        expect(b.cap, greaterThan(a.cap), reason: 'the cap grows with the speed setting');
        expect(b.minEach, greaterThan(a.minEach));
      }
      expect([DrawCloseSpeed.standard.each, DrawCloseSpeed.standard.gap, DrawCloseSpeed.standard.cap], [520, 190, 2200]);
      expect([DrawCloseSpeed.relaxed.each, DrawCloseSpeed.relaxed.gap, DrawCloseSpeed.relaxed.cap], [700, 270, 3000]);
      expect([DrawCloseSpeed.slow.each, DrawCloseSpeed.slow.gap, DrawCloseSpeed.slow.cap], [950, 380, 4200]);
      // Everything but Fast slows down into the icon: slower over the last 5% of the way than through the middle
      for (final s in order.skip(1)) {
        final c = s.curve;
        final end = (c.transform(1) - c.transform(0.95)) / 0.05, middle = (c.transform(0.55) - c.transform(0.45)) / 0.1;
        expect(end, lessThan(middle * 0.5), reason: '${s.id} decelerates into the icon');
      }
    });

    test('few marks: every speed keeps its own flight and gap', () {
      for (final s in DrawCloseSpeed.values) {
        for (var n = 1; s.each + s.gap * (n - 1) <= s.cap; n++) {
          final t = s.timing(n);
          expect(t.each, s.each.toDouble(), reason: '${s.id}, $n marks');
          expect(t.gap, s.gap.toDouble(), reason: '${s.id}, $n marks');
        }
      }
    });

    test('many marks: the whole stays within the cap, the gap shrinks before the flight does', () {
      for (final s in DrawCloseSpeed.values) {
        var lastEach = double.infinity, lastGap = double.infinity;
        var gapOnlyShrank = false;
        for (final n in [for (var i = 1; i <= 2000; i++) i, 5000]) {
          final t = s.timing(n);
          final total = t.each + t.gap * (n - 1);
          expect(total, lessThanOrEqualTo(s.cap + 1e-6), reason: '${s.id}, $n marks: $total ms');
          expect(t.each, greaterThanOrEqualTo(s.minEach.toDouble()), reason: '${s.id}, $n marks: a flight stays long enough to see');
          expect(t.gap, greaterThanOrEqualTo(0));
          expect(t.each, lessThanOrEqualTo(lastEach), reason: 'more marks never fly slower');
          // (Fast keeps the old formula's quirk: when its flights start to shorten the gap is worked out again and comes
          // out a little longer, up to ~115 ms; the total is still the cap.)
          if (s != DrawCloseSpeed.fast) {
            expect(t.gap, lessThanOrEqualTo(lastGap + 1e-9), reason: '${s.id}, $n marks: more marks never wait longer between');
          }
          // The flight only gets shorter once the gap is down to each / spread
          if (t.each < s.each) expect(t.gap, lessThan(s.each / s.spread + 1e-9), reason: '${s.id}, $n marks');
          if (t.gap < s.gap && t.each == s.each) gapOnlyShrank = true;
          lastEach = t.each; lastGap = t.gap;
        }
        if (s != DrawCloseSpeed.fast) expect(gapOnlyShrank, isTrue, reason: '${s.id}: some counts only bring the marks closer together');
      }
      // Fast as before: about 1.3 s for 30 marks; Slow at most 4.2 s even for 5000
      final slow = DrawCloseSpeed.slow.timing(5000);
      expect(slow.each + slow.gap * 4999, closeTo(4200, 1e-6));
    });

    test('the native side waits longer than each cap, so the glass never goes before the last mark lands', () {
      final swift = File('macos/Runner/Shell/Settings.swift').readAsStringSync();
      final names = RegExp(r'enum DrawCloseSpeed: String, CaseIterable \{\s*case ([a-z, ]+)\n').firstMatch(swift)!.group(1)!;
      expect(names.split(',').map((e) => e.trim()).toList(), [for (final s in DrawCloseSpeed.values) s.id],
          reason: 'Settings.swift sends the names Dart knows');
      final block = RegExp(r'var wait: TimeInterval \{(.*?)\n    \}', dotAll: true).firstMatch(swift)!.group(1)!;
      final waits = {for (final m in RegExp(r'case \.(\w+): return ([\d.]+)').allMatches(block)) m.group(1)!: double.parse(m.group(2)!)};
      expect(waits.keys.toSet(), {for (final s in DrawCloseSpeed.values) s.id});
      for (final s in DrawCloseSpeed.values) {
        expect(waits[s.id]! * 1000, greaterThanOrEqualTo(s.cap + 600), reason: '${s.id}: wait ${waits[s.id]} s vs cap ${s.cap} ms');
      }
      final longest = DrawCloseSpeed.values.map((s) => s.cap).reduce(math.max);
      expect(waits.values.reduce(math.max) * 1000, greaterThan(longest + 600), reason: 'the slowest setting is covered');
    });

    Future<int> timeFlight(WidgetTester tester, int marks, {DrawCloseSpeed? speed, bool fly = true}) async {
      final editor = await pump(tester);
      await arrows(tester, marks);
      final clock = Stopwatch()..start();
      final done = (await tester.runAsync(() => speed == null
          ? editor.fadeOutDraw(flyTo: fly ? const Offset(1500, 10) : null)
          : editor.fadeOutDraw(flyTo: fly ? const Offset(1500, 10) : null, speed: speed)))!;
      final ms = clock.elapsedMilliseconds;
      expect(done, isTrue);
      expect(editor.drawFade!.values.every((o) => o == 0), isTrue, reason: 'every mark is gone');
      editor.clearDrawFade();
      return ms;
    }

    testWidgets('default: 3 marks take Normal’s 520 ms + 2 × 190 ms', (tester) async {
      final ms = await timeFlight(tester, 3);
      expect(ms, inInclusiveRange(880, 1500));
    });

    testWidgets('Fast: 3 marks take 350 ms + 2 × 110 ms, as before', (tester) async {
      final ms = await timeFlight(tester, 3, speed: DrawCloseSpeed.fast);
      expect(ms, inInclusiveRange(550, 1000));
    });

    testWidgets('Slow: 3 marks take 950 ms + 2 × 380 ms', (tester) async {
      final ms = await timeFlight(tester, 3, speed: DrawCloseSpeed.slow);
      expect(ms, inInclusiveRange(1690, 2400));
    });

    testWidgets('Slow with 30 marks still ends at its 4.2 s cap', (tester) async {
      final ms = await timeFlight(tester, 30, speed: DrawCloseSpeed.slow);
      expect(ms, inInclusiveRange(4180, 4900));
    });

    testWidgets('Reduce Motion (no icon point): only fades, at the old Fast pace whatever the speed', (tester) async {
      final ms = await timeFlight(tester, 3, speed: DrawCloseSpeed.slow, fly: false);
      expect(ms, inInclusiveRange(550, 1000));
    });
  });
}
