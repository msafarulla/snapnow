// Settings › Defaults publishes every user setting to the other Macs: the keys registered in PublishDefaults.settings
// (macos/Runner/Shell/PublishDefaults.swift), except the few in PublishDefaults.excluded, each with its reason.
// These checks find the preference keys the code uses (Dart prefs through Native, Swift UserDefaults keys) and fail when
// one is in neither list, so a new setting is either published (registered) or excluded on purpose.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/model/annotation.dart';

const _listFile = 'macos/Runner/Shell/PublishDefaults.swift';

String _between(String src, String begin, String end) {
  final a = src.indexOf(begin), b = src.indexOf(end);
  if (a < 0 || b <= a) throw StateError('markers $begin / $end missing in $_listFile');
  return src.substring(a + begin.length, b);
}

Iterable<File> _files(String dir, String ext) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith(ext));

/// Dart keys built at run time, expanded to every value they take.
final _templates = <String, List<String>>{
  r'style.${k.name}': [for (final k in StyleKind.values) 'style.${k.name}'],
  r'style.textFormat.$kind': ['style.textFormat.text', 'style.textFormat.callout'],
};

/// Every preference key the code uses, with where it was found.
Map<String, String> _usedKeys() {
  final found = <String, String>{};
  void add(String key, String where) {
    if (key.contains(r'$')) {
      final expanded = _templates[key];
      expect(expanded, isNotNull, reason: 'a new key built at run time, $key ($where): add it to _templates in this test');
      for (final k in expanded!) {
        found.putIfAbsent(k, () => where);
      }
    } else {
      found.putIfAbsent(key, () => where);
    }
  }

  final dartCall = RegExp(r"""Native\.(?:get|set)(?:String|Bool|DataString)\(\s*'([^']+)'""");
  final dartConst = RegExp(r"""[kK]ey\s*=\s*'([^'$]+)'""");
  for (final f in _files('lib', '.dart')) {
    final src = f.readAsStringSync();
    for (final m in dartCall.allMatches(src)) {
      add(m.group(1)!, f.path);
    }
    for (final m in dartConst.allMatches(src)) {
      add(m.group(1)!, f.path);
    }
  }

  final swiftKeyConst = RegExp(r'[kK]ey\s*=\s*"([^"\\]+)"');
  final swiftForKey = RegExp(r'forKey:\s*"([^"\\]+)"');
  for (final f in _files('macos/Runner', '.swift')) {
    final src = f.readAsStringSync();
    for (final m in swiftKeyConst.allMatches(src)) {
      add(m.group(1)!, f.path);
    }
    for (final line in src.split('\n')) {
      if (!line.contains('efaults')) continue; // UserDefaults / defaults. — not CALayer animation keys
      for (final m in swiftForKey.allMatches(line)) {
        add(m.group(1)!, f.path);
      }
    }
    final prefs = RegExp(r'\nenum Prefs \{([\s\S]*?)\n\}').firstMatch(src);
    if (prefs != null) {
      for (final m in RegExp(r'static let \w+ = "([^"\\]+)"').allMatches(prefs.group(1)!)) {
        add(m.group(1)!, '${f.path} (Prefs)');
      }
    }
  }
  return found;
}

void main() {
  final src = File(_listFile).readAsStringSync();
  // settings: (kind, key), e.g. ('path', 'schedule.folder')
  final settings = RegExp(r'^\s*\.(\w+)\("([^"]+)"', multiLine: true)
      .allMatches(_between(src, '// settings-keys:begin', '// settings-keys:end'))
      .map((m) => (m.group(1)!, m.group(2)!))
      .toList();
  final published = [for (final s in settings) s.$2];
  // excluded: key -> reason
  final excluded = {
    for (final m in RegExp(r'^\s*"([^"]+)":\s*"([^"]*)",', multiLine: true)
        .allMatches(_between(src, '// excluded-keys:begin', '// excluded-keys:end')))
      m.group(1)!: m.group(2)!,
  };
  /// Keys made per shortcut action ("shortcut.<action>", "shortcut.<action>.enabled"): registered as a family in Swift.
  bool family(String k) => k.startsWith('shortcut.');

  test('the lists are read from the Swift file', () {
    expect(published.length, greaterThan(50));
    expect(excluded.length, greaterThanOrEqualTo(10));
    expect(src, contains(r'.json("shortcut.\(action.rawValue)")'), reason: 'the shortcut family is registered');
    expect(src, contains(r'.bool("shortcut.\(action.rawValue).enabled")'));
  });

  test('no key is registered twice or both published and excluded', () {
    expect(published.toSet().length, published.length, reason: 'duplicate in settings');
    expect(published.where(excluded.containsKey), isEmpty);
  });

  test('every excluded key says why', () {
    expect({for (final e in excluded.entries) if (e.value.trim().length < 15) e.key: e.value}, isEmpty);
  });

  test('every preference key in the code is published or excluded', () {
    final used = _usedKeys();
    final unclassified = {
      for (final e in used.entries)
        if (!published.contains(e.key) && !excluded.containsKey(e.key) && !family(e.key)) e.key: e.value,
    };
    expect(unclassified, isEmpty,
        reason: 'New preference keys: register each in PublishDefaults.settings (one line, its type and rule; it is then '
            'published to the other Macs) or, if it cannot work on another Mac, add it to PublishDefaults.excluded with the '
            'reason, in $_listFile');
  });

  test('every listed key is still used by the code', () {
    final used = _usedKeys().keys.toSet();
    expect(published.where((k) => !used.contains(k)), isEmpty, reason: 'registered keys nobody reads or writes (typo or gone?)');
    expect(excluded.keys.where((k) => !used.contains(k)), isEmpty, reason: 'excluded keys nobody reads or writes');
  });

  test('screen places, permissions, first-run state and bookkeeping are excluded; paths are path settings', () {
    final machineBound = RegExp(r'lastArea|[Ff]rame|[Pp]osition|[Dd]isplay|[Ss]creen(?!shot)|prompted|granted|sharedDefaults|[Ll]icen[cs]e|[Uu]pdate|[Rr]ecent|[Cc]ache');
    expect(published.where(machineBound.hasMatch), isEmpty, reason: 'looks tied to one Mac: exclude it with the reason');
    final pathLike = RegExp(r'[Ff]older|[Pp]ath|[Dd]irectory');
    expect([for (final s in settings) if (pathLike.hasMatch(s.$2) && s.$1 != 'path') s.$2], isEmpty,
        reason: 'a folder or file setting must be .path(...) so it goes as ~/... and applies only where it exists');
  });

  test('settings that used to stay per Mac are published now', () {
    for (final k in ['hotkeys.mode', 'matrixRain', 'liveDrawMode', 'altClickHand', 'appearance', 'toolbarTools', 'toolbar.left',
        'inspector.hidden', 'pinOnTop', 'recordMicrophone', 'transcriptLanguage', 'openEditorAfterCapture', 'copyAfterCapture',
        'schedule.folder', 'schedule.interval']) {
      expect(published, contains(k));
    }
  });

  test('every tool default the editor keeps is published', () {
    for (final k in [
      ...StyleKind.values.map((k) => 'style.${k.name}'),
      'style.textFormat.text', 'style.textFormat.callout', 'myQuickStyles', 'callout.style', 'step.style', 'followDrag',
      'draw.color', 'draw.tool', 'liveDrawGlass', 'liveDrawClose', 'liveDrawCloseSpeed', 'gifEntrance', 'gifMaxSide', 'gifFps',
    ]) {
      expect(published, contains(k));
    }
  });
}
