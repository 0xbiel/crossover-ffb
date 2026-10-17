import XCTest
@testable import WheelCore

final class InstallerTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cfb-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    static func pe64() -> Data {
        var b = [UInt8](repeating: 0, count: 512)
        b[0] = 0x4d; b[1] = 0x5a; b[0x3c] = 0x80
        b[0x80] = 0x50; b[0x81] = 0x45; b[0x84] = 0x64; b[0x85] = 0x86
        return Data(b)
    }
    static func bridgeDLL() -> Data { pe64() + Data("cfb-bridge-v2 CFBUID=0".utf8) + Data(count: 24) }

    func makeGame(registry: String = "WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21\n\n#arch=win64\n\n[Software\\\\Wine] 1700000000\n#time=1\n\"Version\"=\"win10\"\n") throws -> GameEntry {
        let pfx = root.appendingPathComponent("pfx"), game = root.appendingPathComponent("SSD Games/My Game")
        try FileManager.default.createDirectory(at: pfx.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try registry.write(to: pfx.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try Self.pe64().write(to: game.appendingPathComponent("Game-Win64.exe"))
        return GameEntry(name: "Game", executable: game.appendingPathComponent("Game-Win64.exe"), prefix: WinePrefix(url: pfx, label: "test"), source: "test", known: false, telemetry: false)
    }
    func installer() -> BridgeInstaller {
        var i = BridgeInstaller(payload: Self.bridgeDLL(), stateDirectory: root.appendingPathComponent("state"))
        i.uid = 501; i.wineTemp = root
        return i
    }

    func testPatchWritesUidDigits() {
        let patched = BridgeInstaller.patch(Self.bridgeDLL(), uid: 501)
        XCTAssertNotNil(patched.range(of: Data("CFBUID=501\0\0".utf8)))
        XCTAssertEqual(patched.count, Self.bridgeDLL().count)
    }

    func testInstallAndUninstallRoundTrip() throws {
        let game = try makeGame()
        let original = try String(contentsOf: game.prefix.url.appendingPathComponent("user.reg"), encoding: .utf8)
        let i = installer()
        XCTAssertEqual(i.status(game), .notInstalled)
        try i.install(game)
        XCTAssertEqual(i.status(game), .installed)
        let reg = try String(contentsOf: game.prefix.url.appendingPathComponent("user.reg"), encoding: .utf8)
        XCTAssertTrue(reg.hasPrefix(original.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(reg.contains("[Software\\\\Wine\\\\AppDefaults\\\\Game-Win64.exe\\\\DllOverrides]\n\"dinput8\"=\"native,builtin\"\n"))
        try i.install(game) // idempotent
        XCTAssertEqual(try String(contentsOf: game.prefix.url.appendingPathComponent("user.reg"), encoding: .utf8), reg)
        try i.uninstall(game)
        XCTAssertEqual(i.status(game), .notInstalled)
        XCTAssertEqual(try String(contentsOf: game.prefix.url.appendingPathComponent("user.reg"), encoding: .utf8).trimmingCharacters(in: .newlines), original.trimmingCharacters(in: .newlines))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.executable.deletingLastPathComponent().appendingPathComponent("dinput8.dll").path))
    }

    func testForeignDLLAndExistingOverrideAreRestored() throws {
        let reg = "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\AppDefaults\\\\Game-Win64.exe\\\\DllOverrides] 1700000000\n#time=1\n\"dinput8\"=\"builtin\"\n\"xinput1_3\"=\"native\"\n\n[Software\\\\Wine\\\\Other] 1\n\"a\"=\"b\"\n"
        let game = try makeGame(registry: reg)
        let foreign = Self.pe64() + Data("some mod".utf8)
        let dll = game.executable.deletingLastPathComponent().appendingPathComponent("dinput8.dll")
        try foreign.write(to: dll)
        let i = installer()
        XCTAssertEqual(i.status(game), .otherDLL)
        try i.install(game)
        XCTAssertEqual(i.status(game), .installed)
        XCTAssertTrue(try String(contentsOf: game.prefix.url.appendingPathComponent("user.reg"), encoding: .utf8).contains("\"dinput8\"=\"native,builtin\"\n\"xinput1_3\"=\"native\""))
        try i.uninstall(game)
        XCTAssertEqual(try Data(contentsOf: dll), foreign)
        XCTAssertEqual(try String(contentsOf: game.prefix.url.appendingPathComponent("user.reg"), encoding: .utf8), reg)
    }

    func testOlderBridgeIsOutdatedAndRunningWineBlocks() throws {
        let game = try makeGame()
        let i = installer()
        try i.install(game)
        try (Self.pe64() + Data("cfb-bridge-v2 old".utf8)).write(to: game.executable.deletingLastPathComponent().appendingPathComponent("dinput8.dll"))
        XCTAssertEqual(i.status(game), .outdated)
        // Simulate a live wineserver for this prefix holding its lock.
        var info = stat(); stat(game.prefix.url.path, &info)
        let dir = root.appendingPathComponent(".wine-501").appendingPathComponent(String(format: "server-%llx-%llx", UInt64(info.st_dev), UInt64(info.st_ino)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent("lock").path
        FileManager.default.createFile(atPath: lockPath, contents: nil)
        XCTAssertFalse(i.isWineRunning(prefix: game.prefix.url))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time;f=open(sys.argv[1],'r+');fcntl.lockf(f,fcntl.LOCK_EX);print('locked',flush=True);time.sleep(5)", lockPath]
        let pipe = Pipe(); child.standardOutput = pipe
        try child.run()
        _ = pipe.fileHandleForReading.availableData
        XCTAssertTrue(i.isWineRunning(prefix: game.prefix.url))
        XCTAssertThrowsError(try i.uninstall(game)) { XCTAssertEqual($0 as? BridgeInstaller.Failure, .wineRunning) }
        child.terminate(); child.waitUntilExit()
    }

    func testMissingPrefixNeedsFirstLaunch() throws {
        var game = try makeGame()
        game.prefix.url = root.appendingPathComponent("nope")
        XCTAssertEqual(installer().status(game), .needsFirstLaunch)
        XCTAssertThrowsError(try installer().install(game)) { XCTAssertEqual($0 as? BridgeInstaller.Failure, .noPrefix) }
    }

    func testBinaryShortcutsAndTextVDF() {
        var d = Data([0x00]) + Data("shortcuts\0".utf8) + Data([0x00]) + Data("0\0".utf8)
        d += Data([0x02]) + Data("appid\0".utf8) + Data([0xd4, 0x19, 0xb1, 0x94])
        d += Data([0x01]) + Data("AppName\0Racing Game\0".utf8)
        d += Data([0x01]) + Data("Exe\0\"/Volumes/Games/Racing/Game.exe\"\0".utf8)
        d += Data([0x00]) + Data("tags\0".utf8) + Data([0x01]) + Data("0\0fav\0".utf8) + Data([0x08])
        d += Data([0x08, 0x08, 0x08])
        XCTAssertEqual(BinaryVDF.shortcuts(d), [.init(appID: 2494634452, name: "Racing Game", exe: "\"/Volumes/Games/Racing/Game.exe\"")])
        let text = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"/Volumes/My SSD/SteamLibrary\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"D:\\\\SteamLibrary\"\n\t}\n}\n"
        XCTAssertEqual(VDF.values(named: "path", in: text), ["/Volumes/My SSD/SteamLibrary", "D:\\SteamLibrary"])
        let drives = ["d": URL(fileURLWithPath: "/Volumes/Ext")]
        XCTAssertEqual(GameLibrary.windowsPath("D:\\SteamLibrary", drives: drives)?.path, "/Volumes/Ext/SteamLibrary")
    }

    func testDiscoveryFindsSteamLibraryOnAnyDiskAndCrossOverBottle() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home"), ssd = root.appendingPathComponent("Volumes/Fast SSD/SteamLibrary")
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        try fm.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try "\"libraryfolders\"\n{\n\"0\"\n{\n\"path\" \"\(steam.path)\"\n}\n\"1\"\n{\n\"path\" \"\(ssd.path)\"\n}\n}\n".write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)
        let acc = ssd.appendingPathComponent("steamapps/common/Assetto Corsa Competizione/AC2/Binaries/Win64")
        try fm.createDirectory(at: acc, withIntermediateDirectories: true)
        try Self.pe64().write(to: acc.appendingPathComponent("AC2-Win64-Shipping.exe"))
        try "\"AppState\"\n{\n\"appid\" \"805550\"\n\"name\" \"Assetto Corsa Competizione\"\n\"installdir\" \"Assetto Corsa Competizione\"\n}\n".write(to: ssd.appendingPathComponent("steamapps/appmanifest_805550.acf"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: ssd.appendingPathComponent("steamapps/compatdata/805550/pfx"), withIntermediateDirectories: true)
        try "WINE".write(to: ssd.appendingPathComponent("steamapps/compatdata/805550/pfx/user.reg"), atomically: true, encoding: .utf8)
        // A CrossOver bottle with a standalone known game.
        let bottle = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Racing")
        let evo = bottle.appendingPathComponent("drive_c/Games/AC EVO")
        try fm.createDirectory(at: evo, withIntermediateDirectories: true)
        try "WINE".write(to: bottle.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try Self.pe64().write(to: evo.appendingPathComponent("AssettoCorsaEVO.exe"))

        let games = GameLibrary(home: home).discover()
        let names = games.map(\.name)
        XCTAssertEqual(Set(names), ["Assetto Corsa Competizione", "Assetto Corsa EVO"])
        let accGame = try XCTUnwrap(games.first { $0.name.hasPrefix("Assetto Corsa C") })
        XCTAssertEqual(accGame.prefix.url.path, ssd.appendingPathComponent("steamapps/compatdata/805550/pfx").path)
        XCTAssertTrue(accGame.telemetry)
        let evoGame = try XCTUnwrap(games.first { $0.name == "Assetto Corsa EVO" })
        XCTAssertEqual(evoGame.prefix.url.path, bottle.path)
        XCTAssertEqual(GameLibrary(home: home).prefix(for: evoGame.executable, among: [])?.url.resolvingSymlinksInPath().path, bottle.resolvingSymlinksInPath().path)
    }
}
