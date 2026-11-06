import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:snaplite_flutter/app/app_controller.dart';

void main() {
  test('window size scales with the screen and caps at 1240x860', () {
    expect(initialWindowSize(null), const Size(1240, 860));
    expect(initialWindowSize(const Size(1728, 1080)), const Size(1240, 842)); // 16" MacBook Pro
    expect(initialWindowSize(const Size(1512, 945)), const Size(1119, 737)); // 14" MacBook Pro
    expect(initialWindowSize(const Size(1710, 1070)), const Size(1240, 835)); // 15" MacBook Air
    expect(initialWindowSize(const Size(800, 500)), const Size(720, 480)); // never below the minimum
  });
}
