import Foundation

/// Games we know: which exe actually runs (the one that needs the bridge next to it).
public struct KnownGame: Sendable {
    public let name: String
    public let steamAppID: Int?
    /// Paths relative to the install folder, first match wins.
    public let executables: [String]
    /// Publishes Kunos physics telemetry for simulated TrueForce.
    public let telemetry: Bool

    public static let catalog: [KnownGame] = [
        KnownGame(name: "Assetto Corsa Competizione", steamAppID: 805550, executables: ["AC2/Binaries/Win64/AC2-Win64-Shipping.exe"], telemetry: true),
        KnownGame(name: "Assetto Corsa EVO", steamAppID: 3058630, executables: ["AssettoCorsaEVO.exe"], telemetry: true),
        KnownGame(name: "Assetto Corsa", steamAppID: 244210, executables: ["acs.exe"], telemetry: true),
        KnownGame(name: "Automobilista 2", steamAppID: 1066890, executables: ["AMS2AVX.exe", "AMS2.exe"], telemetry: false),
        KnownGame(name: "rFactor 2", steamAppID: 365960, executables: ["Bin64/rFactor2.exe"], telemetry: false),
        KnownGame(name: "Le Mans Ultimate", steamAppID: 2399420, executables: ["Le Mans Ultimate.exe"], telemetry: false),
        KnownGame(name: "RaceRoom Racing Experience", steamAppID: 211500, executables: ["Game/x64/RRRE64.exe"], telemetry: false),
        KnownGame(name: "BeamNG.drive", steamAppID: 284160, executables: ["Bin64/BeamNG.drive.x64.exe"], telemetry: false),
    ]
    public static func byAppID(_ id: Int) -> KnownGame? { catalog.first { $0.steamAppID == id } }
    /// Matches an exe anywhere on disk by its last path components.
    public static func matching(executable url: URL) -> KnownGame? {
        let path = url.path.lowercased()
        return catalog.first { $0.executables.contains { path.hasSuffix("/" + $0.lowercased()) } }
    }
}

/// A Wine prefix / CrossOver bottle (the folder holding user.reg and drive_c).
public struct WinePrefix: Sendable, Hashable, Codable {
    public var url: URL
    public var label: String // "CrossOver bottle “Steam”", "Steam (NotProton) · app 805550", …
    public init(url: URL, label: String) { self.url = url; self.label = label }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent("user.reg").path) }
}

public struct GameEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: String { executable.path }
    public var name: String
    public var executable: URL
    public var prefix: WinePrefix
    public var source: String // where it was found, for the UI
    public var known: Bool
    public var telemetry: Bool
    public var custom = false
    /// For cover art (Steam library artwork), when the game has a Steam app ID.
    public var steamAppID: Int?
    public init(name: String, executable: URL, prefix: WinePrefix, source: String, known: Bool, telemetry: Bool, custom: Bool = false, steamAppID: Int? = nil) {
        self.name = name; self.executable = executable; self.prefix = prefix; self.source = source
        self.known = known; self.telemetry = telemetry; self.custom = custom; self.steamAppID = steamAppID
    }
}

/// Finds Windows games and their prefixes: Steam libraries on any disk (games run through
/// NotProton or another compatibility tool keep their prefix in steamapps/compatdata/<appid>/pfx),
/// Steam non-Steam shortcuts, CrossOver bottles (including a Steam install inside a bottle) and ~/.wine.
public struct GameLibrary {
    public var home: URL
    public var fileManager = FileManager.default
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    var steamRoot: URL { home.appendingPathComponent("Library/Application Support/Steam") }
    var notProtonInstalled: Bool { fileManager.fileExists(atPath: home.appendingPathComponent("Library/Application Support/notproton").path) }

    public func discover() -> [GameEntry] {
        var games: [GameEntry] = []
        games += steamGames()
        games += steamShortcuts()
        let bottles = crossOverBottles()
        for bottle in bottles { games += gamesInBottle(bottle) }
        let gameFolders = Set(games.map { $0.executable.deletingLastPathComponent().standardizedFileURL.path.lowercased() })
        var cmPrefixes: [(WinePrefix, String)] = []
        var seenPrefixes = Set<String>()
        for g in games where g.steamAppID == 244210 && g.prefix.exists {
            if seenPrefixes.insert(g.prefix.url.standardizedFileURL.path.lowercased()).inserted {
                cmPrefixes.append((g.prefix, g.source))
            }
        }
        for bottle in bottles where bottle.exists {
            if seenPrefixes.insert(bottle.url.standardizedFileURL.path.lowercased()).inserted {
                cmPrefixes.append((bottle, bottle.label))
            }
        }
        for (prefix, source) in cmPrefixes {
            games += contentManagers(in: prefix, source: source, excludingFolders: gameFolders)
        }
        var seen = Set<String>()
        return games.filter { seen.insert($0.executable.standardizedFileURL.path.lowercased()).inserted }
            .sorted { ($0.known ? 0 : 1, $0.name.lowercased()) < ($1.known ? 0 : 1, $1.name.lowercased()) }
    }

    /// Every prefix we can see, for attaching a game the scan did not find.
    public func prefixes() -> [WinePrefix] {
        var out: [WinePrefix] = crossOverBottles()
        for library in steamLibraries(root: steamRoot) {
            let compat = library.appendingPathComponent("steamapps/compatdata")
            for id in (try? fileManager.contentsOfDirectory(atPath: compat.path)) ?? [] {
                let pfx = WinePrefix(url: compat.appendingPathComponent(id).appendingPathComponent("pfx"), label: "\(steamLabel) · app \(id)")
                if pfx.exists { out.append(pfx) }
            }
        }
        let wine = WinePrefix(url: home.appendingPathComponent(".wine"), label: "Wine (~/.wine)")
        if wine.exists { out.append(wine) }
        return out
    }

    /// The prefix a hand-picked exe belongs to, when it can be worked out.
    public func prefix(for exe: URL, among games: [GameEntry]) -> WinePrefix? {
        // Inside a prefix's drive_c.
        var dir = exe.deletingLastPathComponent()
        while dir.path != "/" && !dir.path.isEmpty {
            if dir.lastPathComponent == "drive_c" {
                let root = dir.deletingLastPathComponent()
                let pfx = WinePrefix(url: root, label: root.path.contains("/CrossOver/Bottles/") ? "CrossOver bottle “\(root.lastPathComponent)”" : "Wine prefix \(root.lastPathComponent)")
                if pfx.exists { return pfx }
            }
            dir = dir.deletingLastPathComponent()
        }
        // A game we already know at the same folder (e.g. a Steam game, a shortcut).
        let folder = exe.deletingLastPathComponent().standardizedFileURL.path
        if let g = games.first(where: { $0.executable.deletingLastPathComponent().standardizedFileURL.path == folder }) { return g.prefix }
        return nil
    }

    var steamLabel: String { notProtonInstalled ? "Steam · NotProton" : "Steam · Windows compatibility" }

    // MARK: Steam on macOS (NotProton / compatibility tools)

    func steamLibraries(root: URL, windowsDrives: [String: URL]? = nil) -> [URL] {
        var out = [root]
        let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for path in VDF.values(named: "path", in: text) {
                if let drives = windowsDrives { if let url = Self.windowsPath(path, drives: drives) { out.append(url) } }
                else { out.append(URL(fileURLWithPath: path)) }
            }
        }
        var seen = Set<String>()
        return out.filter { fileManager.fileExists(atPath: $0.appendingPathComponent("steamapps").path) && seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    struct SteamApp { var id: Int; var name: String; var folder: URL; var library: URL }
    func steamApps(in library: URL) -> [SteamApp] {
        let apps = library.appendingPathComponent("steamapps")
        return ((try? fileManager.contentsOfDirectory(atPath: apps.path)) ?? []).compactMap { file in
            guard file.hasPrefix("appmanifest_"), file.hasSuffix(".acf"),
                  let text = try? String(contentsOf: apps.appendingPathComponent(file), encoding: .utf8),
                  let id = VDF.values(named: "appid", in: text).first.flatMap(Int.init),
                  let dir = VDF.values(named: "installdir", in: text).first else { return nil }
            let name = VDF.values(named: "name", in: text).first ?? dir
            return SteamApp(id: id, name: name, folder: apps.appendingPathComponent("common").appendingPathComponent(dir), library: library)
        }
    }

    func steamGames() -> [GameEntry] {
        let libraries = steamLibraries(root: steamRoot)
        func compat(_ id: Int) -> URL {
            // Steam keeps the prefix in the game's library; fall back to any library that has it.
            for lib in libraries {
                let p = lib.appendingPathComponent("steamapps/compatdata/\(id)/pfx")
                if fileManager.fileExists(atPath: p.path) { return p }
            }
            return (libraries.first ?? steamRoot).appendingPathComponent("steamapps/compatdata/\(id)/pfx")
        }
        var out: [GameEntry] = []
        for lib in libraries {
            for app in steamApps(in: lib) where fileManager.fileExists(atPath: app.folder.path) {
                let known = KnownGame.byAppID(app.id)
                var pfxURL = lib.appendingPathComponent("steamapps/compatdata/\(app.id)/pfx")
                if !fileManager.fileExists(atPath: pfxURL.path) { pfxURL = compat(app.id) }
                let hasPrefix = fileManager.fileExists(atPath: pfxURL.path)
                // Only Windows games: a known one, or anything Steam runs through a compatibility tool.
                guard known != nil || hasPrefix else { continue }
                guard let exe = known.flatMap({ firstExisting($0.executables, in: app.folder) }) ?? Self.guessExecutable(in: app.folder, fileManager: fileManager) else { continue }
                out.append(GameEntry(name: known?.name ?? app.name, executable: exe,
                                     prefix: WinePrefix(url: pfxURL, label: "\(steamLabel) · app \(app.id)"),
                                     source: steamLabel, known: known != nil, telemetry: known?.telemetry ?? false, steamAppID: app.id))
            }
        }
        return out
    }

    /// Non-Steam games added to Steam (e.g. run through NotProton): userdata/*/config/shortcuts.vdf.
    func steamShortcuts() -> [GameEntry] {
        let userdata = steamRoot.appendingPathComponent("userdata")
        var out: [GameEntry] = []
        for user in (try? fileManager.contentsOfDirectory(atPath: userdata.path)) ?? [] {
            let file = userdata.appendingPathComponent(user).appendingPathComponent("config/shortcuts.vdf")
            guard let data = try? Data(contentsOf: file) else { continue }
            for shortcut in BinaryVDF.shortcuts(data) {
                var exePath = shortcut.exe.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                guard exePath.lowercased().hasSuffix(".exe"), exePath.hasPrefix("/") else { continue }
                exePath = (exePath as NSString).standardizingPath
                let exe = URL(fileURLWithPath: exePath)
                guard fileManager.fileExists(atPath: exe.path) else { continue }
                let known = KnownGame.matching(executable: exe)
                var pfx = steamRoot.appendingPathComponent("steamapps/compatdata/\(shortcut.appID)/pfx")
                for lib in steamLibraries(root: steamRoot) {
                    let p = lib.appendingPathComponent("steamapps/compatdata/\(shortcut.appID)/pfx")
                    if fileManager.fileExists(atPath: p.path) { pfx = p; break }
                }
                out.append(GameEntry(name: known?.name ?? shortcut.name, executable: exe,
                                     prefix: WinePrefix(url: pfx, label: "\(steamLabel) · shortcut \(shortcut.appID)"),
                                     source: "\(steamLabel) shortcut", known: known != nil, telemetry: known?.telemetry ?? false, steamAppID: known?.steamAppID))
            }
        }
        return out
    }

    // MARK: CrossOver

    func crossOverBottles() -> [WinePrefix] {
        var roots = [home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")]
        let prefs = home.appendingPathComponent("Library/Preferences/com.codeweavers.CrossOver.plist")
        if let dict = NSDictionary(contentsOf: prefs), let custom = dict["BottleDir"] as? String {
            roots.insert(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath), at: 0)
        }
        var out: [WinePrefix] = []
        for root in roots {
            for name in ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
                let pfx = WinePrefix(url: root.appendingPathComponent(name), label: "CrossOver bottle “\(name)”")
                if pfx.exists { out.append(pfx) }
            }
        }
        return out
    }

    func gamesInBottle(_ bottle: WinePrefix) -> [GameEntry] {
        var out: [GameEntry] = []
        let drives = Self.drives(of: bottle.url)
        let source = bottle.label
        for steam in ["drive_c/Program Files (x86)/Steam", "drive_c/Program Files/Steam"].map({ bottle.url.appendingPathComponent($0) })
            where fileManager.fileExists(atPath: steam.appendingPathComponent("steamapps").path) {
            for lib in steamLibraries(root: steam, windowsDrives: drives) {
                for app in steamApps(in: lib) where fileManager.fileExists(atPath: app.folder.path) {
                    let known = KnownGame.byAppID(app.id)
                    guard let exe = known.flatMap({ firstExisting($0.executables, in: app.folder) }) ?? Self.guessExecutable(in: app.folder, fileManager: fileManager) else { continue }
                    if app.id == 228980 { continue } // Steamworks Common Redistributables
                    out.append(GameEntry(name: known?.name ?? app.name, executable: exe, prefix: bottle, source: source,
                                         known: known != nil, telemetry: known?.telemetry ?? false, steamAppID: app.id))
                }
            }
        }
        // Known games installed without Steam (other launchers, standalone).
        let roots = ["Program Files", "Program Files (x86)", "Games", "GOG Games", "Program Files/Epic Games"].map { bottle.url.appendingPathComponent("drive_c").appendingPathComponent($0) }
        for root in roots {
            for exe in findKnownExecutables(under: root, depth: 4) {
                let known = KnownGame.matching(executable: exe)!
                out.append(GameEntry(name: known.name, executable: exe, prefix: bottle, source: source, known: true, telemetry: known.telemetry, steamAppID: known.steamAppID))
            }
        }
        return out
    }

    func findKnownExecutables(under root: URL, depth: Int) -> [URL] {
        guard depth > 0, let items = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        var out: [URL] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if ["windows", "steam", "common files", "microsoft", "windowsapps"].contains(item.lastPathComponent.lowercased()) { continue }
                out += findKnownExecutables(under: item, depth: depth - 1)
            } else if item.pathExtension.lowercased() == "exe", KnownGame.matching(executable: item) != nil {
                out.append(item)
            }
        }
        return out
    }

    func firstExisting(_ paths: [String], in folder: URL) -> URL? {
        paths.map { folder.appendingPathComponent($0) }.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Scans common locations inside a Wine prefix for Assetto Corsa Content Manager
    /// (excluding any folder that already hosts another game executable, such as acs.exe).
    func contentManagers(in prefix: WinePrefix, source: String, excludingFolders: Set<String>) -> [GameEntry] {
        let driveC = prefix.url.appendingPathComponent("drive_c")
        guard fileManager.fileExists(atPath: driveC.path) else { return [] }
        var candidateDirs: [URL] = [
            "ContentManager",
            "Content Manager",
            "Program Files/Content Manager",
            "Program Files/ContentManager",
            "Program Files (x86)/Content Manager",
            "Program Files (x86)/ContentManager",
            "Games/Content Manager",
            "Games/ContentManager",
        ].map { driveC.appendingPathComponent($0) }

        let usersDir = driveC.appendingPathComponent("users")
        for user in (try? fileManager.contentsOfDirectory(atPath: usersDir.path)) ?? [] {
            let lower = user.lowercased()
            if lower == "public" || lower.hasPrefix(".") { continue }
            let userRoot = usersDir.appendingPathComponent(user)
            for sub in [
                "Desktop", "Desktop/Content Manager", "Desktop/ContentManager",
                "Downloads", "Downloads/Content Manager", "Downloads/ContentManager",
                "Documents", "Documents/Content Manager", "Documents/ContentManager",
            ] {
                candidateDirs.append(userRoot.appendingPathComponent(sub))
            }
        }

        var out: [GameEntry] = []
        for dir in candidateDirs {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            guard !excludingFolders.contains(dir.standardizedFileURL.path.lowercased()) else { continue }
            guard let items = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for item in items where item.lastPathComponent.lowercased() == "content manager.exe" {
                guard PE.isSupportedWindows(item) else { continue }
                out.append(GameEntry(
                    name: "Assetto Corsa Content Manager",
                    executable: item,
                    prefix: prefix,
                    source: source,
                    known: true,
                    telemetry: false,
                    steamAppID: nil
                ))
            }
        }
        return out
    }

    /// Best guess at the main game exe in an install folder: prefers the largest 64-bit PE32+,
    /// falling back to the largest 32-bit PE32, skipping crash handlers, installers and helpers.
    public static func guessExecutable(in folder: URL, fileManager: FileManager = .default) -> URL? {
        let skip = ["crash", "unins", "setup", "redist", "vc_redist", "vcredist", "dxsetup", "dotnet", "easyanticheat", "eac", "beservice", "battleye", "helper", "report", "cef", "webengine", "install", "update", "dxwebsetup", "physx", "ue4prereq", "uninstall"]
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        var best64: (URL, Int)?
        var best32: (URL, Int)?
        for case let url as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let lower = url.lastPathComponent.lowercased()
            if skip.contains(where: lower.contains) { continue }
            if url.pathComponents.contains(where: { ["_commonredist", "redist", "redistributables", "directx", "support", "engine/extras"].contains($0.lowercased()) }) { continue }
            guard let arch = PE.architecture(url) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            switch arch {
            case .x64: if size > best64?.1 ?? -1 { best64 = (url, size) }
            case .x86: if size > best32?.1 ?? -1 { best32 = (url, size) }
            }
        }
        return best64?.0 ?? best32?.0
    }

    /// Wine drive letters of a prefix, from dosdevices symlinks.
    static func drives(of prefix: URL) -> [String: URL] {
        let dos = prefix.appendingPathComponent("dosdevices")
        var out: [String: URL] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dos.path)) ?? [] where name.count == 2 && name.hasSuffix(":") {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: dos.appendingPathComponent(name).path) {
                out[String(name.prefix(1)).lowercased()] = URL(fileURLWithPath: target, relativeTo: dos).standardizedFileURL
            }
        }
        return out
    }

    static func windowsPath(_ path: String, drives: [String: URL]) -> URL? {
        let p = path.replacingOccurrences(of: "\\\\", with: "\\")
        guard p.count >= 2, Array(p)[1] == ":", let root = drives[String(p.prefix(1)).lowercased()] else { return nil }
        let rest = p.dropFirst(2).split(separator: "\\").map(String.init)
        return rest.reduce(root) { $0.appendingPathComponent($1) }
    }
}

public enum PE {
    public enum Arch: Equatable, Sendable { case x64, x86 }

    /// Detects whether a PE file is x86-64 (`.x64`) or 32-bit x86 (`.x86`).
    public static func architecture(_ url: URL) -> Arch? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024), head.count >= 0x40 else { return nil }
        let bytes = [UInt8](head)
        guard bytes[0] == 0x4d, bytes[1] == 0x5a else { return nil }
        let off = Int(bytes[0x3c]) | Int(bytes[0x3d]) << 8 | Int(bytes[0x3e]) << 16 | Int(bytes[0x3f]) << 24
        guard off >= 0 else { return nil }
        let header: [UInt8]
        if off + 6 <= bytes.count {
            header = Array(bytes[off..<off + 6])
        } else {
            guard (try? handle.seek(toOffset: UInt64(off))) != nil, let more = try? handle.read(upToCount: 6), more.count == 6 else { return nil }
            header = [UInt8](more)
        }
        return machine(header)
    }

    public static func architecture(of data: Data) -> Arch? {
        guard data.count >= 0x40 else { return nil }
        let bytes = [UInt8](data.prefix(0x40))
        guard bytes[0] == 0x4d, bytes[1] == 0x5a else { return nil }
        let off = Int(bytes[0x3c]) | Int(bytes[0x3d]) << 8 | Int(bytes[0x3e]) << 16 | Int(bytes[0x3f]) << 24
        guard off >= 0, off + 6 <= data.count else { return nil }
        return machine([UInt8](data[off..<off + 6]))
    }

    private static func machine(_ header: [UInt8]) -> Arch? {
        guard header.count == 6, header[0] == 0x50, header[1] == 0x45, header[2] == 0, header[3] == 0 else { return nil }
        if header[4] == 0x64 && header[5] == 0x86 { return .x64 }
        if header[4] == 0x4c && header[5] == 0x01 { return .x86 }
        return nil
    }

    /// True for a 64-bit (x86-64) Windows executable.
    public static func isWin64(_ url: URL) -> Bool { architecture(url) == .x64 }
    /// True for a 32-bit or 64-bit x86 Windows executable.
    public static func isSupportedWindows(_ url: URL) -> Bool { architecture(url) != nil }
}

/// Minimal readers for Steam's text and binary KeyValues formats.
public enum VDF {
    /// All values of `"key" "value"` pairs with this key, anywhere in the file.
    public static func values(named key: String, in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = quoted(String(line))
            if tokens.count >= 2, tokens[0].lowercased() == key.lowercased() { out.append(tokens[1]) }
        }
        return out
    }
    static func quoted(_ line: String) -> [String] {
        var out: [String] = [], current = "", inside = false, escape = false
        for c in line {
            if inside {
                if escape { current.append(c == "n" ? "\n" : c); escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { out.append(current); current = ""; inside = false }
                else { current.append(c) }
            } else if c == "\"" { inside = true }
        }
        return out
    }
}

public enum BinaryVDF {
    public struct Shortcut: Equatable { public var appID: UInt32; public var name: String; public var exe: String }
    /// Steam shortcuts.vdf: 0x00 map, 0x01 string, 0x02 int32, 0x08 end of map.
    public static func shortcuts(_ data: Data) -> [Shortcut] {
        let b = [UInt8](data)
        var i = 0
        func cstring() -> String? {
            guard let end = b[i...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: b[i..<end], as: UTF8.self)
            i = end + 1
            return s
        }
        var out: [Shortcut] = []
        var current: [String: Any] = [:]
        var depth = 0
        while i < b.count {
            let type = b[i]; i += 1
            if type == 0x08 {
                if depth == 2, let exe = current["exe"] as? String {
                    out.append(Shortcut(appID: current["appid"] as? UInt32 ?? 0, name: current["appname"] as? String ?? "Game", exe: exe))
                }
                if depth == 2 { current = [:] }
                depth -= 1
                if depth < 0 { break }
                continue
            }
            guard let key = cstring()?.lowercased() else { break }
            switch type {
            case 0x00: depth += 1
            case 0x01: guard let v = cstring() else { return out }; if depth == 2 { current[key] = v }
            case 0x02:
                guard i + 4 <= b.count else { return out }
                let v = UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
                i += 4
                if depth == 2 { current[key] = v }
            case 0x07: i += 8
            default: return out
            }
        }
        return out
    }
}
