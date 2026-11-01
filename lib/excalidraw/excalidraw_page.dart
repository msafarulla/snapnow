import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Embeds the bundled, offline Excalidraw whiteboard (assets/excalidraw/) in a WebView and bridges it to the
/// Flutter host: it can start blank or with a capture dropped in, and export a flattened PNG back to SnapNow.
///
/// The bundle is served over a local HTTP server (not file://), so the sibling JS/CSS/fonts load with normal
/// relative URLs and the JS↔Dart bridge works — file:// in WKWebView blocks both. The WebView plugin is
/// flutter_inappwebview (macOS/Windows/mobile); the bundle and bridge are platform-agnostic, so a Linux
/// WebView backend can be slotted in later without touching either.
class ExcalidrawPage extends StatefulWidget {
  final Uint8List? capture; // a PNG to open as an image element; null for a blank board
  final Size? captureSize; // the capture's pixel size (for the image element)
  final void Function(Uint8List png)? onExport; // flattened PNG, when the user sends it back to SnapNow

  const ExcalidrawPage({super.key, this.capture, this.captureSize, this.onExport});

  @override
  State<ExcalidrawPage> createState() => _ExcalidrawPageState();
}

class _ExcalidrawPageState extends State<ExcalidrawPage> {
  // Default document root: a request for /assets/excalidraw/index.html maps to that Flutter asset. (Setting
  // documentRoot:'assets' double-prefixed to assets/assets/… → 404 → blank page.)
  static final InAppLocalhostServer _server = InAppLocalhostServer(port: 8713);
  InAppWebViewController? _web;
  bool _ready = false;
  bool _serverUp = false;
  bool _initialSent = false; // the capture is injected once, whichever trigger wins (ready or load-stop)

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      if (!_server.isRunning()) await _server.start();
    } catch (_) {}
    if (mounted) setState(() => _serverUp = true);
  }

  void _registerBridge(InAppWebViewController c) {
    c.addJavaScriptHandler(handlerName: 'ready', callback: (_) {
      if (mounted) setState(() => _ready = true);
      _sendInitial();
      return true;
    });
    c.addJavaScriptHandler(handlerName: 'exportPng', callback: (args) {
      final b64 = args.isNotEmpty ? args.first as String? : null;
      if (b64 != null && widget.onExport != null) {
        try {
          widget.onExport!(base64Decode(b64));
        } catch (_) {}
      }
      if (mounted) Navigator.of(context).maybePop();
      return true;
    });
    c.addJavaScriptHandler(handlerName: 'error', callback: (args) {
      debugPrint('Excalidraw: ${args.isNotEmpty ? args.first : ''}');
      return true;
    });
  }

  /// Injects the capture once Excalidraw's `window.snapnow` bridge exists, retrying briefly since the WebView's
  /// load-stop can precede the React component mounting.
  Future<void> _sendInitial() async {
    if (_initialSent) return;
    final img = widget.capture, size = widget.captureSize;
    if (img == null || size == null) { _initialSent = true; return; }
    _initialSent = true;
    final dataUrl = 'data:image/png;base64,${base64Encode(img)}';
    final js = "(window.snapnow && window.snapnow.addImage(${jsonEncode(dataUrl)}, "
        "${size.width.round()}, ${size.height.round()})) === true ? 'ok' : 'wait'";
    for (var i = 0; i < 25; i++) {
      final r = await _web?.evaluateJavascript(source: js);
      if (r == 'ok') return;
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 34,
        titleSpacing: 10,
        title: const Text('Excalidraw', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            icon: const Icon(Icons.ios_share, size: 15),
            label: const Text('Send to SnapNow'),
            onPressed: !_ready ? null : () => _web?.evaluateJavascript(source: "window.snapnow && window.snapnow.exportPng()"),
          ),
          IconButton(
            tooltip: 'Close',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Container(
        color: scheme.surface,
        child: !_serverUp
            ? const Center(child: CircularProgressIndicator())
            : InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri('http://localhost:8713/assets/excalidraw/index.html')),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  transparentBackground: true,
                  disableContextMenu: false,
                ),
                onWebViewCreated: (c) {
                  _web = c;
                  _registerBridge(c);
                },
                onLoadStop: (c, url) {
                  _sendInitial(); // inject the capture even if the ready bridge doesn't fire (it retries)
                  // Fallback: if the ready signal doesn't arrive shortly, still allow export (Excalidraw loaded).
                  Future.delayed(const Duration(seconds: 2), () {
                    if (mounted && !_ready) setState(() => _ready = true);
                  });
                },
                onConsoleMessage: (_, msg) => debugPrint('Excalidraw console: ${msg.message}'),
              ),
      ),
    );
  }
}
