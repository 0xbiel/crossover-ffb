import AppKit
import ServiceManagement
import SwiftUI
import WheelCore

/// Everything the menu and the settings window show, kept in sync with the bridge thread and
/// UserDefaults.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    /// What the menu bar icon shows; changes only when the icon itself changes.
    final class IconState: ObservableObject {
        @Published var running = false
        @Published var gameActive = false
    }
    let icon = IconState()
    static var current: AppModel? { shared }
    let bridge: FFBBridge
    let isPreview: Bool
    private let defaults: UserDefaults
    @Published private var presentationTime = ProcessInfo.processInfo.systemUptime
    var presentation: WheelPresentation {
        WheelPresentation(running: status.running, connected: status.wheelConnected,
                          model: status.wheelModel, trueForceInterfaceAvailable: status.trueForceAvailable,
                          age: isPreview ? 0 : presentationTime - status.updatedAt)
    }
    var showsTrueForce: Bool { presentation.showsTrueForce }
    private var timer: Timer?
    private var settingsWindow: NSWindow?
    private var demoPopover: NSPopover?
    private var demoStatusItem: NSStatusItem?

    @Published var status = FFBBridge.Status()
    @Published var strength: Double { didSet { guard !isPreview else { return }; bridge.strength = strength / 100; defaults.set(strength, forKey: "strength") } }
    @Published var reverse: Bool { didSet { guard !isPreview else { return }; bridge.reverseDirectional = reverse; defaults.set(reverse, forKey: "reverse") } }
    @Published var autoStart: Bool { didSet { guard !isPreview else { return }; defaults.set(autoStart, forKey: "autoStart") } }
    /// Shared with the scene's @AppStorage("showInMenuBar"), which also changes when the icon is
    /// ⌘-dragged out of the menu bar; Settings is then the way back in.
    @Published var showInMenuBar: Bool {
        didSet {
            guard !isPreview, showInMenuBar != oldValue else { return }
            if defaults.bool(forKey: "showInMenuBar") != showInMenuBar { defaults.set(showInMenuBar, forKey: "showInMenuBar") }
            if !showInMenuBar { DispatchQueue.main.async { MainActor.assumeIsolated { self.showSettings(.general) } } }
        }
    }
    @Published var tfEnabled: Bool { didSet { pushTrueForce() } }
    @Published var tfStrength: Double { didSet { pushTrueForce() } }
    @Published var tfEngine: Double { didSet { pushTrueForce() } }
    @Published var tfRoad: Double { didSet { pushTrueForce() } }
    @Published var tfSlip: Double { didSet { pushTrueForce() } }
    /// G HUB-style wheel options (range, sensitivity, centering spring, pedals, rev lights).
    @Published var wheel: WheelSettings {
        didSet {
            guard !isPreview, wheel != oldValue else { return }
            bridge.wheel = wheel
            if let data = try? JSONEncoder().encode(wheel) { defaults.set(data, forKey: "wheel") }
        }
    }
    @Published var motorDetected: Bool
    @Published var tfMotorDetected: Bool
    @Published var settingsTab = SettingsTab.overview

    // Games
    @Published var games: [GameEntry] = []
    @Published var gameStatus: [String: BridgeInstaller.Status] = [:]
    @Published var scanning = false
    /// The scan has run for a while: usually macOS is waiting for permission to read a drive.
    @Published var slowScan = false
    @Published var busyGame: String?
    @Published var notice: Notice?
    @Published var pendingCustomExe: URL?
    @Published var prefixChoices: [WinePrefix] = []
    @Published var artwork: [Int: NSImage] = [:]
    private var artworkRequested = Set<Int>()
    let installer: BridgeInstaller

    struct Notice: Identifiable { let id = UUID(); var title: String; var message: String }
    enum SettingsTab: Hashable { case overview, games, wheel, forceFeedback, trueForce, inputs, general }

    init(preview: Bool = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--demo")) {
        isPreview = preview
        bridge = FFBBridge(hardwareEnabled: !preview)
        defaults = preview ? UserDefaults(suiteName: "crossover-ffb-preview-\(UUID().uuidString)")! : .standard
        defaults.register(defaults: ["strength": 80.0, "reverse": false, "motorSign": 0.0, "autoStart": true,
                                     "showInMenuBar": true, "tfEnabled": true, "tfStrength": 60.0, "tfEngine": 50.0, "tfRoad": 60.0, "tfSlip": 60.0, "tfMotorSign": 0.0])
        strength = defaults.double(forKey: "strength")
        reverse = defaults.bool(forKey: "reverse")
        autoStart = defaults.bool(forKey: "autoStart")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        tfEnabled = defaults.bool(forKey: "tfEnabled")
        tfStrength = defaults.double(forKey: "tfStrength")
        tfEngine = defaults.double(forKey: "tfEngine")
        tfRoad = defaults.double(forKey: "tfRoad")
        tfSlip = defaults.double(forKey: "tfSlip")
        wheel = defaults.data(forKey: "wheel").flatMap { try? JSONDecoder().decode(WheelSettings.self, from: $0) } ?? WheelSettings()
        motorDetected = defaults.double(forKey: "motorSign") != 0
        tfMotorDetected = defaults.double(forKey: "tfMotorSign") != 0
        installer = BridgeInstaller(payload: Self.bundledBridge() ?? Data())

        // Stop before timers, discovery, preference writes or any hardware startup.
        if preview { return }
        bridge.strength = strength / 100
        bridge.reverseDirectional = reverse
        bridge.wheel = wheel
        let sign = defaults.double(forKey: "motorSign")
        bridge.motorSign = sign == 0 ? 1 : sign
        let tfSign = defaults.double(forKey: "tfMotorSign")
        // The stream's torque is offset binary with 0xFFFF = full right, so +1 is right on every
        // G923, unlike the classic command, whose direction varies. Only Detect overrides it.
        bridge.tfMotorSign = tfSign != 0 ? tfSign : 1
        pushTrueForce()
        bridge.onCalibrated = { [weak self] sign, viaTF in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.calibrated(sign, viaTF: viaTF) } }
        }
        timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = self.bridge.status
                self.presentationTime = ProcessInfo.processInfo.systemUptime
                if s != self.status { self.status = s }
                if !self.showsTrueForce && self.settingsTab == .trueForce { self.settingsTab = .wheel }
                if s.running != self.icon.running { self.icon.running = s.running }
                if s.gameActive != self.icon.gameActive { self.icon.gameActive = s.gameActive }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        if autoStart { bridge.start() }
        rescan()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = self.defaults.bool(forKey: "showInMenuBar")
                if value != self.showInMenuBar { self.showInMenuBar = value }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [bridge] _ in bridge.stop() }
        if !defaults.bool(forKey: "onboarded") || !showInMenuBar {
            defaults.set(true, forKey: "onboarded")
            DispatchQueue.main.async { MainActor.assumeIsolated { self.showSettings(.games) } }
        }
    }

    /// The DLL shipped inside the app (Contents/Resources), or the dev build next to the sources.
    static func bundledBridge() -> Data? {
        if let url = Bundle.main.url(forResource: "dinput8", withExtension: "dll"), let data = try? Data(contentsOf: url) { return data }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("bridge/build/dinput8.dll")) { return data }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: force feedback

    var running: Bool { status.running }
    var installedGames: [GameEntry] { games.filter { gameStatus[$0.id] == .installed || gameStatus[$0.id] == .outdated } }
    func toggleRunning() { guard !isPreview else { return }; if status.running { bridge.stop() } else { bridge.start() }; status = bridge.status }
    func detectDirection() { guard !isPreview else { return }; bridge.requestCalibration() }
    private func pushTrueForce() {
        guard !isPreview else { return }
        defaults.set(tfEnabled, forKey: "tfEnabled")
        defaults.set(tfStrength, forKey: "tfStrength"); defaults.set(tfEngine, forKey: "tfEngine")
        defaults.set(tfRoad, forKey: "tfRoad"); defaults.set(tfSlip, forKey: "tfSlip")
        bridge.trueForce = .init(enabled: tfEnabled, strength: tfStrength / 100, engine: tfEngine / 100, road: tfRoad / 100, slip: tfSlip / 100)
    }
    private func calibrated(_ sign: Double?, viaTF: Bool) {
        guard let sign else { return }
        defaults.set(sign, forKey: viaTF ? "tfMotorSign" : "motorSign")
        if viaTF { tfMotorDetected = true } else { motorDetected = true }
    }

    var needsInputPermission: Bool { status.message.contains("Input Monitoring") }
    func openInputMonitoringSettings() {
        guard !isPreview else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        get { !isPreview && SMAppService.mainApp.status == .enabled }
        set {
            guard !isPreview else { return }
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { notice = Notice(title: "Couldn't change Open at Login", message: error.localizedDescription) }
            objectWillChange.send()
        }
    }

    // MARK: settings window

    func showSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab == .trueForce && !showsTrueForce ? .wheel : tab }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = isPreview ? "crossover-ffb Demo — No Hardware" : "crossover-ffb"
            // Sidebar runs the full height under a transparent title bar, as in System Settings.
            window.titleVisibility = isPreview ? .visible : .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(self))
            window.setContentSize(NSSize(width: 1100, height: 780))
            window.minSize = NSSize(width: 920, height: 640)
            window.center()
            window.setFrameAutosaveName("SettingsWindow2")
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Deterministic demo data only; never starts a worker or touches shared memory.
    func setPreviewWheel(_ wheel: BridgeWheelModel?) {
        guard isPreview else { return }
        var status = FFBBridge.Status()
        status.running = true
        status.wheelConnected = wheel != nil
        status.wheelModel = wheel
        status.trueForceAvailable = wheel == .g923
        status.gameActive = wheel != nil
        status.effectsPlaying = wheel == nil ? 0 : 3
        status.output = wheel == nil ? 0 : 0.24
        status.rawSteering = wheel == nil ? 32768 : 35025
        status.input.connected = wheel != nil
        status.input.wheelModel = wheel
        status.input.throttle = wheel == nil ? 65535 : 27525
        status.input.brake = 65535
        status.input.clutch = wheel == nil ? 65535 : 57670
        status.tfStreaming = wheel == .g923
        status.telemetry = wheel == .g923
        status.trueForce = wheel == .g923 ? "TrueForce streaming." : "TrueForce unavailable."
        status.message = wheel == nil ? "Waiting for a wheel…" : "Game connected — force feedback active."
        status.gameProcessID = wheel == nil ? 0 : 4242
        self.status = status
        if !showsTrueForce && settingsTab == .trueForce { settingsTab = .overview }
    }

    func prepareDemoMenu() {
        guard isPreview, demoStatusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "FFB Demo"
        item.button?.target = self
        item.button?.action = #selector(toggleDemoMenu)
        demoStatusItem = item
    }

    @objc private func toggleDemoMenu() {
        if demoPopover?.isShown == true { demoPopover?.performClose(nil) }
        else { showDemoMenu() }
    }

    func showDemoMenu() {
        guard isPreview else { return }
        prepareDemoMenu()
        guard let button = demoStatusItem?.button else { return }
        if demoPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 360, height: 570)
            popover.contentViewController = NSHostingController(rootView: MenuView().environmentObject(self))
            demoPopover = popover
        }
        if let host = button.window, host.frame.height > 0 {
            demoPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let content = settingsWindow?.contentView {
            // macOS can hide status items when the menu bar runs out of room.
            demoPopover?.show(relativeTo: NSRect(x: content.bounds.maxX - 100, y: content.bounds.maxY - 64, width: 80, height: 24),
                              of: content, preferredEdge: .minY)
        }
        demoPopover?.contentViewController?.view.window?.makeKey()
    }

    // MARK: games

    private var customGames: [GameEntry] {
        get { (defaults.data(forKey: "customGames")).flatMap { try? JSONDecoder().decode([GameEntry].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "customGames") }
    }
    private var hiddenGames: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenGames") ?? []) }
        set { defaults.set(Array(newValue), forKey: "hiddenGames") }
    }

    /// Synchronous scan, for --snapshot.
    func scanNow() {
        guard !isPreview else { return }
        games = customGames + GameLibrary().discover().filter { !hiddenGames.contains($0.id) }
        gameStatus = Dictionary(games.map { ($0.id, installer.status($0)) }, uniquingKeysWith: { a, _ in a })
        for id in Set(games.compactMap(\.steamAppID)) { artwork[id] = GameArtwork.cover(appID: id) }
    }

    /// Fetches cover art for games that do not have it yet (in the background).
    func loadArtwork() {
        guard !isPreview else { return }
        let wanted = Set(games.compactMap(\.steamAppID)).subtracting(artworkRequested)
        artworkRequested.formUnion(wanted)
        for id in wanted {
            DispatchQueue.global(qos: .utility).async {
                let image = GameArtwork.cover(appID: id)
                DispatchQueue.main.async { MainActor.assumeIsolated { if let image { self.artwork[id] = image } else { self.artworkRequested.remove(id) } } }
            }
        }
    }

    func rescan() {
        guard !isPreview else { return }
        guard !scanning else { return }
        scanning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated { if self.scanning { self.slowScan = true } }
        }
        let custom = customGames, hidden = hiddenGames, installer = installer
        DispatchQueue.global(qos: .userInitiated).async {
            let found = GameLibrary().discover().filter { !hidden.contains($0.id) }
            let all = custom + found.filter { f in !custom.contains { $0.id == f.id } }
            let statuses = Dictionary(all.map { ($0.id, installer.status($0)) }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.games = all
                    self.gameStatus = statuses
                    self.scanning = false
                    self.slowScan = false
                    self.loadArtwork()
                }
            }
        }
    }

    func refreshStatus(_ game: GameEntry) { gameStatus[game.id] = installer.status(game) }

    func install(_ game: GameEntry) { run(game, verb: "install") { try $0.install(game) } }
    func uninstall(_ game: GameEntry) { run(game, verb: "uninstall") { try $0.uninstall(game) } }

    private func run(_ game: GameEntry, verb: String, _ action: @escaping @Sendable (BridgeInstaller) throws -> Void) {
        guard !isPreview else { return }
        busyGame = game.id
        let installer = installer
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try action(installer) } catch { failure = error.localizedDescription }
            let status = installer.status(game)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busyGame = nil
                    self.gameStatus[game.id] = status
                    if let failure { self.notice = Notice(title: "Couldn't \(verb) \(game.name)", message: failure) }
                }
            }
        }
    }

    func revealInFinder(_ game: GameEntry) { NSWorkspace.shared.activateFileViewerSelecting([game.executable]) }

    /// Lets the user add any 64-bit Windows game: pick its exe, the prefix is worked out when possible.
    func addGame(replacing original: GameEntry? = nil) {
        guard !isPreview else { return }
        let panel = NSOpenPanel()
        panel.title = original == nil ? "Choose the game's .exe" : "Choose the .exe that actually runs \(original!.name)"
        panel.message = "Pick the Windows program of the game (for Unreal Engine games, the …-Win64-Shipping.exe inside Binaries/Win64)."
        panel.allowedContentTypes = [.init(filenameExtension: "exe")!]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        if let original { panel.directoryURL = original.executable.deletingLastPathComponent() }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let exe = panel.url else { return }
        guard PE.isWin64(exe) else {
            notice = Notice(title: "Not a 64-bit Windows game", message: "\(exe.lastPathComponent) is not a 64-bit Windows executable. Only 64-bit DirectInput games are supported.")
            return
        }
        if let original {
            add(exe: exe, prefix: original.prefix, name: original.name, source: original.source, hiding: original)
        } else if let prefix = GameLibrary().prefix(for: exe, among: games) {
            add(exe: exe, prefix: prefix)
        } else {
            prefixChoices = GameLibrary().prefixes()
            pendingCustomExe = exe // the Games tab shows a prefix picker
        }
    }

    func choosePrefixFolder() -> WinePrefix? {
        guard !isPreview else { return nil }
        let panel = NSOpenPanel()
        panel.title = "Choose the Wine prefix or CrossOver bottle"
        panel.message = "The folder that contains user.reg and drive_c."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let prefix = WinePrefix(url: url, label: url.lastPathComponent)
        guard prefix.exists else {
            notice = Notice(title: "Not a Wine prefix", message: "\(url.path) has no user.reg. Choose the bottle / prefix folder itself.")
            return nil
        }
        return prefix
    }

    func add(exe: URL, prefix: WinePrefix, name: String? = nil, source: String? = nil, hiding original: GameEntry? = nil) {
        guard !isPreview else { return }
        let known = KnownGame.matching(executable: exe)
        let entry = GameEntry(name: name ?? known?.name ?? exe.deletingPathExtension().lastPathComponent, executable: exe, prefix: prefix,
                              source: source ?? prefix.label, known: known != nil, telemetry: known?.telemetry ?? false, custom: true,
                              steamAppID: original?.steamAppID ?? known?.steamAppID)
        customGames = customGames.filter { $0.id != entry.id && $0.id != original?.id } + [entry]
        if let original, !original.custom { hiddenGames.insert(original.id) }
        pendingCustomExe = nil
        rescan()
    }

    func remove(_ game: GameEntry) {
        guard !isPreview else { return }
        if game.custom { customGames = customGames.filter { $0.id != game.id } } else { hiddenGames.insert(game.id) }
        rescan()
    }
    func showHiddenGames() { guard !isPreview else { return }; hiddenGames = []; rescan() }
}
