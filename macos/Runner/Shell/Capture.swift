import AppKit

enum CaptureMode {
    case region, window, screen
}

extension Notification.Name {
    /// Posted when a file in the captures folder is added or changed.
    static let capturesChanged = Notification.Name("SnapLiteCapturesChanged")
}

enum Capture {
    static let folder: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let url = pictures.appendingPathComponent("SnapNow", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Scratch space for drag-out, sharing and text grabs.
    static let cacheFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("SnapLite", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func isInFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// A free file name, e.g. "SnapNow 2026-10-20 at 14.05.33.png", then "... 2.png".
    static func uniqueURL(in directory: URL = folder, base: String, ext: String = "png") -> URL {
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static func newCaptureURL(prefix: String = "SnapNow", ext: String = "png") -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return uniqueURL(base: "\(prefix) \(f.string(from: Date()))", ext: ext)
    }

    /// Runs /usr/sbin/screencapture; completion gets the new file, or nil if the user pressed Esc.
    /// `cursor` only works for full-screen captures (screencapture -C is non-interactive only).
    /// `delay` (region only, SnapNow's picker): seconds between picking the area and capturing it.
    static func run(_ mode: CaptureMode, to destination: URL? = nil, cursor: Bool = false, windowShadow: Bool = false,
                    sound: Bool = false, delay: Int = 0, systemPicker: Bool = false, completion: @escaping (URL?) -> Void) {
        let url = destination ?? newCaptureURL()
        // SnapNow's own picker (frozen screen, crosshair, magnifier), as in Snagit. It needs Screen Recording
        // permission (the system picker below doesn't); without it, or if the frozen screen comes back blank,
        // the system picker takes over.
        if mode == .region && !systemPicker && CGPreflightScreenCaptureAccess() {
            RegionCapture.start(to: url, sound: sound, delay: delay, completion: completion) {
                run(.region, to: url, cursor: cursor, windowShadow: windowShadow, sound: sound, systemPicker: true, completion: completion)
            }
            return
        }
        var args = sound ? [] : ["-x"]
        if !windowShadow { args.append("-o") }       // window captures (also Space in region mode) without the shadow
        switch mode {
        case .region: args += ["-i"]               // the system picker (Space switches to window picking)
        case .window: args += ["-i", "-w"]         // pick a window
        case .screen: args += ["-D", String(displayUnderMouse())] + (cursor ? ["-C"] : [])
        }
        args.append(url.path)

        // During a screen recording its pill and border step aside: screencapture cannot leave single windows out
        let restoreOverlays = Recorder.shared.hideOverlaysForStill()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { _ in
            let captured = FileManager.default.fileExists(atPath: url.path)
            DispatchQueue.main.async { restoreOverlays(); completion(captured ? url : nil) }
        }
        do {
            try process.run()
        } catch {
            restoreOverlays()
            completion(nil)
        }
    }

    /// screencapture numbers displays from 1, main display first, matching NSScreen.screens.
    private static func displayUnderMouse() -> Int {
        let mouse = NSEvent.mouseLocation
        let index = NSScreen.screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        return index + 1
    }
}
