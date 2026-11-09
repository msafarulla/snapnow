import AppKit
import FlutterMacOS
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Vision

/// macOS platform layer for the Flutter UI, on the channel "snaplite/native". Ported from the Swift
/// SnapLite: region selector, screen recorder (red frame + Stop bar), Vision OCR, stored shortcuts,
/// Screen Recording permission. Windows/Linux implement the same channel later.
final class SnapLiteNative {
  static weak var shared: SnapLiteNative?

  private let channel: FlutterMethodChannel
  private let recorder = Recorder()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "snaplite/native", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    TextGrabber.warmUp()
    SnapLiteNative.shared = self
    // Settings › Appearance: tell the Flutter windows (Library, editor) to follow the chosen theme
    NotificationCenter.default.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
      self?.invoke("appearanceChanged", Theme.choice.rawValue)
    }
  }

  /// Native → Dart: "openEditor" (path), "showLibrary", "capturesChanged", "recordingFinished".
  func invoke(_ method: String, _ arguments: Any? = nil) {
    channel.invokeMethod(method, arguments: arguments)
  }

  /// Same, but waits for Dart's answer (draw mode asks whether the drawing was saved before it lifts the glass).
  func invoke(_ method: String, _ arguments: Any? = nil, completion: @escaping (Any?) -> Void) {
    channel.invokeMethod(method, arguments: arguments) { completion($0) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "shell":
      // Dart → the menu bar shell's own flows, so the editor's buttons behave like the hotkeys
      switch args["action"] as? String {
      case "openImage": Shell.shared.openImage()
      case "settings": Shell.shared.showSettings()
      case "endDraw": LiveDraw.shared.endFromEditor()
      case let name?: if let action = ShortcutAction(rawValue: name) { Shell.shared.perform(action) }
      default: break
      }
      result(nil)
    case "glassRects":
      let rects = (args["rects"] as? [[Double]]) ?? []
      LiveDraw.shared.setGlass(rects: rects.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) },
                               radius: CGFloat(rects.first?[4] ?? 14), dark: args["dark"] as? Bool ?? true,
                               useFrost: args["frost"] as? Bool ?? true)
      result(nil)
    case "copyText":
      Shell.copyText(args["text"] as? String ?? "")
      result(nil)
    case "toast":
      Toast.show(args["message"] as? String ?? "", symbol: args["symbol"] as? String ?? "checkmark.circle.fill")
      result(nil)
    case "toolbarTools":
      result(UserDefaults.standard.array(forKey: "toolbarTools") as? [Int])
    case "thumbnail":
      // Quick Look thumbnail (images and movies alike) as PNG bytes
      let url = URL(fileURLWithPath: args["path"] as? String ?? "")
      let size = args["size"] as? Double ?? 180
      let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size * 0.75),
                                                 scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
        let png = rep.flatMap { NSBitmapImageRep(cgImage: $0.cgImage).representation(using: .png, properties: [:]) }
        DispatchQueue.main.async { result(png.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    case "trash":
      let urls = (args["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
      NSWorkspace.shared.recycle(urls) { _, _ in DispatchQueue.main.async { result(nil) } }
    case "copyFiles":
      // One image: the picture plus its file; several (or movies): the files
      let urls = (args["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      if urls.count == 1, urls[0].pathExtension.lowercased() != "mov", let image = NSImage(contentsOf: urls[0]) {
        pasteboard.writeObjects([image, urls[0] as NSURL])
      } else {
        pasteboard.writeObjects(urls as [NSURL])
      }
      Toast.show(urls.count == 1 ? "Copied" : "Copied \(urls.count) items")
      result(nil)
    case "copyGif":
      // The GIF bytes for apps that paste image data, plus the file for apps that paste files
      // (Messages, Slack, Mail, Finder), which is what keeps it animated there
      guard let path = args["path"] as? String, let data = FileManager.default.contents(atPath: path) else {
        result(FlutterError(code: "copyGif", message: "No GIF at path", details: nil))
        return
      }
      let item = NSPasteboardItem()
      item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
      item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([item])
      result(nil)
    case "share":
      // The system share menu under the editor's Share button; Flutter sends the button's rect with a
      // top-left origin, so flip it unless the Flutter view already is
      guard let path = args["path"] as? String,
            let view = NSApp.windows.first(where: { $0 is MainFlutterWindow })?.contentView else { result(nil); return }
      let x = args["x"] as? Double ?? 0, y = args["y"] as? Double ?? 0
      let w = args["w"] as? Double ?? 1, h = args["h"] as? Double ?? 1
      let rect = NSRect(x: x, y: view.isFlipped ? y : view.bounds.height - y - h, width: w, height: h)
      NSSharingServicePicker(items: [URL(fileURLWithPath: path)]).show(relativeTo: rect, of: view,
                                                                         preferredEdge: view.isFlipped ? .maxY : .minY) // below
      result(nil)
    case "copySticker":
      guard let png = (args["png"] as? FlutterStandardTypedData)?.data else { result(nil); return }
      Sticker.copy(png: png, name: args["name"] as? String ?? "SnapNow", result: result)
    case "addWhatsAppSticker":
      guard let frames = (args["frames"] as? FlutterStandardTypedData)?.data,
            let durations = args["durations"] as? [Int] else { result(nil); return }
      WhatsAppPack.add(frames: frames, durations: durations, result: result)
    case "copyTextOfFile":
      guard let path = args["path"] as? String, let data = FileManager.default.contents(atPath: path),
            let src = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
        result(nil); return
      }
      Toast.show("Reading text…", symbol: "text.viewfinder")
      TextGrabber.recognize(image) { Shell.copyText($0); result(nil) }
    case "exportGIF":
      Toast.show("Making GIF…", symbol: "hourglass")
      GIFExporter.export(URL(fileURLWithPath: args["path"] as? String ?? "")) { [weak self] gif in
        if gif != nil {
          Toast.show("GIF saved to the library")
          self?.invoke("capturesChanged")
        } else {
          Toast.show("Could not make a GIF", symbol: "exclamationmark.triangle.fill")
        }
        result(gif?.path)
      }
    case "storedShortcuts":
      // The Swift app stored each as JSON Data {keyCode, modifiers} (Carbon codes); same bundle id, same defaults.
      var out: [String: String] = [:]
      for action in ["region", "window", "screen", "text", "record", "library"] {
        if let data = UserDefaults.standard.data(forKey: "shortcut.\(action)"), let s = String(data: data, encoding: .utf8) {
          out[action] = s
        }
      }
      result(out)
    case "setShortcut":
      let key = "shortcut.\(args["action"] as? String ?? "")"
      if let json = args["json"] as? String { UserDefaults.standard.set(json.data(using: .utf8), forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
      result(nil)
    case "getDataString":
      let key = args["key"] as? String ?? ""
      if let data = UserDefaults.standard.data(forKey: key) { result(String(data: data, encoding: .utf8)) }
      else { result(UserDefaults.standard.string(forKey: key)) }
    case "setDataString":
      UserDefaults.standard.set((args["json"] as? String ?? "").data(using: .utf8), forKey: args["key"] as? String ?? "")
      result(nil)
    case "getString":
      result(UserDefaults.standard.string(forKey: args["key"] as? String ?? ""))
    case "setString":
      UserDefaults.standard.set(args["value"] as? String, forKey: args["key"] as? String ?? "")
      result(nil)
    case "showColorPanel":
      let rgb = args["color"] as? Int ?? 0xE8332A
      let panel = NSColorPanel.shared
      panel.setTarget(self)
      panel.setAction(#selector(colorPanelChanged(_:)))
      panel.isContinuous = true
      panel.color = NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
      panel.orderFront(nil)
      result(nil)
    case "getBool":
      let key = args["key"] as? String ?? ""
      result(UserDefaults.standard.object(forKey: key) == nil ? nil : UserDefaults.standard.bool(forKey: key))
    case "setBool":
      UserDefaults.standard.set(args["value"] as? Bool ?? false, forKey: args["key"] as? String ?? "")
      result(nil)
    case "screenAccess":
      result(CGPreflightScreenCaptureAccess())
    case "requestScreenAccess":
      let granted = CGRequestScreenCaptureAccess()
      if !granted { PermissionGuide.shared.show() }
      result(granted)
    case "selectRegion":
      RegionSelector.select(hint: args["hint"] as? String ?? "Drag to select an area · Esc to cancel") { rect in
        result(rect.map { [$0.minX, $0.minY, $0.width, $0.height] })
      }
    case "startRecording":
      // Pick the area first, then record it; the movie path arrives later via "recordingFinished".
      RegionSelector.select(hint: "Drag the area to record · click for the whole screen · Esc to cancel") { [weak self] rect in
        guard let self, let rect else { result("cancelled"); return }
        let started = self.recorder.start(rect: rect, microphone: args["microphone"] as? Bool ?? false,
                                          showClicks: args["showClicks"] as? Bool ?? true) { [weak self] url in
          self?.channel.invokeMethod("recordingFinished", arguments: url?.path)
        }
        result(started ? "started" : "failed")
      }
    case "stopRecording":
      recorder.stop()
      result(nil)
    case "isRecording":
      result(recorder.isRecording)
    case "ocr":
      guard let path = args["path"] as? String, let data = FileManager.default.contents(atPath: path),
            let src = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
        result(""); return
      }
      TextGrabber.recognize(image) { result($0) }
    case "imageDensity":
      guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args["path"] as? String ?? "") as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 else { result(nil); return }
      result(max(1, (dpi / 72).rounded()))
    case "saveAs":
      guard let png = (args["png"] as? FlutterStandardTypedData)?.data else { result(nil); return }
      SaveAs.run(png: png, name: args["name"] as? String ?? "SnapNow",
                 density: args["density"] as? Double ?? 1, result: result)
    case "openUrl":
      if let url = URL(string: args["url"] as? String ?? ""), ["https", "http"].contains(url.scheme) { NSWorkspace.shared.open(url) }
      result(nil)
    case "reveal":
      if let path = args["path"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
      result(nil)
    case "openPath":
      if let path = args["path"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
      result(nil)
    case "activate":
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    case "displayUnderMouse":
      // screencapture -D numbers displays from 1 in NSScreen.screens order
      let mouse = NSEvent.mouseLocation
      result((NSScreen.screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0) + 1)
    case "screenVisibleSize":
      // Visible frame (points, below the menu bar and above the Dock) of the display under the mouse,
      // so the editor/library window can be sized to the screen it opens on (14" vs 16" Macs).
      let mouse = NSEvent.mouseLocation
      let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
      result([Double(screen.visibleFrame.width), Double(screen.visibleFrame.height)])
    case "beep":
      NSSound.beep()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

extension SnapLiteNative {
  @objc func colorPanelChanged(_ sender: NSColorPanel) {
    guard let c = sender.color.usingColorSpace(.sRGB) else { return }
    func byte(_ v: CGFloat) -> Int { Int(max(0, min(255, (v * 255).rounded()))) }
    invoke("colorPicked", byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent))
  }
}

// MARK: - Save As (format menu)

/// Save panel with a Format menu: re-encodes the flattened PNG as PNG, JPEG, HEIC, TIFF, PDF, GIF or BMP.
/// Result: the saved path, nil when cancelled, or a FlutterError when writing fails.
enum SaveAs {
  struct Format { let name: String; let type: UTType; let opaque: Bool }

  private static let all = [
    Format(name: "PNG", type: .png, opaque: false),
    Format(name: "JPEG", type: .jpeg, opaque: true),
    Format(name: "HEIC", type: .heic, opaque: false),
    Format(name: "TIFF", type: .tiff, opaque: false),
    Format(name: "PDF", type: .pdf, opaque: false),
    Format(name: "GIF", type: .gif, opaque: false),
    Format(name: "BMP", type: .bmp, opaque: true),
  ]
  private static let lastKey = "saveAs.format"

  /// ImageIO encoders vary by macOS version, so only offer what this Mac can write; PDF is drawn directly.
  static var available: [Format] {
    let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    return all.filter { $0.type == .pdf || writable.contains($0.type.identifier) }
  }

  static func run(png: Data, name: String, density: Double, result: @escaping FlutterResult) {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
      result(FlutterError(code: "decode", message: "Couldn't read the image", details: nil)); return
    }
    let formats = available
    let panel = NSSavePanel()
    panel.title = "Save As"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = name
    // Settings › Save As format when it's set and still writable here, else the last one used
    let chosen = UserDefaults.standard.string(forKey: Prefs.saveAsFormat).flatMap { name in
      formats.contains { $0.name == name } ? name : nil
    }
    let picker = FormatPicker(panel: panel, formats: formats,
                              selected: chosen ?? UserDefaults.standard.string(forKey: lastKey))
    let done: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { result(nil); return }
      let format = picker.format
      do {
        try write(image, as: format, to: url, density: density)
        UserDefaults.standard.set(format.name, forKey: lastKey)
        result(url.path)
      } catch {
        result(FlutterError(code: "write", message: "Couldn't save as \(format.name)", details: "\(error)"))
      }
    }
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: done)
    } else {
      panel.begin(completionHandler: done)
    }
  }

  struct WriteError: Error { let reason: String }

  static func write(_ image: CGImage, as format: Format, to url: URL, density: Double) throws {
    let scale = max(1, density)
    if format.type == .pdf {
      // one page at the capture's point size, so a Retina capture prints at its on-screen size
      var box = CGRect(x: 0, y: 0, width: Double(image.width) / scale, height: Double(image.height) / scale)
      guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw WriteError(reason: "pdf context") }
      pdf.beginPDFPage(nil)
      pdf.interpolationQuality = .high
      pdf.draw(image, in: box)
      pdf.endPDFPage()
      pdf.closePDF()
      return
    }
    let pixels = format.opaque ? (onWhite(image) ?? image) : image
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
      throw WriteError(reason: "no encoder for \(format.type.identifier)")
    }
    var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
    if format.type == .jpeg || format.type == .heic { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
    CGImageDestinationAddImage(dest, pixels, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw WriteError(reason: "finalize failed") }
  }

  /// JPEG and BMP have no alpha: transparent canvas space becomes white instead of black.
  private static func onWhite(_ image: CGImage) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.setFillColor(.white)
    ctx.fill(rect)
    ctx.draw(image, in: rect)
    return ctx.makeImage()
  }
}

/// The panel's "Format:" accessory; switching formats swaps the file name's extension.
private final class FormatPicker: NSObject {
  private let panel: NSSavePanel
  private let formats: [SaveAs.Format]
  private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

  init(panel: NSSavePanel, formats: [SaveAs.Format], selected: String?) {
    self.panel = panel
    self.formats = formats
    super.init()
    popup.addItems(withTitles: formats.map(\.name))
    popup.selectItem(at: formats.firstIndex { $0.name == selected } ?? 0)
    popup.target = self
    popup.action = #selector(changed)
    let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
    row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    panel.accessoryView = row
    changed()
  }

  var format: SaveAs.Format { formats[max(0, popup.indexOfSelectedItem)] }

  @objc private func changed() {
    panel.allowedContentTypes = [format.type]
    let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
    panel.nameFieldStringValue = "\(base).\(format.type.preferredFilenameExtension ?? format.name.lowercased())"
  }
}

/// ⌃⌘C: the finished image as a WhatsApp sticker, a 512×512 WebP with a transparent margin, at most
/// 100 KB. WhatsApp pastes it as a sticker when the clipboard has the WebP data and the file.
/// (A pasted animated WebP shows only its first frame, so animated stickers go through WhatsAppPack.)
enum Sticker {
  static let side = 512, maxBytes = 100_000

  static func copy(png: Data, name: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let webp = encode(png: png)
      DispatchQueue.main.async {
        guard let webp else {
          result(FlutterError(code: "sticker", message: "Couldn't make the sticker", details: nil)); return
        }
        do {
          let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnapNow Stickers")
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          let url = dir.appendingPathComponent(name).appendingPathExtension("webp")
          try webp.write(to: url)
          let item = NSPasteboardItem()
          item.setData(webp, forType: NSPasteboard.PasteboardType("org.webmproject.webp"))
          item.setString(url.absoluteString, forType: .fileURL)
          NSPasteboard.general.clearContents()
          NSPasteboard.general.writeObjects([item])
          result(url.path)
        } catch {
          result(FlutterError(code: "sticker", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// Lowers the quality first, then the picture's size, until it fits; nil if even the smallest try doesn't.
  static func encode(png: Data) -> Data? {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    for fill in [1.0, 0.8, 0.6] {
      guard var rgba = pixels(image, fill: fill) else { return nil }
      for quality: Float in [85, 75, 65, 55, 45] {
        if let data = webp(&rgba, quality: quality), data.count <= maxBytes { return data }
      }
    }
    return nil
  }

  /// The image fitted inside the square (16 px margin at full fill), as straight (unpremultiplied) RGBA.
  static func pixels(_ image: CGImage, fill: Double) -> [UInt8]? {
    var rgba = [UInt8](repeating: 0, count: side * side * 4)
    let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
      guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      let box = (Double(side) - 32) * fill
      let scale = min(box / Double(image.width), box / Double(image.height))
      let w = Double(image.width) * scale, h = Double(image.height) * scale
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
      return true
    }
    guard ok else { return nil }
    for i in stride(from: 0, to: rgba.count, by: 4) {
      let a = Int(rgba[i + 3])
      guard a > 0, a < 255 else { continue }
      for c in 0..<3 { rgba[i + c] = UInt8(min(255, Int(rgba[i + c]) * 255 / a)) }
    }
    return rgba
  }

  static func webp(_ rgba: inout [UInt8], quality: Float) -> Data? {
    var out: UnsafeMutablePointer<UInt8>?
    let size = WebPEncodeRGBA(&rgba, Int32(side), Int32(side), Int32(side * 4), quality, &out)
    guard size > 0, let out else { return nil }
    defer { WebPFree(out) }
    return Data(bytes: out, count: size)
  }
}

/// ⌃⌘C with markup: the build-up animation as an animated WhatsApp sticker. WhatsApp keeps pasted or
/// dropped stickers still and animates only stickers from installed packs, so SnapLite keeps one pack
/// (its newest 30 stickers) and hands the whole pack over the way sticker apps do: JSON on the
/// pasteboard, then whatsapp://stickerPack. Sending the same identifier again updates the pack.
enum WhatsAppPack {
  static let identifier = "com.mm.snaplite.stickers", keep = 30, minimum = 3, maxBytes = 490_000
  static let handOff = URL(string: "whatsapp://stickerPack")!
  static let pasteboardType = NSPasteboard.PasteboardType("net.whatsapp.third-party.sticker-pack")
  static var folder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SnapLite/WhatsApp Stickers")
  }

  /// frames: 512×512 straight RGBA frames back to back; durations in ms, one per frame.
  static func add(frames: Data, durations: [Int], result: @escaping FlutterResult) {
    func fail(_ message: String) { result(FlutterError(code: "whatsapp", message: message, details: nil)) }
    guard NSWorkspace.shared.urlForApplication(toOpen: handOff) != nil else { return fail("WhatsApp isn't installed") }
    let frameBytes = Sticker.side * Sticker.side * 4
    guard !durations.isEmpty, frames.count == frameBytes * durations.count else { return fail("Couldn't make the sticker") }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let json = try store(frames: frames, durations: durations)
        DispatchQueue.main.async { handOver(json); result(nil) }
      } catch {
        DispatchQueue.main.async { fail(error.localizedDescription) }
      }
    }
  }

  /// Saves the new sticker, keeps the pack within WhatsApp's 3–30, and returns the pack's JSON.
  /// Until there are 3 real stickers the pack is filled with copies of the newest (pad-*), removed as real ones arrive.
  static func store(frames: Data, durations: [Int]) throws -> Data {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    var quality: Float = 75
    var webp: Data?
    for q: Float in [75, 60, 45, 30] {
      quality = q
      if let data = animated(frames, durations, quality: q), data.count <= maxBytes { webp = data; break }
    }
    guard let webp else { throw NSError(domain: "whatsapp", code: 1, userInfo: [NSLocalizedDescriptionKey: "The animation is too big for a sticker"]) }
    let stamp = Int(Date().timeIntervalSince1970 * 1000)
    try webp.write(to: folder.appendingPathComponent("\(stamp).webp"))

    let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "webp" }
    files.filter { $0.lastPathComponent.hasPrefix("pad-") }.forEach { try? fm.removeItem(at: $0) }
    var real = files.filter { !$0.lastPathComponent.hasPrefix("pad-") }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    real.dropFirst(keep).forEach { try? fm.removeItem(at: $0) }
    real = Array(real.prefix(keep))
    var pads: [URL] = []
    for i in 0..<max(0, minimum - real.count) {
      // A slightly different encoding, so WhatsApp doesn't see the same file twice
      guard let copy = animated(frames, durations, quality: max(10, quality - Float(5 * (i + 1)))) else { continue }
      let url = folder.appendingPathComponent("pad-\(stamp)-\(i).webp")
      try copy.write(to: url)
      pads.append(url)
    }

    let stickers: [[String: Any]] = try (real + pads).map {
      ["image_data": try Data(contentsOf: $0).base64EncodedString(), "emojis": ["👉"]]
    }
    let lastFrame = frames.suffix(Sticker.side * Sticker.side * 4)
    let pack: [String: Any] = [
      "identifier": identifier, "name": "SnapNow", "publisher": "SnapNow",
      "tray_image": tray(from: Data(lastFrame))?.base64EncodedString() ?? "",
      "animated_sticker_pack": true, "ios_app_store_link": "", "android_play_store_link": "",
      "stickers": stickers,
    ]
    return try JSONSerialization.data(withJSONObject: pack)
  }

  /// Puts the pack on the pasteboard and opens WhatsApp, which reads it from there. Whatever was copied
  /// before comes back a minute later, unless something new has been copied meanwhile.
  static func handOver(_ json: Data) {
    let pb = NSPasteboard.general
    let saved = (pb.pasteboardItems ?? []).map { item in
      item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
    }
    pb.clearContents()
    pb.setData(json, forType: pasteboardType)
    let ours = pb.changeCount
    NSWorkspace.shared.open(handOff)
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
      guard pb.changeCount == ours else { return }
      pb.clearContents()
      if saved.isEmpty { return }
      pb.writeObjects(saved.map { types in
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: type) }
        return item
      })
    }
  }

  static func animated(_ frames: Data, _ durations: [Int], quality: Float) -> Data? {
    let side = Int32(Sticker.side), frameBytes = Sticker.side * Sticker.side * 4
    var options = WebPAnimEncoderOptions()
    guard WebPAnimEncoderOptionsInit(&options) != 0 else { return nil }
    options.anim_params.loop_count = 0
    guard let encoder = WebPAnimEncoderNew(side, side, &options) else { return nil }
    defer { WebPAnimEncoderDelete(encoder) }
    var config = WebPConfig()
    guard WebPConfigInit(&config) != 0 else { return nil }
    config.quality = quality
    config.method = 4
    var time: Int32 = 0
    let ok = frames.withUnsafeBytes { raw -> Bool in
      for (i, ms) in durations.enumerated() {
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { return false }
        picture.width = side
        picture.height = side
        picture.use_argb = 1
        let pixels = raw.baseAddress!.advanced(by: i * frameBytes).assumingMemoryBound(to: UInt8.self)
        defer { WebPPictureFree(&picture) }
        guard WebPPictureImportRGBA(&picture, pixels, side * 4) != 0,
              WebPAnimEncoderAdd(encoder, &picture, time, &config) != 0 else { return false }
        time += Int32(ms)
      }
      return WebPAnimEncoderAdd(encoder, nil, time, nil) != 0
    }
    guard ok else { return nil }
    var data = WebPData()
    WebPDataInit(&data)
    defer { WebPDataClear(&data) }
    guard WebPAnimEncoderAssemble(encoder, &data) != 0, let bytes = data.bytes else { return nil }
    return Data(bytes: bytes, count: data.size)
  }

  /// The pack's icon in WhatsApp: the finished picture, 96×96 PNG.
  static func tray(from rgba: Data) -> Data? {
    let side = Sticker.side
    guard let provider = CGDataProvider(data: rgba as CFData),
          let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
          let ctx = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
    guard let small = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, small, nil)
    return CGImageDestinationFinalize(dst) ? out as Data : nil
  }
}

// MARK: - Shared helpers

enum CaptureFiles {
  static let folder: URL = {
    let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
    let url = pictures.appendingPathComponent("SnapNow", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  /// The app used to be called SnapLite: its ~/Pictures/SnapLite is moved to ~/Pictures/SnapNow once. Runs only
  /// here, before the Flutter engine starts; if SnapNow already holds files, SnapLite is left as it is.
  static func migrateOldFolder() {
    let fm = FileManager.default
    let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
    let old = pictures.appendingPathComponent("SnapLite", isDirectory: true)
    let new = pictures.appendingPathComponent("SnapNow", isDirectory: true)
    guard fm.fileExists(atPath: old.path) else { return }
    if let items = try? fm.contentsOfDirectory(atPath: new.path) {
      guard items.allSatisfy({ $0.hasPrefix(".") }) else { return }
      try? fm.removeItem(at: new)
    }
    do { try fm.moveItem(at: old, to: new) } catch { NSLog("SnapNow: could not move %@: %@", old.path, "\(error)") }
  }

  /// A free file name, e.g. "SnapNow 2026-10-20 at 14.05.33.png", then "... 2.png".
  static func newCaptureURL(prefix: String = "SnapNow", ext: String = "png") -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let base = "\(prefix) \(f.string(from: Date()))"
    var url = folder.appendingPathComponent("\(base).\(ext)")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(base) \(n).\(ext)")
      n += 1
    }
    return url
  }
}

private enum Look {
  static let dim = NSColor(white: 0.08, alpha: 1)
  static let accent = NSColor.controlAccentColor
  static let surface = NSColor(white: 0.12, alpha: 1)
  static let border = NSColor(white: 1, alpha: 0.18)
  static let text = NSColor.white
  static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .medium) }
}

private extension CGRect {
  init(corner a: CGPoint, _ b: CGPoint) {
    self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }
}

// MARK: - Region selector

/// Full-screen overlays for dragging out a rectangle, in Cocoa global coordinates.
/// A click without a drag picks that whole screen; Esc cancels.
final class RegionSelector {
  private static var current: RegionSelector?   // keeps the overlays alive while open

  private var windows: [NSWindow] = []
  private var completion: ((CGRect?) -> Void)?

  static func select(hint: String, completion: @escaping (CGRect?) -> Void) {
    current?.finish(nil)
    let selector = RegionSelector()
    selector.completion = completion
    current = selector

    let mouse = NSEvent.mouseLocation
    for screen in NSScreen.screens {
      let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.level = .screenSaver
      window.isOpaque = false
      window.backgroundColor = .clear
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
      view.screenFrame = screen.frame
      view.hint = hint
      view.onFinish = { [weak selector] rect in selector?.finish(rect) }
      window.contentView = view
      window.setFrame(screen.frame, display: true)
      window.orderFrontRegardless()
      if NSMouseInRect(mouse, screen.frame, false) {
        window.makeKey()
      }
      window.makeFirstResponder(view)
      selector.windows.append(window)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  private func finish(_ rect: CGRect?) {
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    let done = completion
    completion = nil
    if RegionSelector.current === self { RegionSelector.current = nil }
    done?(rect)
  }
}

private final class OverlayWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
  var screenFrame = CGRect.zero
  var hint = ""
  var onFinish: ((CGRect?) -> Void)?
  private var start: CGPoint?
  private var current: CGPoint?

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var selection: CGRect? {
    guard let a = start, let b = current else { return nil }
    return CGRect(corner: a, b)
  }

  override func draw(_ dirtyRect: NSRect) {
    let dim = NSBezierPath(rect: bounds)
    if let r = selection { dim.appendRect(r) }
    dim.windingRule = .evenOdd
    Look.dim.withAlphaComponent(0.45).setFill()
    dim.fill()

    if let r = selection {
      let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
      border.lineWidth = 1.5
      Look.accent.setStroke()
      border.stroke()
      label("\(Int(r.width)) × \(Int(r.height))", at: CGPoint(x: r.minX, y: max(r.minY - 26, 4)))
    } else {
      let attributes: [NSAttributedString.Key: Any] = [.font: Look.font(15)]
      let width = (hint as NSString).size(withAttributes: attributes).width
      label(hint, at: CGPoint(x: bounds.midX - width / 2 - 10, y: bounds.maxY - 120), fontSize: 15)
    }
  }

  private func label(_ text: String, at point: CGPoint, fontSize: CGFloat = 12) {
    let attributes: [NSAttributedString.Key: Any] = [.font: Look.font(fontSize), .foregroundColor: Look.text]
    let size = (text as NSString).size(withAttributes: attributes)
    let box = CGRect(x: point.x, y: point.y, width: size.width + 20, height: size.height + 8)
    Look.surface.withAlphaComponent(0.92).setFill()
    let pill = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
    pill.fill()
    Look.border.setStroke()
    pill.stroke()
    (text as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 4), withAttributes: attributes)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func mouseDown(with event: NSEvent) {
    start = convert(event.locationInWindow, from: nil)
    current = start
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    current = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let r = selection else { return }
    if r.width < 4 || r.height < 4 {
      onFinish?(screenFrame)
    } else {
      onFinish?(r.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
  }
}

// MARK: - Recorder

/// Screen recording through `screencapture -v`. It records until it gets SIGINT, which also
/// finalizes the movie (writing to its stdin does not stop it).
final class Recorder {
  private var process: Process?
  private var frame: NSWindow?
  private var controls: NSPanel?
  private var controlsTimer: Timer?
  private(set) var startedAt: Date?

  var isRecording: Bool { process != nil }

  /// `rect` is in Cocoa global coordinates. Completion gets the movie, or nil if nothing was written.
  func start(rect: CGRect, microphone: Bool, showClicks: Bool = true, completion: @escaping (URL?) -> Void) -> Bool {
    guard process == nil else { return false }
    let url = CaptureFiles.newCaptureURL(prefix: "SnapNow Recording", ext: "mov")

    // screencapture -R takes points from the top-left of the main display
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    let r = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height).integral
    var args = ["-x", "-v", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
    if showClicks { args.append("-k") }
    if microphone { args.append("-g") }
    args.append(url.path)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = args
    p.standardInput = Pipe()
    p.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async {
        self?.process = nil
        self?.startedAt = nil
        self?.frame?.orderOut(nil)
        self?.frame = nil
        self?.hideControls()
        completion(FileManager.default.fileExists(atPath: url.path) ? url : nil)
      }
    }
    do {
      try p.run()
    } catch {
      return false
    }
    process = p
    startedAt = Date()
    showFrame(around: rect)
    showControls(near: rect)
    return true
  }

  func stop() {
    process?.interrupt()
  }

  /// A small bar with the elapsed time and a "Stop Recording" button, just outside the recorded area
  /// when there is room (macOS's own menu bar indicator only offers "Stop Sharing").
  private func showControls(near rect: CGRect) {
    let size = NSSize(width: 214, height: 36)
    let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)   // below
    if origin.y < visible.minY { origin.y = rect.maxY + 10 }                              // else above
    if origin.y + size.height > visible.maxY { origin.y = visible.minY + 16 }             // else bottom of screen
    origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)

    let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .statusBar
    panel.hasShadow = true
    panel.sharingType = .none   // keep it out of the recording where macOS honors this
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

    let background = NSView()
    background.wantsLayer = true
    background.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
    background.layer?.cornerRadius = 10
    let time = NSTextField(labelWithString: "0:00")
    time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    time.textColor = .white
    let dot = NSImageView(image: NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!)
    dot.contentTintColor = .systemRed
    // Drawn by hand: a standard button looks disabled here, since the bar never becomes key
    let stop = StopButton(title: "Stop Recording", target: self, action: #selector(stopClicked))
    stop.isBordered = false
    stop.wantsLayer = true
    stop.layer?.backgroundColor = NSColor.systemRed.cgColor
    stop.layer?.cornerRadius = 7
    stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
    stop.imagePosition = .imageLeading
    stop.contentTintColor = .white
    stop.attributedTitle = NSAttributedString(string: " Stop Recording ",
                                              attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
    stop.heightAnchor.constraint(equalToConstant: 26).isActive = true
    stop.widthAnchor.constraint(equalToConstant: 136).isActive = true
    let stack = NSStackView(views: [dot, time, stop])
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
    stack.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
    ])
    panel.contentView = background
    panel.orderFrontRegardless()
    controls = panel

    controlsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let start = self?.startedAt else { return }
      let seconds = Int(Date().timeIntervalSince(start))
      time.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
  }

  @objc private func stopClicked() {
    stop()
  }

  private func hideControls() {
    controlsTimer?.invalidate()
    controlsTimer = nil
    controls?.orderOut(nil)
    controls = nil
  }

  /// A red border just outside the recorded area; it is click-through and not in the recording.
  private func showFrame(around rect: CGRect) {
    let inset: CGFloat = 3
    let window = NSWindow(contentRect: rect.insetBy(dx: -inset, dy: -inset), styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.ignoresMouseEvents = true
    window.sharingType = .none
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    window.contentView = FrameView(inset: inset)
    window.orderFrontRegardless()
    frame = window
  }
}

/// The Stop bar is never key, so its button must take the first click.
private final class StopButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FrameView: NSView {
  private let inset: CGFloat

  init(inset: CGFloat) {
    self.inset = inset
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(rect: bounds.insetBy(dx: inset / 2, dy: inset / 2))
    path.lineWidth = inset - 1
    NSColor.systemRed.setStroke()
    path.stroke()
  }
}

// MARK: - OCR

/// On-device OCR. Words on the same row are joined with tabs, so grids paste into a spreadsheet as cells.
enum TextGrabber {
  static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      // Transparent margins made Vision find nothing on a whole wide capture, so read the image on
      // solid white; if that still finds nothing, try once at twice the size.
      var text = read(onWhite(image, scale: 1))
      if text.isEmpty, max(image.width, image.height) <= 4000 { text = read(onWhite(image, scale: 2)) }
      DispatchQueue.main.async { completion(text) }
    }
  }

  private static func read(_ image: CGImage?) -> String {
    guard let image else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do {
      try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
      return ""
    }
    return arrange(request.results ?? [])
  }

  private static func onWhite(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
  }

  /// The first recognition in a process loads Vision's model and takes ~15 s; do that at launch.
  static func warmUp() {
    let image = NSImage(size: NSSize(width: 240, height: 48), flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      ("SnapLite warm up 123" as NSString).draw(at: NSPoint(x: 8, y: 12),
                                               withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
      return true
    }
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    recognize(cg) { _ in }
  }

  private static func arrange(_ observations: [VNRecognizedTextObservation]) -> String {
    let pieces = observations.compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
      .sorted { $0.box.midY > $1.box.midY }
    var rows: [[(box: CGRect, text: String)]] = []
    for piece in pieces {
      if let last = rows.last?.last, abs(last.box.midY - piece.box.midY) < min(last.box.height, piece.box.height) * 0.5 {
        rows[rows.count - 1].append(piece)
      } else {
        rows.append([piece])
      }
    }
    return rows
      .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "\t") }
      .joined(separator: "\n")
  }
}
