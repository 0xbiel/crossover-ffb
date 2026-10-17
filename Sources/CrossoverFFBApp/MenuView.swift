import AppKit
import SwiftUI
import WheelCore

// Menu bar dropdown. Following Apple's HIG: content (status, force, games) sits on standard
// materials; Liquid Glass is kept to the functional layer (the header badge and the action
// buttons), grouped in one container and tinted only to signal state. Corners are concentric:
// 18 pt panel padding around 26 pt cards inside the system's popover shape.

private enum Metric {
    static let width: CGFloat = 352
    static let padding: CGFloat = 18
    static let card: CGFloat = 26
    static let spacing: CGFloat = 14
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.spacing) {
            header
            if model.needsInputPermission { permissionCard }
            liveCard
            controlsCard
            footer
        }
        .padding(Metric.padding)
        .frame(width: Metric.width)
    }

    // MARK: header

    private var stateColor: Color {
        model.status.gameActive ? .green : model.status.wheelConnected ? .accentColor : .secondary
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(model.status.running ? .white : .secondary)
                .frame(width: 44, height: 44)
                .glassBadge(tint: model.status.running ? stateColor : nil)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("crossover-ffb").font(.headline)
                Text(headline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("Force feedback", isOn: Binding(get: { model.status.running }, set: { _ in model.toggleRunning() }))
                .toggleStyle(.switch).labelsHidden()
                .help(model.status.running ? "Turn the wheel bridge off" : "Turn the wheel bridge on")
        }
    }

    private var headline: String {
        let s = model.status
        if !s.running { return "Off" }
        if s.gameActive { return s.tfStreaming ? "In game · TrueForce" : "In game" }
        if s.wheelConnected { return "Ready, waiting for a game" }
        return "Waiting for the wheel"
    }

    // MARK: live status

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Chip(title: "Wheel", symbol: "steeringwheel", on: model.status.wheelConnected)
                Chip(title: "Game", symbol: "flag.checkered", on: model.status.gameActive)
                Chip(title: "TrueForce", symbol: "waveform", on: model.status.tfStreaming)
            }
            if model.status.gameActive {
                ForceMeter(value: model.status.output)
                if model.status.tfStreaming {
                    Label(model.status.telemetry ? "Receiving game telemetry" : "No telemetry from this game", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.installedGames.isEmpty {
                ReadyGames(games: model.installedGames)
            } else {
                Text(model.status.running ? "Install the bridge into a game to get force feedback." : "Turn on the bridge to use your wheel in games.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        .animation(.easeInOut(duration: 0.25), value: model.status.gameActive)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Monitoring needed", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            Text("Allow crossover-ffb in Privacy & Security to read the wheel.").font(.callout).foregroundStyle(.secondary)
            Button("Open Privacy Settings") { model.openInputMonitoringSettings() }.glassButton(prominent: true)
        }
        .card()
    }

    // MARK: controls

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Strength")
                    Spacer()
                    Text("\(Int(model.strength.rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack(spacing: 8) {
                    Image(systemName: "dial.low").foregroundStyle(.secondary)
                    Slider(value: $model.strength, in: 0...100).controlSize(.small)
                        .accessibilityLabel("Force feedback strength")
                    Image(systemName: "dial.high").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(model.tfEnabled ? Color.accentColor : .secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TrueForce").font(.callout)
                    Text("Engine, road, kerbs and ABS detail").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("TrueForce", isOn: $model.tfEnabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }
        .card()
    }

    // MARK: footer

    private var footer: some View {
        GlassGroup {
            HStack(spacing: 8) {
                if model.installedGames.isEmpty && !model.scanning {
                    Button { open(.games) } label: { Label("Set Up Games", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                        .glassButton(prominent: true)
                } else {
                    Button { open(.games) } label: { Label("Library", systemImage: "square.grid.2x2").frame(maxWidth: .infinity) }
                        .glassButton()
                }
                Button { open(nil) } label: { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity) }
                    .glassButton()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .glassButton(circle: true)
                    .help("Quit crossover-ffb")
                    .accessibilityLabel("Quit crossover-ffb")
            }
            .controlSize(.large)
        }
    }

    private func open(_ tab: AppModel.SettingsTab?) {
        dismiss()
        model.showSettings(tab)
    }
}

/// Small covers of the games that have the bridge, so it is clear what is ready to play.
private struct ReadyGames: View {
    @EnvironmentObject var model: AppModel
    let games: [GameEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ready to play").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(games.prefix(5)) { game in
                    VStack(spacing: 4) {
                        cover(game)
                            .frame(width: 48, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                            .overlay(alignment: .topTrailing) {
                                if model.gameStatus[game.id] == .outdated {
                                    Image(systemName: "arrow.up.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .orange).font(.caption).offset(x: 4, y: -4)
                                }
                            }
                            .help(game.name)
                    }
                }
                if games.count > 5 { Text("+\(games.count - 5)").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
    }
    @ViewBuilder func cover(_ game: GameEntry) -> some View {
        if let id = game.steamAppID, let image = model.artwork[id] {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: GameCard.colors(for: game.name), startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(game.name.prefix(1))).font(.headline).foregroundStyle(.white)
            }
        }
    }
}

private struct Chip: View {
    let title: String, symbol: String, on: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption2.weight(.semibold))
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .foregroundStyle(on ? Color.green : .secondary)
        .background(on ? Color.green.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "connected" : "not connected")
    }
}

/// Bipolar force meter: grows left or right from the centre line.
struct ForceMeter: View {
    let value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Force").font(.callout)
                Spacer()
                Text(String(format: "%@%.0f%%", value < -0.005 ? "← " : value > 0.005 ? "→ " : "", abs(value) * 100))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let half = geo.size.width / 2, w = half * min(1, abs(value))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: abs(value) > 0.95 ? [.orange, .red] : [.accentColor.opacity(0.7), .accentColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, w))
                        .offset(x: value < 0 ? half - w : half)
                    Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1).offset(x: half)
                }
            }
            .frame(height: 10)
            .animation(.linear(duration: 0.07), value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Force")
        .accessibilityValue("\(Int(abs(value) * 100)) percent \(value < 0 ? "left" : "right")")
    }
}

// MARK: Liquid Glass with fallbacks for macOS 13–15

extension View {
    /// Content-layer card: standard material, continuous corners.
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Metric.card, style: .continuous))
    }

    @ViewBuilder func glassBadge(tint: Color?) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint?.opacity(0.85)).interactive(), in: .circle)
        } else {
            background(tint ?? Color.primary.opacity(0.1), in: Circle())
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false, circle: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent).buttonBorderShape(circle ? .circle : .capsule) }
            else { buttonStyle(.glass).buttonBorderShape(circle ? .circle : .capsule) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Groups neighbouring glass elements so they render and morph as one surface (macOS 26+).
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 8) { content } } else { content }
    }
}
