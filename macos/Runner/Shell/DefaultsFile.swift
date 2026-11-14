import CryptoKit
import Foundation

/// Settings › Defaults, the part with no AppKit in it (tools/publish_defaults_test compiles this file alone): the shared
/// file's format, what goes into it and how it is applied. One Mac publishes its settings (every key in
/// PublishDefaults.settings that is not in PublishDefaults.excluded) to snapnow-defaults.json in a folder every Mac can
/// reach; the others apply it.
///
/// File (format 1):
/// {"format": 1, "publishedAt": "2026-11-14T09:41:00Z", "publishId": "<UUID>", "mac": "<computer name>",
///  "installId": "<UUID of the publishing app install>", "appVersion": "1.83.0+273", "values": {"<key>": <value or null>, ...}}
/// A value is kept in the file in its JSON form: true/false, a string, a number, a list of integers, or (for keys stored as
/// JSON data) the JSON object or array itself. A folder or file setting inside the home folder goes as "~/<path in the
/// home>" and is expanded on the receiving Mac; one outside the home is not published. null = the key was never set on the
/// publishing Mac (the receiver goes back to the built-in default); a key missing from "values" (an older app that did not
/// know it, a path outside the home) leaves the receiver's own value alone.
/// Since 1.84.0 two optional members make a path setting the same everywhere: "folders": ["<key>", ...] names the path
/// settings that are folders (a receiver without that folder creates it), and "assets": {"<key>": "<sha256>.<ext>"} names
/// the copy, in the shared folder's "assets" subfolder, of the file a path setting points to (a receiver without that file
/// copies it into place). An older app ignores both and keeps skipping such a path.
enum DefaultsFile {
    static let name = "snapnow-defaults.json"
    /// Bump only for a change an older app must not apply (it skips a newer format and says so).
    static let format = 1

    /// How UserDefaults keeps a key, which is also how it is checked and written back.
    enum Kind {
        case bool          // a Bool
        case text          // a String (choices and numbers kept as text included)
        case int           // an integer
        case number        // a Double (whole numbers may arrive as integers; UserDefaults reads either)
        case intArray      // a list of integers
        case jsonData      // JSON kept as Data (Dart's setDataString, Swift's JSONEncoder); a JSON object or array in the file
        case path          // an absolute path String here, "~/..." in the file; applied only where it exists
    }

    struct Entry {
        let key: String
        let kind: Kind
        /// The settings code's own rule for a value of this key, given in its stored form (Bool, String, Int or Data).
        let accepts: (Any) -> Bool

        static func bool(_ key: String) -> Entry { Entry(key: key, kind: .bool, accepts: { $0 is Bool }) }
        static func text(_ key: String, _ rule: @escaping (String) -> Bool = { _ in true }) -> Entry {
            Entry(key: key, kind: .text, accepts: { ($0 as? String).map(rule) ?? false })
        }
        /// An integer kept as text (the Dart side parses it with int.tryParse and clamps it itself).
        static func intText(_ key: String, _ range: ClosedRange<Int>? = nil) -> Entry {
            text(key) { s in Int(s).map { range?.contains($0) ?? true } ?? false }
        }
        static func choice(_ key: String, _ allowed: [String]) -> Entry { text(key) { allowed.contains($0) } }
        static func int(_ key: String, _ range: ClosedRange<Int>) -> Entry {
            Entry(key: key, kind: .int, accepts: { ($0 as? Int).map(range.contains) ?? false })
        }
        static func number(_ key: String, _ rule: @escaping (Double) -> Bool = { _ in true }) -> Entry {
            Entry(key: key, kind: .number, accepts: { v in (v as? Double).map { $0.isFinite && rule($0) } ?? false })
        }
        static func intArray(_ key: String, _ rule: @escaping (Int) -> Bool = { _ in true }) -> Entry {
            Entry(key: key, kind: .intArray, accepts: { ($0 as? [Int]).map { $0.allSatisfy(rule) } ?? false })
        }
        static func json(_ key: String, _ rule: @escaping (Data) -> Bool = { _ in true }) -> Entry {
            Entry(key: key, kind: .jsonData, accepts: { ($0 as? Data).map(rule) ?? false })
        }
        /// A folder or file this Mac uses. Published only from inside the home folder, applied only if it exists there.
        static func path(_ key: String) -> Entry { Entry(key: key, kind: .path, accepts: { ($0 as? String)?.hasPrefix("/") ?? false }) }
    }

    struct Publish {
        var format = DefaultsFile.format
        var publishedAt: Date
        var publishId: String
        var mac: String
        var installId: String
        var appVersion: String
        var values: [String: Any]
        /// Path settings that are folders: created on a Mac that does not have them.
        var folders: [String] = []
        /// Path settings that are files: key -> the file's name in the shared folder's assets subfolder.
        var assets: [String: String] = [:]
    }

    static let assetsFolder = "assets"
    /// A file a setting points to travels only up to this size (a watermark image, not a video).
    static let maxAssetBytes = 25 * 1024 * 1024

    enum ReadResult {
        case unreachable            // the folder is not there (a network volume that is not mounted, a deleted folder)
        case missing                // the folder is there, the file is not (nobody published yet)
        case downloading            // iCloud Drive has only a placeholder; a download was asked for
        case malformed              // half written, cut off, not ours
        case newer(Int)             // made by a newer app: skipped
        case ok(Publish)
    }

    enum Decision: Equatable {
        case apply
        case own                    // published by this very app install
        case alreadyApplied         // this publish id was applied before
    }

    // MARK: Publish

    /// The whitelisted keys' current values in the file's JSON form; never-set keys as NSNull. A stored value of the wrong
    /// type (or JSON data that does not parse) is left out, so a receiver keeps its own value for it.
    /// A path setting goes as "~/..." when it is inside [home] and is left out when it is not.
    static func snapshot(_ d: UserDefaults, entries: [Entry], home: String = NSHomeDirectory()) -> [String: Any] {
        var out: [String: Any] = [:]
        for e in entries {
            guard let raw = d.object(forKey: e.key) else { out[e.key] = NSNull(); continue }
            if e.kind == .path {
                if let p = raw as? String, e.accepts(p), let rel = homeRelative(p, home: home) { out[e.key] = rel }
            } else if let v = jsonValue(raw, kind: e.kind), let stored = storedValue(v, kind: e.kind), e.accepts(stored) {
                out[e.key] = v
            }
        }
        return out
    }

    /// "~" or "~/<the rest>" for a path inside [home]; nil outside it.
    static func homeRelative(_ path: String, home: String) -> String? {
        let p = (path as NSString).standardizingPath, h = (home as NSString).standardizingPath
        if p == h { return "~" }
        guard p.hasPrefix(h + "/") else { return nil }
        return "~/" + p.dropFirst(h.count + 1)
    }

    /// The absolute path in [home] for a published "~/..." path; nil for anything else (an absolute path, "..").
    static func expandHome(_ published: String, home: String) -> String? {
        guard published == "~" || published.hasPrefix("~/") else { return nil }
        let rest = published.dropFirst(published == "~" ? 1 : 2)
        guard !rest.split(separator: "/").contains("..") else { return nil }
        return rest.isEmpty ? home : home + "/" + rest
    }

    static func encode(_ p: Publish) throws -> Data {
        var doc: [String: Any] = ["format": p.format, "publishedAt": iso.string(from: p.publishedAt), "publishId": p.publishId,
                                  "mac": p.mac, "installId": p.installId, "appVersion": p.appVersion, "values": p.values]
        if !p.folders.isEmpty { doc["folders"] = p.folders.sorted() }
        if !p.assets.isEmpty { doc["assets"] = p.assets }
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes the file whole or not at all: a hidden temp file in the same folder, then a rename over the old file, so a
    /// reader on another Mac never sees half of it.
    static func write(_ data: Data, to folder: URL, fileManager fm: FileManager = .default) throws {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        let temp = folder.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if rename(temp.path, folder.appendingPathComponent(name).path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// The keys whose value is not the same in [a] and [b] (a key only one of them has counts).
    static func changedKeys(_ a: [String: Any], _ b: [String: Any]) -> Set<String> {
        var out = Set<String>()
        for k in Set(a.keys).union(b.keys) {
            guard let x = a[k], let y = b[k] else { out.insert(k); continue }
            if canonical(["v": x]) != canonical(["v": y]) { out.insert(k) }
        }
        return out
    }

    /// What a Mac publishes after changing only [changed]: the values every Mac already shares ([shared], the file as it
    /// stands) with this Mac's [local] value for each changed key. So a Mac sends its changes, never the rest of its state,
    /// and two Macs changing different settings do not undo each other.
    static func merge(shared: [String: Any], local: [String: Any], changed: Set<String>) -> [String: Any] {
        var out = shared
        for k in changed {
            if let v = local[k] { out[k] = v } else { out.removeValue(forKey: k) }
        }
        return out
    }

    /// The published values in one fixed byte form, to tell "something changed" from "nothing did".
    static func canonical(_ values: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
    }

    /// For the path settings in [values] ("~/..."): which are folders, and a copy of each file (up to maxAssetBytes) in
    /// [folder]/assets under its content hash, written whole or not at all and only when missing. Copies no published
    /// setting points to any more are removed (only here, when publishing; never when applying).
    /// [keep] = asset names other settings of the publish still point to (settings this Mac did not change).
    static func publishAssets(_ values: [String: Any], entries: [Entry], to folder: URL, home: String = NSHomeDirectory(),
                              fileManager fm: FileManager = .default, keep: Set<String> = []) -> (folders: [String], assets: [String: String]) {
        var folders: [String] = [], assets: [String: String] = [:]
        let dir = folder.appendingPathComponent(assetsFolder, isDirectory: true)
        for e in entries where e.kind == .path {
            guard let abs = (values[e.key] as? String).flatMap({ expandHome($0, home: home) }) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders.append(e.key); continue }
            guard let size = (try? fm.attributesOfItem(atPath: abs))?[.size] as? Int, size <= maxAssetBytes,
                  let data = fm.contents(atPath: abs) else { continue }
            let ext = (abs as NSString).pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
            let name = hashHex(data) + (ext.isEmpty ? "" : "." + ext)
            let target = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let temp = dir.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
                guard (try? data.write(to: temp)) != nil else { continue }
                if rename(temp.path, target.path) != 0 { try? fm.removeItem(at: temp); continue }
            }
            assets[e.key] = name
        }
        let wanted = Set(assets.values).union(keep)
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !wanted.contains(old) && !old.hasPrefix(".") {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
        return (folders.sorted(), assets)
    }

    static func hashHex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// An asset name as publishAssets makes it: one plain file name, nothing that could leave the assets folder.
    static func safeAssetName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && name.count <= 100
    }

    // MARK: Apply

    static func read(folder: URL, fileManager fm: FileManager = .default) -> ReadResult {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return .unreachable }
        let file = folder.appendingPathComponent(name)
        guard let data = fm.contents(atPath: file.path) else {
            // iCloud Drive keeps an evicted file as ".snapnow-defaults.json.icloud" until it is downloaded
            let placeholder = folder.appendingPathComponent(".\(name).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: file)
                return .downloading
            }
            return fm.fileExists(atPath: file.path) ? .malformed : .missing
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> ReadResult {
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawFormat = doc["format"] as? NSNumber, !isBool(rawFormat), let format = exactInt(rawFormat) else { return .malformed }
        if format > Self.format { return .newer(format) }
        guard format >= 1,
              let id = doc["publishId"] as? String, !id.isEmpty,
              let install = doc["installId"] as? String, !install.isEmpty,
              let at = (doc["publishedAt"] as? String).flatMap(iso.date(from:)),
              let values = doc["values"] as? [String: Any] else { return .malformed }
        let mac = (doc["mac"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "another Mac"
        return .ok(Publish(format: format, publishedAt: at, publishId: id, mac: mac, installId: install,
                           appVersion: doc["appVersion"] as? String ?? "", values: values,
                           folders: doc["folders"] as? [String] ?? [], assets: doc["assets"] as? [String: String] ?? [:]))
    }

    /// Own publishes are never applied (no ping-pong); an id already applied only again when asked (Apply now).
    static func decide(_ p: Publish, installId: String, lastAppliedId: String?, force: Bool) -> Decision {
        if p.installId == installId { return .own }
        if !force, p.publishId == lastAppliedId { return .alreadyApplied }
        return .apply
    }

    struct Applied {
        var applied: [String] = []
        /// Wrong type, out of range, not a choice here: this Mac keeps its own value.
        var rejected: [String] = []
        /// A published folder or file that does not exist on this Mac: this Mac keeps its own value.
        var missing: [String] = []
    }

    /// Sets the keys of [entries] found in [values]; null removes the key (back to the built-in default). Keys not in
    /// [entries] (excluded here, unknown to this version) are ignored; a bad value is skipped and the key keeps its value
    /// here; a "~/..." path is expanded in [home] and set only if it exists - after creating it when the publish says it is
    /// a folder ([folders]), or copying the published file into place when the publish carries it ([assets], kept in
    /// [sharedFolder]/assets).
    @discardableResult
    static func apply(_ values: [String: Any], to d: UserDefaults, entries: [Entry], home: String = NSHomeDirectory(),
                      fileManager fm: FileManager = .default, folders: [String] = [], assets: [String: String] = [:],
                      sharedFolder: URL? = nil) -> Applied {
        var r = Applied()
        for e in entries {
            guard let v = values[e.key] else { continue }
            if v is NSNull {
                d.removeObject(forKey: e.key)
                r.applied.append(e.key)
            } else if e.kind == .path {
                guard let abs = (v as? String).flatMap({ expandHome($0, home: home) }), e.accepts(abs) else { r.rejected.append(e.key); continue }
                if folders.contains(e.key) {
                    if !fm.fileExists(atPath: abs) { try? fm.createDirectory(atPath: abs, withIntermediateDirectories: true) }
                } else if let name = assets[e.key], safeAssetName(name), let sharedFolder {
                    // the published file: copied into place when missing here, or when this Mac's file there is another one
                    let source = sharedFolder.appendingPathComponent(assetsFolder).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    let here = fm.fileExists(atPath: abs, isDirectory: &isDir)
                    let same = here && !isDir.boolValue && fm.contents(atPath: abs).map { name.hasPrefix(hashHex($0)) } == true
                    if !same, !isDir.boolValue, let data = fm.contents(atPath: source.path), name.hasPrefix(hashHex(data)) {
                        try? fm.createDirectory(atPath: (abs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                        try? data.write(to: URL(fileURLWithPath: abs), options: .atomic)
                    }
                }
                if fm.fileExists(atPath: abs) {
                    d.set(abs, forKey: e.key)
                    r.applied.append(e.key)
                } else {
                    r.missing.append(e.key)
                }
            } else if let stored = storedValue(v, kind: e.kind), e.accepts(stored) {
                d.set(stored, forKey: e.key)
                r.applied.append(e.key)
            } else {
                r.rejected.append(e.key)
            }
        }
        return r
    }

    // MARK: Conversions

    /// A UserDefaults value as it goes into the file, or nil when it is not of the key's kind.
    static func jsonValue(_ raw: Any, kind: Kind) -> Any? {
        switch kind {
        case .bool: return isBool(raw) ? (raw as? Bool) : nil
        case .text: return raw as? String
        case .int: return isBool(raw) ? nil : (raw as? NSNumber).flatMap { exactInt($0) }
        case .number: return isBool(raw) ? nil : (raw as? NSNumber)?.doubleValue
        case .intArray: return intArray(raw)
        case .jsonData:
            let data = (raw as? Data) ?? (raw as? String)?.data(using: .utf8)
            guard let data, let v = try? JSONSerialization.jsonObject(with: data), v is [String: Any] || v is [Any] else { return nil }
            return v
        case .path: return raw as? String
        }
    }

    /// A file value in the form UserDefaults keeps it, or nil when it is not of the key's kind.
    static func storedValue(_ v: Any, kind: Kind) -> Any? {
        switch kind {
        case .bool: return isBool(v) ? (v as? Bool) : nil
        case .text: return v as? String
        case .int: return isBool(v) ? nil : (v as? NSNumber).flatMap { exactInt($0) }
        case .number: return isBool(v) ? nil : (v as? NSNumber)?.doubleValue
        case .intArray: return intArray(v)
        case .jsonData:
            guard v is [String: Any] || v is [Any] else { return nil }
            return try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
        case .path: return v as? String
        }
    }

    private static func intArray(_ v: Any) -> [Int]? {
        guard let list = v as? [Any] else { return nil }
        var out: [Int] = []
        for x in list {
            guard !isBool(x), let n = (x as? NSNumber).flatMap({ exactInt($0) }) else { return nil }
            out.append(n)
        }
        return out
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func exactInt(_ n: NSNumber) -> Int? {
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 9e15 else { return nil }
        return Int(d)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
