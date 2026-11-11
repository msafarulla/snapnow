import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var native: SnapLiteNative?

  /// Draw mode (double-tap Option) makes this a borderless, display-sized overlay: it must be allowed to take
  /// the keyboard and to sit over the menu bar and Dock, which AppKit would otherwise squeeze it below.
  var drawMode = false
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    drawMode ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }

  override func awakeFromNib() {
    CaptureFiles.migrateOldFolder()   // before Flutter or the shell touch the captures folder
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    native = SnapLiteNative(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()

    // Clicking a full-screen app leaves an accessory app's window floating in that app's Space (it can't go
    // behind), so the editor steps aside instead: off screen but still open, in ⌘-Tab and the Dock, and back
    // as it was when SnapNow is switched to again. Not when pinned (on top on purpose).
    NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      // Checked a few times as the other app comes forward, so it hides as soon as that's clear
      for delay in [0.03, 0.1, 0.2, 0.4] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.hideIfFloatingOverFullScreenApp() }
      }
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      if DockPresence.shared.parked { self?.makeKeyAndOrderFront(nil) }
    }
  }

  /// Still the top window although a full-screen app is now active: we're stuck over it.
  private func hideIfFloatingOverFullScreenApp() {
    guard isVisible, level == .normal, !NSApp.isActive,
          let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
          let screen = screen?.frame else { return }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let normal = windows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    guard (normal.first?[kCGWindowNumber as String] as? Int) == windowNumber else { return }
    let fullScreen = normal.contains { w in
      guard (w[kCGWindowOwnerPID as String] as? pid_t) == front,
            let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return false }
      return r.width >= screen.width && r.height >= screen.height * 0.85
    }
    if fullScreen {
      DockPresence.shared.parked = true   // still counts as open, so SnapNow stays in ⌘-Tab
      orderOut(nil)
    }
  }

  // Menu bar app: the editor window starts hidden (window_manager's pattern, so the engine still starts).
  private var launched = false

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    // Show as a regular app: an accessory (menu bar) app's window opens inside a full-screen app's Space and
    // floats over it, so clicking the full-screen app couldn't send the editor behind. Not at launch, where
    // the window is ordered once and hidden straight away.
    if place != .out { DockPresence.shared.parked = false }
    // Not in draw mode: the glass has to be able to sit on another app's full-screen Space (see LiveDraw.enter)
    if launched && place != .out && !isVisible && !drawMode { DockPresence.shared.becomeRegular() }
    launched = true
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
    DockPresence.shared.update()   // show/hide don't post a notification of their own
  }
}


/// A menu bar app (LSUIElement) has no Dock icon, so an open editor couldn't be found with ⌘-Tab or
/// the Dock and sat over everything. While any normal window (editor, library, settings) is open or
/// minimized SnapLite becomes a regular app; when the last one goes away it's menu-bar only again.
final class DockPresence {
    static let shared = DockPresence()

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in self.update() }
        }
    }

    /// The editor stepped aside from a full-screen app's Space: hidden, but still open.
    var parked = false

    /// Right away, before a window is shown (update() would only catch up after it's on screen).
    func becomeRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// Deferred one turn so a closing or hiding window has left the screen before it's counted.
    func update() {
        DispatchQueue.main.async {
            // While draw mode is up SnapNow stays a menu bar app (see LiveDraw.enter)
            let open = !LiveDraw.shared.active && (self.parked || NSApp.windows.contains { w in
                w.styleMask.contains(.titled) && !(w is NSPanel) && (w.level == .normal || w.level == .floating) // floating = pinned
                    && (w.isVisible || w.isMiniaturized)
            })
            let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory
            if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
        }
    }
}
