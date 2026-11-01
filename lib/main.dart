import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'app/app_controller.dart';
import 'app/theme.dart';
import 'library/library_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // file_picker's macOS panels refuse to open without sandbox file entitlements; SnapLite isn't sandboxed
  // (it runs /usr/sbin/screencapture), so that check only gets in the way of Open / Add Image / GIF save.
  if (Platform.isMacOS) await FilePicker.skipEntitlementsChecks();
  await AppController.instance.init();
  runApp(const SnapLiteApp());
}

class SnapLiteApp extends StatelessWidget {
  const SnapLiteApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Follows Settings › Appearance live: Light / Dark / Tokyo Night as chosen; Glass and Match System follow the Mac
    return ValueListenableBuilder<String>(
      valueListenable: AppController.instance.appearance,
      builder: (context, choice, _) => MaterialApp(
        title: 'SnapNow',
        debugShowCheckedModeBanner: false,
        theme: SnapTheme.light,
        darkTheme: choice == 'tokyoNight' ? SnapTheme.tokyoNight : SnapTheme.dark,
        themeMode: switch (choice) {
          'light' => ThemeMode.light,
          'dark' || 'tokyoNight' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        home: LibraryPage(key: AppController.instance.libraryKey),
      ),
    );
  }
}
