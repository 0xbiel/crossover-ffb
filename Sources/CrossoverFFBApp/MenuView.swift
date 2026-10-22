import AppKit
import SwiftUI
import WheelCore

// Compact status panel: aligned readings, quiet dividers and a small action footer.

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var connected: Bool { model.presentation.isConnected }
    private var angle: Double { WheelPresentation.angle(steering: model.status.rawSteering, range: model.wheel.range) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "steeringwheel").font(.title2).foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("crossover-ffb").font(.system(size: 14, weight: .semibold))
                    Text(model.presentation.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(connected ? Color.mint : Color.secondary).frame(width: 6, height: 6)
                Text(connected ? "Connected" : "Offline").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.bottom, 18)
            Divider().opacity(0.5)
            HStack(spacing: 18) {
                WheelRim(model: model.presentation.visibleModel)
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(connected ? angle : 0))
                VStack(alignment: .leading, spacing: 5) {
                    Text(connected ? String(format: "%+.0f°", angle) : "—")
                        .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(connected ? "Steering · \(model.wheel.range)° range" : "Connect your wheel over USB")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 17)
            VStack(spacing: 13) {
                meter("Accelerator", value: 1 - Double(model.status.input.throttle) / 65535, color: .mint)
                meter("Brake", value: 1 - Double(model.status.input.brake) / 65535, color: .orange)
                meter("Clutch", value: 1 - Double(model.status.input.clutch) / 65535, color: .blue)
            }.padding(.bottom, 18)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Force feedback").fontWeight(.medium)
                    Spacer()
                    Text(connected && model.status.gameActive ? "Active" : "Standby").foregroundStyle(.secondary)
                }.font(.system(size: 12))
                ForceMeter(value: connected ? model.status.output : 0)
                HStack {
                    Text("Strength").foregroundStyle(.secondary)
                    Slider(value: $model.strength, in: 0...100).controlSize(.mini)
                    Text("\(Int(model.strength))%").monospacedDigit().frame(width: 32, alignment: .trailing)
                }.font(.system(size: 11))
                if model.showsTrueForce {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(.mint)
                        Text("TrueForce")
                        Spacer()
                        Toggle("TrueForce", isOn: $model.tfEnabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }.font(.system(size: 12)).accessibilityIdentifier("trueForce.controls")
                }
            }.padding(.vertical, 16)
            if model.needsInputPermission {
                Button("Allow Input Monitoring…") { model.openInputMonitoringSettings() }.padding(.bottom, 12)
            }
            Divider().opacity(0.5)
            VStack(spacing: 2) {
                Button { open(.overview) } label: { actionRow("Open wheel dashboard", "slider.horizontal.3", "↗") }
                Button { open(.games) } label: { actionRow("Game library", "square.grid.2x2", "\(model.installedGames.count) ready") }
                HStack {
                    Image(systemName: "power").frame(width: 16).foregroundStyle(.secondary)
                    Text("Wheel bridge")
                    Spacer()
                    Toggle("Wheel bridge", isOn: Binding(get: { model.running }, set: { _ in model.toggleRunning() }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }.help("Quit crossover-ffb")
                }.font(.system(size: 12)).padding(.vertical, 7)
            }.buttonStyle(.plain).padding(.top, 10)
            if model.isPreview { Text("PREVIEW · NO HARDWARE").font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(.secondary).padding(.top, 8) }
        }
        .padding(20).frame(width: 360)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.055, green: 0.09, blue: 0.15).opacity(0.82)))
        }
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.09)))
        .environment(\.colorScheme, .dark).tint(.mint)
    }
    private func meter(_ name: String, value: Double, color: Color) -> some View {
        HStack(spacing: 12) {
            Text(name).frame(width: 76, alignment: .leading).foregroundStyle(.secondary)
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.08)).overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(0.8)).frame(width: connected ? geo.size.width * max(0, min(1, value)) : 0)
                }
            }.frame(height: 4)
            Text(connected ? "\(Int(value * 100))%" : "—").monospacedDigit().frame(width: 32, alignment: .trailing)
        }.font(.system(size: 11))
    }
    private func actionRow(_ title: String, _ symbol: String, _ value: String) -> some View {
        HStack {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(.vertical, 8).contentShape(Rectangle())
    }
    private func open(_ tab: AppModel.SettingsTab) { dismiss(); model.showSettings(tab) }
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
    @ViewBuilder func glassBadge(tint: Color?) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint?.opacity(0.85)).interactive(), in: .circle)
        } else {
            background(tint ?? Color.primary.opacity(0.1), in: Circle())
        }
    }

    func glassButton(prominent: Bool = false, circle: Bool = false) -> some View {
        buttonStyle(WorkspaceButtonStyle(prominent: prominent, circle: circle))
    }
}

/// Groups neighbouring glass elements so they render and morph as one surface (macOS 26+).
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 8) { content } } else { content }
    }
}


private struct WorkspaceButtonStyle: ButtonStyle {
    let prominent: Bool
    let circle: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, circle ? 9 : 12).padding(.vertical, 8)
            .background(prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: circle ? 20 : 7))
            .opacity(enabled ? 1 : 0.4)
    }
}
