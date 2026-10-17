import AppKit
import SwiftUI
import WheelCore

// The large window: a System Settings–style sidebar (Liquid Glass on macOS 26 comes from the
// system sidebar itself) and pages built from rounded section cards on standard materials.

enum Radius {
    static let card: CGFloat = 22
    static let cover: CGFloat = 16
    static let icon: CGFloat = 8
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 280)
        } detail: {
            Group {
                switch model.settingsTab {
                case .games: LibraryPage()
                case .forceFeedback: ForceFeedbackPage()
                case .trueForce: TrueForcePage()
                case .inputs: InputsPage()
                case .general: GeneralPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 780, minHeight: 540)
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }
}

// MARK: sidebar

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { Optional(model.settingsTab) }, set: { if let t = $0 { model.settingsTab = t } })) {
            Section {
                SidebarStatus()
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
            }
            Section {
                item(.games, "Library", "square.grid.2x2.fill", .indigo)
            }
            Section("Wheel") {
                item(.forceFeedback, "Force Feedback", "steeringwheel", .blue)
                item(.trueForce, "TrueForce", "waveform", .purple)
                item(.inputs, "Wheel Input", "dial.medium.fill", .teal)
            }
            Section("App") {
                item(.general, "General", "gearshape.fill", .gray)
            }
        }
        .listStyle(.sidebar)
    }

    func item(_ tab: AppModel.SettingsTab, _ title: String, _ symbol: String, _ color: Color) -> some View {
        Label { Text(title) } icon: { IconTile(symbol: symbol, color: color, size: 22) }
            .tag(tab)
    }
}

/// Small summary at the top of the sidebar: is everything connected?
private struct SidebarStatus: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.status
        HStack(spacing: 10) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(s.gameActive ? Color.green : s.wheelConnected ? Color.accentColor : Color.secondary.opacity(0.6)))
            VStack(alignment: .leading, spacing: 1) {
                Text("crossover-ffb").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                Text(!s.running ? "Off" : s.gameActive ? "In game" : s.wheelConnected ? "Wheel ready" : "No wheel")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("On", isOn: Binding(get: { model.status.running }, set: { _ in model.toggleRunning() }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

/// Coloured rounded-square symbol tile, as in System Settings.
struct IconTile: View {
    let symbol: String, color: Color
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(color.gradient))
    }
}

// MARK: page building blocks

struct Page<Accessory: View, Content: View>: View {
    let title: String, subtitle: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.largeTitle.weight(.bold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    accessory
                }
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

extension Page where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// Rounded section card with an optional heading and footer.
struct Card<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline).padding(.leading, 6) }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.quaternary.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// One row in a card: icon tile, title and subtitle, trailing control.
struct Row<Trailing: View>: View {
    var symbol: String? = nil
    var color: Color = .accentColor
    let title: String
    var subtitle: String? = nil
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let symbol { IconTile(symbol: symbol, color: color) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.vertical, 10)
            if divider { Divider().padding(.leading, symbol == nil ? 0 : 40) }
        }
    }
}

struct PercentSlider: View {
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: 0...100).frame(width: 220)
            Text("\(Int(value.rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: Library

struct LibraryPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(title: "Library", subtitle: "Install the wheel bridge into the Windows games you play through NotProton, Steam or CrossOver, on any disk. Quit a game before installing or uninstalling it.") {
            GlassGroup {
                HStack(spacing: 8) {
                    Button { model.rescan() } label: {
                        if model.scanning { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .glassButton(circle: true).help("Look for games again").disabled(model.scanning)
                    Button { model.addGame() } label: { Label("Add Game", systemImage: "plus") }
                        .glassButton(prominent: true)
                }
                .controlSize(.large)
            }
        } content: {
            if let exe = model.pendingCustomExe { PrefixPicker(exe: exe) }
            if model.games.isEmpty {
                EmptyLibrary()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 20, alignment: .top)], alignment: .leading, spacing: 26) {
                    ForEach(model.games) { game in GameCard(game: game) }
                }
            }
            Label("After installing, choose “G923 Racing Wheel for PlayStation and PC” in the game's controls and calibrate it there.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

private struct EmptyLibrary: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            IconTile(symbol: model.scanning ? "magnifyingglass" : "gamecontroller.fill", color: .indigo, size: 56)
            Text(model.scanning ? "Looking for games…" : "No Windows games found yet").font(.title3.weight(.semibold))
            Text("Install a game and launch it once through NotProton, Steam or CrossOver, then look again, or add it yourself.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button { model.addGame() } label: { Label("Add Game…", systemImage: "plus") }.glassButton(prominent: true).controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

/// One game in the library grid: Steam-style 2:3 cover with status and the install action.
struct GameCard: View {
    @EnvironmentObject var model: AppModel
    let game: GameEntry
    @State private var hovering = false
    var status: BridgeInstaller.Status { model.gameStatus[game.id] ?? .notInstalled }
    var busy: Bool { model.busyGame == game.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.cover, style: .continuous))
                .overlay(alignment: .topTrailing) { if status == .installed { installedMark } }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        if game.telemetry { Tag(text: "TrueForce", color: .purple, solid: true) }
                        if !game.known { Tag(text: "untested", color: .orange, solid: true) }
                    }
                    .padding(10)
                }
                .overlay(RoundedRectangle(cornerRadius: Radius.cover, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 14 : 7, y: hovering ? 8 : 4)
                .scaleEffect(hovering ? 1.025 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
                .onHover { hovering = $0 }
                .help(game.executable.path + "\nPrefix: " + game.prefix.url.path)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(game.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 2)
            StatusBadge(status: status).padding(.horizontal, 2)
            if busy { ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 28) } else { actions }
        }
        .contextMenu {
            Button("Show in Finder") { model.revealInFinder(game) }
            Button("Use a Different .exe…") { model.addGame(replacing: game) }
            Divider()
            Button("Remove from Library") { model.remove(game) }.disabled(status == .installed || status == .outdated)
        }
    }

    @ViewBuilder var cover: some View {
        if let id = game.steamAppID, let image = model.artwork[id] {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: Self.colors(for: game.name), startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 10) {
                    Image(systemName: game.known ? "flag.checkered" : "steeringwheel").font(.system(size: 34, weight: .semibold))
                    Text(game.name).font(.headline).multilineTextAlignment(.center).padding(.horizontal, 10)
                }
                .foregroundStyle(.white.opacity(0.92))
            }
        }
    }

    var installedMark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .green)
            .shadow(radius: 3).padding(10)
    }

    /// Stable per-name colours for games without artwork.
    static func colors(for name: String) -> [Color] {
        let hue = Double(name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
        return [Color(hue: hue, saturation: 0.55, brightness: 0.55), Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.3)]
    }

    @ViewBuilder var actions: some View {
        GlassGroup {
            HStack(spacing: 6) {
                switch status {
                case .installed:
                    Button { model.uninstall(game) } label: { Text("Uninstall").frame(maxWidth: .infinity) }.glassButton()
                case .outdated:
                    Button { model.install(game) } label: { Text("Update").frame(maxWidth: .infinity) }.glassButton(prominent: true)
                    Button { model.uninstall(game) } label: { Image(systemName: "trash") }.glassButton(circle: true).help("Uninstall")
                case .notInstalled, .otherDLL:
                    Button { model.install(game) } label: { Text("Install").frame(maxWidth: .infinity) }.glassButton(prominent: true)
                case .needsFirstLaunch:
                    Button { model.refreshStatus(game) } label: { Text("Check Again").frame(maxWidth: .infinity) }.glassButton()
                case .missing:
                    Button { model.remove(game) } label: { Text("Remove").frame(maxWidth: .infinity) }.glassButton()
                }
            }
        }
    }
}

struct Tag: View {
    let text: String, color: Color
    var solid = false
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).fixedSize().padding(.horizontal, 8).padding(.vertical, 3)
            .background(solid ? color.opacity(0.9) : color.opacity(0.15), in: Capsule())
            .foregroundStyle(solid ? .white : color)
    }
}

struct StatusBadge: View {
    let status: BridgeInstaller.Status
    var body: some View {
        let (text, icon, color): (String, String, Color) = switch status {
        case .installed: ("Installed", "checkmark.circle.fill", .green)
        case .outdated: ("Update available", "arrow.up.circle.fill", .orange)
        case .notInstalled: ("Not installed", "circle.dashed", .secondary)
        case .otherDLL: ("Another dinput8.dll is there (kept as backup)", "exclamationmark.circle", .orange)
        case .needsFirstLaunch: ("Launch the game once first", "play.circle", .secondary)
        case .missing: ("Game not found", "questionmark.circle", .red)
        }
        Label(text, systemImage: icon).font(.caption).foregroundStyle(color).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

struct PrefixPicker: View {
    @EnvironmentObject var model: AppModel
    let exe: URL
    @State private var selection = 0
    var body: some View {
        Card(title: "Where does \(exe.lastPathComponent) run?", footer: "Pick the CrossOver bottle or NotProton/Steam prefix the game runs in, or choose its folder (the one with user.reg and drive_c).") {
            if !model.prefixChoices.isEmpty {
                Row(symbol: "shippingbox.fill", color: .brown, title: "Wine prefix", divider: false) {
                    Picker("Prefix", selection: $selection) {
                        ForEach(Array(model.prefixChoices.enumerated()), id: \.offset) { i, p in Text(p.label).tag(i) }
                    }
                    .labelsHidden().frame(maxWidth: 320)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingCustomExe = nil }.glassButton()
                Button("Choose Folder…") { if let p = model.choosePrefixFolder() { model.add(exe: exe, prefix: p) } }.glassButton()
                if !model.prefixChoices.isEmpty {
                    Button("Add Game") { model.add(exe: exe, prefix: model.prefixChoices[selection]) }.glassButton(prominent: true)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: Force feedback

struct ForceFeedbackPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.status
        Page(title: "Force Feedback", subtitle: "How strongly the game's forces reach your wheel.") {
            Card {
                Row(symbol: "power", color: s.running ? .green : .gray, title: "Wheel bridge", subtitle: s.message) {
                    Toggle("Wheel bridge", isOn: Binding(get: { s.running }, set: { _ in model.toggleRunning() })).toggleStyle(.switch).labelsHidden()
                }
                Row(symbol: "flag.checkered", color: s.gameActive ? .green : .gray, title: "Game",
                    subtitle: s.gameActive ? "Windows process \(s.gameProcessID) · \(s.effectsPlaying) effect\(s.effectsPlaying == 1 ? "" : "s") playing" : "Not connected",
                    divider: s.gameActive) { EmptyView() }
                if s.gameActive { ForceMeter(value: s.output).padding(.vertical, 12) }
            }
            Card(title: "Feel") {
                Row(symbol: "dial.high.fill", color: .blue, title: "Strength", subtitle: "Overall force sent to the motor") {
                    PercentSlider(value: $model.strength)
                }
                Row(symbol: "arrow.left.arrow.right", color: .orange, title: "Reverse game force direction",
                    subtitle: "Turn on if forces push the wheel away from centre in corners", divider: false) {
                    Toggle("Reverse", isOn: $model.reverse).toggleStyle(.switch).labelsHidden()
                }
            }
            Card(title: "Motor direction", footer: "Do this once with no game running and your hands off the wheel. It gives a short gentle push to learn which way the motor turns, so springs and dampers centre the wheel instead of fighting you.") {
                Row(symbol: "scope", color: .pink, title: "Detect motor direction", subtitle: model.motorDetected ? "Detected" : "Not detected yet", divider: false) {
                    Button("Detect") { model.detectDirection() }.glassButton()
                        .disabled(!s.wheelConnected || (s.gameActive && !s.tfStreaming))
                }
            }
        }
    }
}

// MARK: TrueForce

struct TrueForcePage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.status
        Page(title: "TrueForce", subtitle: "High-frequency detail on top of force feedback for the Logitech G923, made from game telemetry.") {
            Card {
                Row(symbol: "waveform", color: .purple, title: "Simulated TrueForce",
                    subtitle: s.trueForce + (s.tfStreaming ? (s.telemetry ? " Receiving telemetry." : " No telemetry from this game.") : "")) {
                    Toggle("TrueForce", isOn: $model.tfEnabled).toggleStyle(.switch).labelsHidden()
                }
                Row(symbol: "antenna.radiowaves.left.and.right", color: .indigo, title: "Telemetry",
                    subtitle: "Assetto Corsa, Assetto Corsa Competizione and AC EVO. Other games keep normal force feedback through the TrueForce stream.", divider: false) { EmptyView() }
            }
            Card(title: "Mix") {
                Row(symbol: "speaker.wave.3.fill", color: .purple, title: "Overall") { PercentSlider(value: $model.tfStrength) }
                Row(symbol: "engine.combustion.fill", color: .red, title: "Engine", subtitle: "Follows revs and throttle") { PercentSlider(value: $model.tfEngine) }
                Row(symbol: "road.lanes", color: .gray, title: "Road & kerbs", subtitle: "Surface texture, bumps and kerb rumble") { PercentSlider(value: $model.tfRoad) }
                Row(symbol: "exclamationmark.brakesignal", color: .orange, title: "Slip & ABS", subtitle: "Tyre slip judder and ABS pulses", divider: false) { PercentSlider(value: $model.tfSlip) }
            }
            .disabled(!model.tfEnabled)
            .opacity(model.tfEnabled ? 1 : 0.55)
            Card(title: "Direction", footer: "TrueForce only runs while a game is connected: start a session, pause the game, let go of the wheel, then press Detect. If the wheel stops responding after a crash, unplug its power for a few seconds.") {
                Row(symbol: "scope", color: .pink, title: "Detect TrueForce direction",
                    subtitle: model.tfMotorDetected ? "Detected" : "Not detected yet (uses the normal direction)", divider: false) {
                    Button("Detect") { model.detectDirection() }.glassButton().disabled(!s.tfStreaming)
                }
            }
        }
    }
}

// MARK: Wheel input

struct InputsPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.status
        Page(title: "Wheel Input", subtitle: "What games see from your wheel and pedals, live.") {
            Card(title: "Axes") {
                axis("Steering", "steeringwheel", .blue, s.input.steering, centred: true)
                axis("Accelerator", "arrow.up.circle.fill", .green, 65535 - s.input.throttle)
                axis("Brake", "stop.circle.fill", .red, 65535 - s.input.brake)
                axis("Clutch", "c.circle.fill", .orange, 65535 - s.input.clutch, divider: false)
            }
            Card(title: "Buttons") {
                HStack(alignment: .top, spacing: 24) {
                    DPad(hat: s.input.hat)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<3, id: \.self) { row in
                            HStack(spacing: 8) {
                                ForEach(row * 9..<min(25, row * 9 + 9), id: \.self) { i in
                                    let on = s.input.buttons & (1 << i) != 0
                                    Text("\(i + 1)").font(.caption2.weight(.semibold)).monospacedDigit()
                                        .frame(width: 30, height: 30)
                                        .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                                        .foregroundStyle(on ? .white : .secondary)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
            }
            Text("Games see a “G923 Racing Wheel for PlayStation and PC”: X steering, Y accelerator, Rz brake, Slider clutch. Calibrate and map pedals in each game's controls.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
        }
    }

    /// Pedals report 65535 released; shown as 0 % → 100 % pressed.
    func axis(_ name: String, _ symbol: String, _ color: Color, _ value: UInt32, centred: Bool = false, divider: Bool = true) -> some View {
        Row(symbol: symbol, color: color, title: name, divider: divider) {
            HStack(spacing: 10) {
                GeometryReader { geo in
                    let f = CGFloat(value) / 65535
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        if centred {
                            let w = abs(f - 0.5) * geo.size.width
                            Capsule().fill(color.gradient).frame(width: max(6, w)).offset(x: f < 0.5 ? geo.size.width / 2 - w : geo.size.width / 2)
                        } else {
                            Capsule().fill(color.gradient).frame(width: max(6, f * geo.size.width))
                        }
                    }
                }
                .frame(width: 240, height: 10)
                Text(model.status.wheelConnected ? (centred ? "\(Int((Double(value) / 65535 - 0.5) * 200))%" : "\(Int(Double(value) / 655.35))%") : "—")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct DPad: View {
    let hat: UInt32
    var body: some View {
        let dirs: [(UInt32, String, CGFloat, CGFloat)] = [(0, "chevron.up", 0, -1), (2, "chevron.right", 1, 0), (4, "chevron.down", 0, 1), (6, "chevron.left", -1, 0)]
        ZStack {
            Circle().fill(Color.primary.opacity(0.06)).frame(width: 96, height: 96)
            ForEach(dirs, id: \.0) { d in
                let on = hat < 8 && (hat == d.0 || (hat + 1) % 8 == d.0 || (hat + 7) % 8 == d.0)
                Image(systemName: d.1).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(on ? .white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(on ? Color.accentColor : Color.clear))
                    .offset(x: d.2 * 30, y: d.3 * 30)
            }
        }
        .accessibilityLabel("D-pad")
    }
}

// MARK: General

struct GeneralPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Page(title: "General", subtitle: "Startup, menu bar and permissions.") {
            Card(footer: "When the menu bar icon is hidden, open crossover-ffb again from Applications or Spotlight to get to this window.") {
                Row(symbol: "menubar.rectangle", color: .blue, title: "Show in menu bar") {
                    Toggle("Show in menu bar", isOn: $model.showInMenuBar).toggleStyle(.switch).labelsHidden()
                }
                Row(symbol: "person.crop.circle.badge.checkmark", color: .green, title: "Open at login") {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })).toggleStyle(.switch).labelsHidden()
                }
                Row(symbol: "bolt.fill", color: .yellow, title: "Turn the bridge on when the app opens", divider: false) {
                    Toggle("Auto start", isOn: $model.autoStart).toggleStyle(.switch).labelsHidden()
                }
            }
            Card(title: "Permissions") {
                Row(symbol: "hand.raised.fill", color: .orange, title: "Input Monitoring", subtitle: "Needed to read the wheel and pedals", divider: false) {
                    Button("Open Settings…") { model.openInputMonitoringSettings() }.glassButton()
                }
            }
            Card(title: "About") {
                Row(symbol: "steeringwheel", color: .indigo, title: "crossover-ffb",
                    subtitle: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")") { EmptyView() }
                Row(symbol: "cable.connector", color: .gray, title: "Supported hardware",
                    subtitle: "Logitech G923 (PlayStation/PC) and G29 over USB, with 64-bit DirectInput games run through NotProton/Steam, CrossOver or Wine.", divider: false) { EmptyView() }
            }
            HStack {
                Button("Show Hidden Games") { model.showHiddenGames() }.glassButton()
                Spacer()
                Button(role: .destructive) { NSApp.terminate(nil) } label: { Label("Quit crossover-ffb", systemImage: "power") }.glassButton()
            }
        }
    }
}
