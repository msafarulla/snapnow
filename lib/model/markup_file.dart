import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'annotation.dart';

/// Keeps a capture's markup inside its saved PNG, so reopening it brings back the original capture and
/// every annotation (in the order it was added) instead of a flat picture: it can still be edited, or
/// turned into a build-up GIF, long after it was saved.
///
/// The PNG itself is the finished image, so any viewer shows it as usual. The markup rides in a private
/// chunk, `snLP`: ancillary (viewers skip it) and not safe to copy (editors that change the pixels drop
/// it). It also records a checksum of the image data; if another app changed the pixels anyway, the
/// markup no longer matches and the file opens flat.
///
/// Chunk layout: "SNLP", version byte, u32 JSON length, JSON, u32 image count, then each image as
/// u32 length + PNG bytes. Image 0 is the base capture; image overlays refer to the others by index.
/// Everything read back is validated and bounded; anything off and [read] returns null.
class MarkupFile {
  static const version = 1;
  static const _type = 'snLP';
  static const _magic = 'SNLP';
  static const maxChunk = 512 * 1024 * 1024;
  static const maxSide = 20000;
  static const maxPixels = 120 * 1000 * 1000;
  static const maxAnnotations = 20000;
  static const maxImages = 500;

  /// `flatPng` with `s`'s markup added; `flatPng` unchanged when there's no markup to keep.
  static Future<Uint8List> embed(Uint8List flatPng, CanvasState s) async {
    if (s.annotations.isEmpty) return flatPng;
    final chunks = _chunks(flatPng);
    if (chunks == null) return flatPng;
    final images = <Uint8List>[await _png(s.image)];
    final json = {
      'idat': _idatCrc(flatPng, chunks),
      'width': s.image.width,
      'height': s.image.height,
      'density': s.density,
      'background': s.background.toARGB32(),
      'annotations': [for (final a in s.annotations) await _annotation(a, images)],
    };
    final body = BytesBuilder(copy: false)
      ..add(ascii.encode(_magic))
      ..addByte(version);
    final text = utf8.encode(jsonEncode(json));
    body..add(_u32(text.length))..add(text)..add(_u32(images.length));
    for (final png in images) {
      body..add(_u32(png.length))..add(png);
    }
    // Insert just before IEND, dropping any older copy
    final out = BytesBuilder(copy: false)..add(flatPng.sublist(0, 8));
    for (final c in chunks) {
      if (c.type == _type) continue;
      if (c.type == 'IEND') out.add(_chunk(_type, body.takeBytes()));
      out.add(flatPng.sublist(c.start, c.end));
    }
    return out.takeBytes();
  }

  /// The canvas saved in `png`, or null when it carries no (usable) markup.
  static Future<CanvasState?> read(Uint8List png) async {
    try {
      final chunks = _chunks(png);
      if (chunks == null) return null;
      final c = chunks.where((c) => c.type == _type).firstOrNull;
      if (c == null) return null;
      final d = ByteData.sublistView(png, c.dataStart, c.dataStart + c.length);
      if (d.lengthInBytes < 13 || ascii.decode(png.sublist(c.dataStart, c.dataStart + 4)) != _magic) return null;
      if (d.getUint8(4) != version) return null;
      var p = 5;
      final jsonLen = d.getUint32(p);
      p += 4;
      if (jsonLen > d.lengthInBytes - p) return null;
      final json = jsonDecode(utf8.decode(png.sublist(c.dataStart + p, c.dataStart + p + jsonLen)));
      p += jsonLen;
      if (json is! Map || json['idat'] != _idatCrc(png, chunks)) return null; // pixels changed since
      final count = d.getUint32(p);
      p += 4;
      if (count < 1 || count > maxImages) return null;
      final blobs = <Uint8List>[];
      for (var i = 0; i < count; i++) {
        if (p + 4 > d.lengthInBytes) return null;
        final n = d.getUint32(p);
        p += 4;
        if (n > d.lengthInBytes - p) return null;
        blobs.add(png.sublist(c.dataStart + p, c.dataStart + p + n));
        p += n;
      }
      final images = List<ui.Image?>.filled(count, null);
      Future<ui.Image> image(int i) async => images[i] ??= await _decode(blobs[i]);

      final base = await image(0);
      if (base.width != json['width'] || base.height != json['height']) return null;
      final list = json['annotations'];
      if (list is! List || list.isEmpty || list.length > maxAnnotations) return null;
      final ids = <int>{};
      final annotations = <Annotation>[];
      for (final j in list) {
        final a = await _parse(j, (i) => i is int && i > 0 && i < count ? image(i) : throw const FormatException());
        if (a.id <= 0 || !ids.add(a.id)) return null;
        annotations.add(a);
      }
      final density = _num(json['density']);
      return CanvasState(
        image: base,
        annotations: annotations,
        background: ui.Color(_int(json['background'])),
        density: density > 0 && density <= 8 ? density : 1,
      );
    } catch (_) {
      return null;
    }
  }

  // ---- Annotations as JSON ----

  static Future<Map<String, Object?>> _annotation(Annotation a, List<Uint8List> images) async {
    final shape = switch (a.shape) {
      ArrowShape(:final from, :final to, :final points, :final tangents) =>
        {'kind': 'arrow', 'from': _pt(from), 'to': _pt(to), 'points': [for (final q in points) _pt(q)],
          'tangents': [for (final t in tangents) t == null ? null : _pt(t)]},
      LineShape(:final from, :final to, :final points, :final tangents) =>
        {'kind': 'line', 'from': _pt(from), 'to': _pt(to), 'points': [for (final q in points) _pt(q)],
          'tangents': [for (final t in tangents) t == null ? null : _pt(t)]},
      RectShape(:final rect) => {'kind': 'box', 'rect': _rc(rect)},
      EllipseShape(:final rect) => {'kind': 'ellipse', 'rect': _rc(rect)},
      HighlightShape(:final rect) => {'kind': 'highlight', 'rect': _rc(rect)},
      SpotlightShape(:final rect) => {'kind': 'spotlight', 'rect': _rc(rect)},
      BlurShape(:final rect) => {'kind': 'blur', 'rect': _rc(rect)}, // the painter pixelates live
      PenShape(:final points) => {'kind': 'pen', 'points': [for (final q in points) _pt(q)]},
      TextShape(:final string, :final at, :final runs) =>
        {'kind': 'text', 'string': string, 'at': _pt(at), 'runs': [for (final r in runs) _run(r)]},
      CalloutShape(:final string, :final at, :final tail, :final runs, :final style) =>
        {'kind': 'callout', 'string': string, 'at': _pt(at), 'tail': tail == null ? null : _pt(tail),
          'runs': [for (final r in runs) _run(r)], 'style': style.name},
      StepShape(:final center, :final style) => {'kind': 'step', 'center': _pt(center), 'style': style.name},
      ImageShape(:final rect, :final image) => {'kind': 'image', 'rect': _rc(rect), 'image': (images..add(await _png(image))).length - 1},
    };
    return {
      'id': a.id,
      'color': a.color.toARGB32(),
      'size': a.size.index,
      'style': a.arrowStyle.toJson(),
      'scale': a.scale,
      'text': a.textFormat.toJson(),
      ...shape,
    };
  }

  /// Saved by name (stable if the enum is ever reordered); files from before step styles, or an unknown
  /// name, give a circle.
  static StepMarker _stepMarker(Object? v) => StepMarker.values.where((s) => s.name == v).firstOrNull ?? StepMarker.circle;

  static Future<Annotation> _parse(Object? j, Future<ui.Image> Function(Object?) image) async {
    if (j is! Map) throw const FormatException();
    List<ui.Offset> pts(Object? v) => [for (final q in v as List) _offset(q)];
    final shape = switch (j['kind']) {
      'arrow' => ArrowShape(_offset(j['from']), _offset(j['to']), points: pts(j['points']),
          tangents: [for (final t in j['tangents'] as List) t == null ? null : _offset(t)]),
      'line' => LineShape(_offset(j['from']), _offset(j['to']), points: pts(j['points']),
          tangents: [for (final t in j['tangents'] as List) t == null ? null : _offset(t)]),
      'box' => RectShape(_rect(j['rect'])),
      'ellipse' => EllipseShape(_rect(j['rect'])),
      'highlight' => HighlightShape(_rect(j['rect'])),
      'spotlight' => SpotlightShape(_rect(j['rect'])),
      'blur' => BlurShape(_rect(j['rect']), null),
      'pen' => PenShape(pts(j['points'])),
      'text' => TextShape(j['string'] as String, _offset(j['at']), runs: _runs(j['runs'])),
      'callout' => CalloutShape(j['string'] as String, _offset(j['at']),
          tail: j['tail'] == null ? null : _offset(j['tail']), runs: _runs(j['runs']),
          style: CalloutStyle.values.where((s) => s.name == j['style']).firstOrNull ?? CalloutStyle.rounded),
      'step' => StepShape(_offset(j['center']), style: _stepMarker(j['style'])),
      'image' => ImageShape(_rect(j['rect']), await image(j['image'])),
      _ => throw const FormatException(),
    };
    final size = _int(j['size']);
    final scale = _num(j['scale']);
    return Annotation(
      id: _int(j['id']),
      shape: shape,
      color: ui.Color(_int(j['color'])),
      size: size >= 0 && size < StrokeSize.values.length ? StrokeSize.values[size] : StrokeSize.medium,
      arrowStyle: ArrowStyle.fromJson(j['style']) ?? const ArrowStyle(),
      scale: scale > 0 && scale <= 8 ? scale : 1,
      textFormat: TextFormat.fromJson(j['text']) ?? const TextFormat(),
    );
  }

  static List<double> _pt(ui.Offset o) => [o.dx, o.dy];
  static List<double> _rc(ui.Rect r) => [r.left, r.top, r.right, r.bottom];
  static List<Object?> _run(TextRun r) =>
      [r.start, r.end, r.style.color?.toARGB32(), r.style.bold, r.style.italic, r.style.underline];

  static ui.Offset _offset(Object? v) {
    final l = v as List;
    if (l.length != 2) throw const FormatException();
    return ui.Offset(_num(l[0]), _num(l[1]));
  }

  static ui.Rect _rect(Object? v) {
    final l = v as List;
    if (l.length != 4) throw const FormatException();
    return ui.Rect.fromLTRB(_num(l[0]), _num(l[1]), _num(l[2]), _num(l[3]));
  }

  static List<TextRun> _runs(Object? v) => [
        for (final r in v as List)
          TextRun(_int((r as List)[0]), _int(r[1]),
              (color: r[2] == null ? null : ui.Color(_int(r[2])), bold: r[3] as bool?, italic: r[4] as bool?,
                underline: r[5] as bool?)),
      ];

  static double _num(Object? v) {
    final x = (v as num).toDouble();
    if (!x.isFinite) throw const FormatException();
    return x;
  }

  static int _int(Object? v) => v is int ? v : throw const FormatException();

  // ---- Images ----

  static Future<Uint8List> _png(ui.Image image) async =>
      (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

  /// Decodes an embedded PNG after checking its header size, so a crafted file can't ask for a huge bitmap.
  static Future<ui.Image> _decode(Uint8List png) async {
    final chunks = _chunks(png);
    if (chunks == null || chunks.first.type != 'IHDR' || chunks.first.length < 8) throw const FormatException();
    final h = ByteData.sublistView(png, chunks.first.dataStart);
    final w = h.getUint32(0), ht = h.getUint32(4);
    if (w == 0 || ht == 0 || w > maxSide || ht > maxSide || w * ht > maxPixels) throw const FormatException();
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  // ---- PNG chunks ----

  static const _signature = [137, 80, 78, 71, 13, 10, 26, 10];

  /// The file's chunks, or null if it isn't a well-formed PNG (bad signature, sizes or checksums).
  static List<_Chunk>? _chunks(Uint8List png) {
    if (png.length < 8) return null;
    for (var i = 0; i < 8; i++) {
      if (png[i] != _signature[i]) return null;
    }
    final d = ByteData.sublistView(png);
    final out = <_Chunk>[];
    var p = 8;
    while (p + 12 <= png.length) {
      final len = d.getUint32(p);
      if (len > maxChunk || p + 12 + len > png.length) return null;
      final type = ascii.decode(png.sublist(p + 4, p + 8), allowInvalid: true);
      if (_crc(png, p + 4, p + 8 + len) != d.getUint32(p + 8 + len)) return null;
      out.add(_Chunk(type, p, len));
      p += 12 + len;
      if (type == 'IEND') return out;
    }
    return null;
  }

  static int _idatCrc(Uint8List png, List<_Chunk> chunks) {
    var c = 0xFFFFFFFF;
    for (final ch in chunks.where((ch) => ch.type == 'IDAT')) {
      c = _crcUpdate(c, png, ch.dataStart, ch.dataStart + ch.length);
    }
    return c ^ 0xFFFFFFFF;
  }

  static Uint8List _chunk(String type, Uint8List data) {
    final b = BytesBuilder(copy: false)..add(_u32(data.length));
    final typed = Uint8List.fromList([...ascii.encode(type), ...data]);
    b..add(typed)..add(_u32(_crc(typed, 0, typed.length)));
    return b.takeBytes();
  }

  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

  static final _table = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int _crcUpdate(int c, Uint8List b, int start, int end) {
    for (var i = start; i < end; i++) {
      c = _table[(c ^ b[i]) & 0xFF] ^ (c >> 8);
    }
    return c;
  }

  static int _crc(Uint8List b, int start, int end) => _crcUpdate(0xFFFFFFFF, b, start, end) ^ 0xFFFFFFFF;
}

class _Chunk {
  final String type;
  final int start, length; // start = the length field
  const _Chunk(this.type, this.start, this.length);
  int get dataStart => start + 8;
  int get end => start + 12 + length;
}
