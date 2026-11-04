import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../editor/canvas_painter.dart';
import '../model/annotation.dart';
import 'epicycles.dart';
import 'gif_encoder.dart';

/// The "build-up" GIF: the original capture, then each annotation appearing in the order it was added,
/// then the finished picture, looping. Rendering uses the editor's own painter; encoding is pure Dart.
class BuildUpGif {
  /// Frames a second, set in Settings (`gifFps`): 50 (20 ms, the shortest delay GIF players honour) is the
  /// smoothest, 25 and 15 make smaller files. Appearances stay unhurried either way.
  static const fpsChoices = [15, 25, 50];
  static int fps = 50;
  static const openingHold = Duration(milliseconds: 1200);
  static const pauseAfterEach = Duration(milliseconds: 600);
  static const finalHold = Duration(milliseconds: 3000);
  static const lineDraw = Duration(milliseconds: 1200), fourierDraw = Duration(milliseconds: 2800);
  /// The GIF's longest side in output pixels, user-chosen (editor GIF options / `gifMaxSide` pref): any
  /// value clamped to [minMaxSide]..[maxMaxSide]. Default 3840 keeps the old behaviour (full Retina
  /// sharpness, capped at a 4K side). The GIF never upscales past the capture's own pixels — see
  /// [outputScale].
  static const minMaxSide = 256, maxMaxSide = 6000;
  static int maxSide = 3840;

  /// Clamp and set the chosen longest-side size (rejects out-of-range custom values).
  static void setMaxSide(int px) => maxSide = px.clamp(minMaxSide, maxMaxSide);

  /// Fourier circles trace lines, pen strokes and outlines as they draw on (the editor's setting).
  static bool fourier = false;

  /// The GIF's canvas is the whole original captured image. Optionally it can crop to the markup's bounding
  /// box plus a margin (the point of interest) — off by default: the original image stays the canvas.
  static bool focusOnMarkup = false;

  /// How long an annotation takes to appear: lines and outlines draw on a bit slower than pops and fades,
  /// and slower still while Fourier circles trace them, so the circles can be seen.
  static Duration appearing(Annotation a) => fourier && Epicycles.of(a) != null ? fourierDraw : switch (a.shape) {
        ArrowShape() || LineShape() || RectShape() || EllipseShape() || PenShape() => lineDraw,
        HighlightShape() => const Duration(milliseconds: 900),
        _ => const Duration(milliseconds: 700),
      };

  /// Output pixels per image pixel: the capture's full resolution, at most [maxSide] long.
  static double outputScale(CanvasState s) =>
      (maxSide / math.max(s.image.width, s.image.height)).clamp(0.01, 1.0);

  static Future<Uint8List> render(CanvasState s) async {
    final k = outputScale(s);
    final fullW = math.max(1, (s.image.width * k).round()), fullH = math.max(1, (s.image.height * k).round());
    // Focus the animation on the markup, not the whole capture (see [focusOnMarkup]).
    final focus = focusOnMarkup ? await _markupBounds(s, k, fullW, fullH) : null;
    final crop = focus == null
        ? Rect.fromLTWH(0, 0, s.image.width.toDouble(), s.image.height.toDouble())
        : _withMargin(focus, s.image.width.toDouble(), s.image.height.toDouble());
    final origin = crop.topLeft;
    final w = math.max(1, (crop.width * k).round()), h = math.max(1, (crop.height * k).round());
    final progress = <int, double>{};
    final march = ValueNotifier<double>(0);
    final frames = <GifFrame>[];
    Uint32List? previous;

    // Each frame keeps only the rectangle that changed; pixels in it that didn't change stay transparent.
    Future<void> frame(Duration delay) async {
      final pixels = await _snapshot(s, progress, march, k, w, h, origin: origin);
      if (previous == null) {
        frames.add(GifFrame(0, 0, w, h, pixels.buffer.asUint8List(), delay.inMilliseconds));
      } else {
        final changed = _changedRect(previous!, pixels, w, h);
        if (changed == null) {
          frames.last.delayMs += delay.inMilliseconds;
        } else {
          frames.add(_crop(previous!, pixels, w, changed, delay.inMilliseconds));
        }
      }
      previous = pixels;
    }

    await _timeline(s, progress, march, fps, frame, (d) => frames.last.delayMs += d.inMilliseconds);
    return _encodeInBackground(w, h, frames);
  }

  /// The bounding box (image pixels) of everything drawn over the capture, or null when nothing shows.
  /// Measured by what changes between the bare capture and the fully-drawn one, so it covers every shape,
  /// stroke, arrowhead, shadow and glyph exactly. Fourier circles are transient (gone at t=1) and left out.
  static Future<Rect?> _markupBounds(CanvasState s, double k, int w, int h) async {
    final zero = ValueNotifier<double>(0);
    final bare = await _snapshot(s.copyWith(annotations: const []), null, zero, k, w, h);
    final withMarkup = await _snapshot(s, null, zero, k, w, h); // null progress = everything shown
    var r = _changedRect(bare, withMarkup, w, h); // output-pixel coordinates
    // Fourier circles sweep widest mid-draw and are gone at t=1, so include a mid pass or they get clipped.
    if (fourier && s.annotations.any((a) => Epicycles.of(a) != null)) {
      final mid = {for (final a in s.annotations) a.id: 0.5};
      final r2 = _changedRect(bare, await _snapshot(s, mid, zero, k, w, h), w, h);
      r = r == null ? r2 : (r2 == null ? r : r.expandToInclude(r2));
    }
    return r == null ? null : Rect.fromLTRB(r.left / k, r.top / k, r.right / k, r.bottom / k);
  }

  /// The focus box grown by a margin (≈8% of its longer side) and clamped to the image.
  static Rect _withMargin(Rect focus, double imgW, double imgH) {
    final m = math.max(focus.width, focus.height) * 0.08;
    return focus.inflate(m).intersect(Rect.fromLTWH(0, 0, imgW, imgH));
  }

  /// Whether any annotation uses the Marching Ants pattern.
  static bool marches(CanvasState s) => s.annotations.any((a) => a.styleKind != null && a.arrowStyle.pattern.marches);

  /// The finished picture with only its Marching Ants moving: one dash cycle that loops seamlessly
  /// (what ⌘C copies when the markup has them).
  static Future<Uint8List> renderMarching(CanvasState s) async {
    final k = outputScale(s);
    final w = math.max(1, (s.image.width * k).round()), h = math.max(1, (s.image.height * k).round());
    final march = ValueNotifier<double>(0);
    final n = (marchCycle * fps).round(), delay = 1000 ~/ fps;
    final frames = <GifFrame>[];
    Uint32List? previous;
    for (var i = 0; i < n; i++) {
      march.value = i / n;
      final pixels = await _snapshot(s, null, march, k, w, h); // null = everything shown
      final changed = previous == null ? null : _changedRect(previous, pixels, w, h);
      if (previous == null) {
        frames.add(GifFrame(0, 0, w, h, pixels.buffer.asUint8List(), delay));
      } else if (changed == null) {
        frames.last.delayMs += delay;
      } else {
        frames.add(_crop(previous, pixels, w, changed, delay));
      }
      previous = pixels;
    }
    return _encodeInBackground(w, h, frames);
  }

  /// The animation itself: the original, then each annotation appearing in the order it was added.
  /// [frame] shows the current [progress] for a while; [hold] lengthens the frame on screen.
  /// Marching Ants lines run during the final hold (still while they appear, so those frames stay small).
  static Future<void> _timeline(CanvasState s, Map<int, double> progress, ValueNotifier<double> march, int fps,
      Future<void> Function(Duration) frame, void Function(Duration) hold) async {
    final order = [...s.annotations]..sort((a, b) => a.id.compareTo(b.id)); // the order they were added
    await frame(openingHold);
    for (final a in order) {
      final n = math.max(2, appearing(a).inMilliseconds * fps ~/ 1000);
      final step = Duration(microseconds: appearing(a).inMicroseconds ~/ n);
      for (var i = 1; i <= n; i++) {
        progress[a.id] = i / n;
        await frame(step);
      }
      hold(pauseAfterEach);
    }
    final rest = finalHold - pauseAfterEach;
    if (!marches(s)) return hold(rest);
    final n = rest.inMilliseconds * fps ~/ 1000, step = Duration(microseconds: rest.inMicroseconds ~/ n);
    for (var i = 1; i <= n; i++) {
      march.value = (i / fps / marchCycle) % 1;
      await frame(step);
    }
    march.value = 0;
  }

  /// Seconds for marching ants to run one dash cycle (as in the editor).
  static const marchCycle = 0.8;

  static const stickerSide = 512, stickerFps = 12, stickerMaxMs = 9500;

  /// The same animation as WhatsApp sticker frames: the picture fitted in a transparent 512×512 square
  /// (16 px margin), full frames of straight RGBA, at most [stickerMaxMs] long (sped up to fit).
  static Future<List<({Uint8List rgba, int ms})>> stickerFrames(CanvasState s) async {
    const side = stickerSide, box = side - 32.0;
    final k = math.min(box / s.image.width, box / s.image.height);
    final w = s.image.width * k, h = s.image.height * k;
    final at = Offset((side - w) / 2, (side - h) / 2);
    final progress = <int, double>{};
    final march = ValueNotifier<double>(0);
    final frames = <({Uint8List rgba, int ms})>[];
    final ms = <int>[];

    Future<void> frame(Duration delay) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..translate(at.dx, at.dy);
      canvas.clipRect(Rect.fromLTWH(0, 0, w, h));
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
      CanvasPainter(state: s, selectionId: null, scale: k, progress: progress, march: march, epicycles: fourier)
          .paint(canvas, Size(w, h));
      final image = await recorder.endRecording().toImage(side, side);
      final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
      image.dispose();
      if (frames.isNotEmpty && _same(frames.last.rgba, rgba)) {
        ms.last += delay.inMilliseconds;
      } else {
        frames.add((rgba: rgba, ms: 0));
        ms.add(delay.inMilliseconds);
      }
    }

    // Fewer frames per appearance when there's a lot of markup, so the frames (1 MB each) stay around 60
    final fps = s.annotations.length <= 8 ? stickerFps : math.max(4, 96 ~/ s.annotations.length);
    await _timeline(s, progress, march, fps, frame, (d) => ms.last += d.inMilliseconds);
    final total = ms.fold(0, (a, b) => a + b);
    final f = total > stickerMaxMs ? stickerMaxMs / total : 1.0;
    return [for (var i = 0; i < frames.length; i++) (rgba: frames[i].rgba, ms: math.max(20, (ms[i] * f).floor()))];
  }

  static bool _same(Uint8List a, Uint8List b) {
    final x = a.buffer.asUint32List(a.offsetInBytes, a.length ~/ 4), y = b.buffer.asUint32List(b.offsetInBytes, b.length ~/ 4);
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  /// A closure of its own, so the isolate gets only the frames (not the canvas and its images).
  static Future<Uint8List> _encodeInBackground(int w, int h, List<GifFrame> frames) =>
      Isolate.run(() => encodeGif(w, h, frames));

  /// One frame as RGBA pixels that are either opaque or 0. GIF has no partial transparency, so transparent
  /// canvas areas (a window's rounded corners) stay transparent and their soft edges are blended onto white.
  static Future<Uint32List> _snapshot(CanvasState s, Map<int, double>? progress, ValueListenable<double> march, double k,
      int w, int h, {Offset origin = Offset.zero}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Crop to a focus box: shift it to the top-left corner, then only the w×h window is rasterized.
    if (origin != Offset.zero) canvas.translate(-origin.dx * k, -origin.dy * k);
    CanvasPainter(state: s, selectionId: null, scale: k, progress: progress, march: march, epicycles: fourier)
        .paint(canvas, Size(w.toDouble(), h.toDouble()));
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    final px = data!.buffer.asUint32List();
    for (var i = 0; i < px.length; i++) {
      final p = px[i], a = p >>> 24; // little-endian RGBA bytes: alpha is the top byte
      if (a == 255) continue;
      if (a < 128) {
        px[i] = 0;
        continue;
      }
      int over(int c) => (c * a + 255 * (255 - a)) ~/ 255;
      px[i] = 0xFF000000 | (over((p >> 16) & 0xFF) << 16) | (over((p >> 8) & 0xFF) << 8) | over(p & 0xFF);
    }
    return px;
  }

  static Rect? _changedRect(Uint32List a, Uint32List b, int w, int h) {
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (a[row + x] != b[row + x]) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    return maxX < 0 ? null : Rect.fromLTRB(minX.toDouble(), minY.toDouble(), maxX + 1.0, maxY + 1.0);
  }

  /// The changed rectangle of `now`, with pixels equal to `before` cleared (alpha 0 = keep the last frame's).
  static GifFrame _crop(Uint32List before, Uint32List now, int w, Rect r, int delayMs) {
    final x0 = r.left.toInt(), y0 = r.top.toInt(), cw = r.width.toInt(), ch = r.height.toInt();
    final out = Uint32List(cw * ch);
    for (var y = 0; y < ch; y++) {
      final src = (y0 + y) * w + x0;
      for (var x = 0; x < cw; x++) {
        final p = now[src + x];
        out[y * cw + x] = p == before[src + x] ? 0 : p;
      }
    }
    return GifFrame(x0, y0, cw, ch, out.buffer.asUint8List(), delayMs);
  }
}
