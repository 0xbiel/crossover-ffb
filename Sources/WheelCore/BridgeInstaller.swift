import Foundation

/// Installs the dinput8.dll bridge next to a game's exe and sets Wine's per-app DLL override
/// (`dinput8` = native,builtin) in the prefix's user.reg. Undo puts back whatever was there.
public struct BridgeInstaller: Sendable {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        case outdated        // ours, but an older build or the override is missing: Update repairs it
        case otherDLL        // the game folder already has a different dinput8.dll (kept as a backup on install)
        case needsFirstLaunch // the prefix does not exist yet (Steam creates it on first launch)
        case missing         // exe no longer there
    }
    public enum Failure: LocalizedError, Equatable {
        case wineRunning, noPrefix, notWindows64, unsupportedName, backupInTheWay, bridgeMissing, io(String)
        public var errorDescription: String? {
            switch self {
            case .wineRunning: "This game's Wine session is still running. Quit the game (and Steam or CrossOver for that bottle), wait a few seconds, then try again."
            case .noPrefix: "Its Wine prefix does not exist yet. Launch the game once, quit it, then install."
            case .notWindows64: "That file is not a 64-bit Windows game executable."
            case .unsupportedName: "The executable name contains characters the Wine registry entry cannot hold."
            case .backupInTheWay: "The game folder already has a dinput8.dll backup from an earlier install. Remove dinput8.dll.crossover-ffb-original first."
            case .bridgeMissing: "The bridge DLL is missing from the app."
            case .io(let message): message
            }
        }
    }

    public static let override = "native,builtin"
    static let marker = Data("cfb-bridge-v2".utf8)
    static let backupName = "dinput8.dll.crossover-ffb-original"

    public var payload: Data // the unpatched DLL shipped with the app
    public var stateDirectory: URL
    public var uid: UInt32 = getuid()
    public var wineTemp = URL(fileURLWithPath: "/tmp")
    public init(payload: Data, stateDirectory: URL = BridgeInstaller.defaultStateDirectory) {
        self.payload = payload; self.stateDirectory = stateDirectory
    }
    public static var defaultStateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/crossover-ffb")
    }

    /// The DLL as installed for this Mac user (shared-memory path carries the uid).
    public var patchedPayload: Data { Self.patch(payload, uid: uid) }
    static func patch(_ dll: Data, uid: UInt32) -> Data {
        var bytes = [UInt8](dll)
        let tag = Array("CFBUID=".utf8)
        guard let at = bytes.indices.first(where: { bytes.count - $0 >= 24 && Array(bytes[$0..<$0 + 7]) == tag }) else { return dll }
        let digits = Array(String(uid).utf8)
        for k in 0..<17 { bytes[at + 7 + k] = k < digits.count ? digits[k] : 0 }
        return Data(bytes)
    }
    static func isOurs(_ data: Data) -> Bool { data.range(of: marker) != nil }

    // MARK: status

    public func status(_ game: GameEntry) -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: game.executable.path) else { return .missing }
        let dll = dllURL(game)
        let present = try? Data(contentsOf: dll)
        if let present, !Self.isOurs(present) { return game.prefix.exists ? .otherDLL : .needsFirstLaunch }
        guard game.prefix.exists else { return .needsFirstLaunch }
        guard let present else { return .notInstalled }
        let registry = (try? String(contentsOf: registryURL(game), encoding: .utf8)).map(UserRegistry.init)
        let value = registry?.value(section: Self.sectionName(game), name: "dinput8")
        if present != patchedPayload || !(value?.lowercased().hasPrefix("native") ?? false) { return .outdated }
        return .installed
    }

    // MARK: install / uninstall

    public func install(_ game: GameEntry) throws {
        guard payload.count > 2, payload.prefix(2) == Data("MZ".utf8) else { throw Failure.bridgeMissing }
        guard PE.isWin64(game.executable) else { throw Failure.notWindows64 }
        guard game.prefix.exists else { throw Failure.noPrefix }
        guard Self.validName(game.executable.lastPathComponent) else { throw Failure.unsupportedName }
        try ensureNotRunning(game)
        let fm = FileManager.default
        let dll = dllURL(game), backup = dll.deletingLastPathComponent().appendingPathComponent(Self.backupName)
        var record = loadRecords()[game.id] ?? Record(executable: game.executable.path, prefix: game.prefix.url.path)

        if let existing = try? Data(contentsOf: dll), !Self.isOurs(existing) {
            guard !fm.fileExists(atPath: backup.path) else { throw Failure.backupInTheWay }
            try wrap { try fm.moveItem(at: dll, to: backup) }
            record.keptOriginalDLL = true
        }
        try wrap { try Self.atomicWrite(patchedPayload, to: dll) }

        let reg = registryURL(game)
        let before = try wrap { try String(contentsOf: reg, encoding: .utf8) }
        try saveRegistryBackup(before, game: game)
        var registry = UserRegistry(before)
        let previous = registry.value(section: Self.sectionName(game), name: "dinput8")
        if record.previousOverride == nil, let previous, !previous.lowercased().hasPrefix("native") { record.previousOverride = previous }
        registry.set(section: Self.sectionName(game), name: "dinput8", value: Self.override)
        try ensureNotRunning(game)
        try wrap { try Self.atomicWrite(Data(registry.text.utf8), to: reg) }
        try saveRecord(record, for: game.id)
    }

    public func uninstall(_ game: GameEntry) throws {
        try ensureNotRunning(game)
        let fm = FileManager.default
        let dll = dllURL(game), backup = dll.deletingLastPathComponent().appendingPathComponent(Self.backupName)
        let record = loadRecords()[game.id]
        if let data = try? Data(contentsOf: dll), Self.isOurs(data) { try wrap { try fm.removeItem(at: dll) } }
        if fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: dll.path) { try wrap { try fm.moveItem(at: backup, to: dll) } }
        let reg = registryURL(game)
        if let before = try? String(contentsOf: reg, encoding: .utf8) {
            var registry = UserRegistry(before)
            if let previous = record?.previousOverride {
                registry.set(section: Self.sectionName(game), name: "dinput8", value: previous)
            } else if registry.value(section: Self.sectionName(game), name: "dinput8")?.lowercased().hasPrefix("native") == true {
                registry.remove(section: Self.sectionName(game), name: "dinput8")
            }
            if registry.text != before {
                try saveRegistryBackup(before, game: game)
                try wrap { try Self.atomicWrite(Data(registry.text.utf8), to: reg) }
            }
        }
        var records = loadRecords(); records[game.id] = nil
        try writeRecords(records)
    }

    // MARK: helpers

    func dllURL(_ game: GameEntry) -> URL { game.executable.deletingLastPathComponent().appendingPathComponent("dinput8.dll") }
    func registryURL(_ game: GameEntry) -> URL { game.prefix.url.appendingPathComponent("user.reg") }
    static func sectionName(_ game: GameEntry) -> String { "Software\\\\Wine\\\\AppDefaults\\\\\(game.executable.lastPathComponent)\\\\DllOverrides" }
    static func validName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".exe") && name.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && !"\\\"[]".unicodeScalars.contains($0) }
    }

    /// A running wineserver holds an fcntl lock on /tmp/.wine-<uid>/server-<dev>-<inode>/lock for
    /// its prefix, and rewrites user.reg from memory when it exits, so edits must wait for it.
    public func isWineRunning(prefix: URL) -> Bool {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return false }
        let dir = wineTemp.appendingPathComponent(".wine-\(uid)").appendingPathComponent(String(format: "server-%llx-%llx", UInt64(info.st_dev), UInt64(info.st_ino)))
        let fd = open(dir.appendingPathComponent("lock").path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &lock) == 0 else { return false }
        return lock.l_type != Int16(F_UNLCK)
    }
    func ensureNotRunning(_ game: GameEntry) throws { if isWineRunning(prefix: game.prefix.url) { throw Failure.wineRunning } }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".cfb-\(UUID().uuidString)")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
    }
    func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as Failure { throw error } catch { throw Failure.io(error.localizedDescription) }
    }

    struct Record: Codable { var executable: String; var prefix: String; var previousOverride: String?; var keptOriginalDLL = false }
    var recordsURL: URL { stateDirectory.appendingPathComponent("installs.json") }
    func loadRecords() -> [String: Record] {
        (try? JSONDecoder().decode([String: Record].self, from: Data(contentsOf: recordsURL))) ?? [:]
    }
    func writeRecords(_ records: [String: Record]) throws {
        try wrap {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: recordsURL, options: .atomic)
        }
    }
    func saveRecord(_ record: Record, for id: String) throws { var r = loadRecords(); r[id] = record; try writeRecords(r) }
    func saveRegistryBackup(_ text: String, game: GameEntry) throws {
        let dir = stateDirectory.appendingPathComponent("registry-backups")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try wrap {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent("\(stamp)-\(game.executable.deletingPathExtension().lastPathComponent).user.reg"), atomically: true, encoding: .utf8)
        }
    }
}

/// Line-based editor for Wine's user.reg that leaves everything it does not touch byte-identical.
public struct UserRegistry {
    public private(set) var lines: [String]
    public init(_ text: String) { lines = text.components(separatedBy: "\n") }
    public var text: String { lines.joined(separator: "\n") }

    static func header(_ line: String) -> String? {
        guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: line.startIndex)..<end])
    }
    /// Range of the section's body lines (after its header) and the header index.
    func find(_ section: String) -> (header: Int, body: Range<Int>)? {
        guard let h = lines.firstIndex(where: { Self.header($0)?.lowercased() == section.lowercased() }) else { return nil }
        var end = h + 1
        while end < lines.count, Self.header(lines[end]) == nil { end += 1 }
        return (h, h + 1..<end)
    }
    static func nameOf(_ line: String) -> String? {
        guard line.hasPrefix("\"") else { return nil }
        let rest = line.dropFirst()
        guard let q = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<q])
    }
    public func value(section: String, name: String) -> String? {
        guard let s = find(section) else { return nil }
        for i in s.body {
            let line = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if Self.nameOf(line)?.lowercased() == name.lowercased(), let eq = line.range(of: "\"=\"") {
                return String(line[eq.upperBound...].dropLast(line.hasSuffix("\"") ? 1 : 0))
            }
        }
        return nil
    }
    public mutating func set(section: String, name: String, value: String) {
        let entry = "\"\(name)\"=\"\(value)\""
        if let s = find(section) {
            if let i = s.body.first(where: { Self.nameOf(lines[$0])?.lowercased() == name.lowercased() }) { lines[i] = entry; return }
            var at = s.body.upperBound
            while at > s.body.lowerBound, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
            lines.insert(entry, at: at)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
            lines += ["", "[\(section)]", entry, ""]
        }
    }
    /// Removes the value; drops the section when nothing but metadata is left in it.
    public mutating func remove(section: String, name: String) {
        guard let s = find(section) else { return }
        guard let i = s.body.first(where: { Self.nameOf(lines[$0])?.lowercased() == name.lowercased() }) else { return }
        lines.remove(at: i)
        guard let s2 = find(section) else { return }
        let meaningful = s2.body.contains { let t = lines[$0].trimmingCharacters(in: .whitespacesAndNewlines); return !t.isEmpty && !t.hasPrefix("#") }
        if !meaningful {
            // The body includes the blank separator line before the next section.
            lines.removeSubrange(s2.header..<s2.body.upperBound)
            if lines.last != "" { lines.append("") }
        }
    }
}
