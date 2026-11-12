import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // FlutterAppDelegate has no applicationDidFinishLaunching of its own, so no super call (it throws).
  override func applicationDidFinishLaunching(_ notification: Notification) {
    Shell.shared.start()   // status item, capture panel, menu, hotkeys
    NSWindow.allowsAutomaticWindowTabbing = false   // no Show Tab Bar / Show All Tabs in the View menu
  }

  // Menu bar app: closing the editor window only hides it.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Dock icon clicked while every window is hidden (e.g. ⌘W in the editor): bring the Library back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { Shell.shared.showLibrary() }
    return true
  }

  // A recording is closed properly before the app goes away (quit, the installer's kill, logout all come here).
  private var quitReplied = false
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard Recorder.shared.isRecording || Recorder.shared.isFinishing else { return super.applicationShouldTerminate(sender) }
    let reply = { [weak self] in
      guard let self, !self.quitReplied else { return }
      self.quitReplied = true
      sender.reply(toApplicationShouldTerminate: true)
    }
    Recorder.shared.stop(reason: .quit, source: "app quit" + (Shell.quitSignal.map { " (\($0))" } ?? " (Quit or the system)"), done: reply)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: reply)   // never hold the quit for longer
    return .terminateLater
  }

  override func applicationWillTerminate(_ notification: Notification) {
    Recorder.shared.finalizeNowIfNeeded()   // whatever else ended the app: close the movie if it is still open
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
