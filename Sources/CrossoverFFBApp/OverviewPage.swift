import SwiftUI
import WheelCore

struct OverviewPage: View {
    @EnvironmentObject var model: AppModel
    private var connected: Bool { model.presentation.isConnected }
    var body: some View {
        Page(title: "Your driving setup", subtitle: connected ? "Everything you need for the next session." : "Connect your wheel over USB. Your settings will be here when you return.") {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.presentation.title).font(.headline)
                            Text(connected ? "PlayStation / PC · USB" : "G29 & G923 supported").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(connected ? "CONNECTED" : "OFFLINE").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(connected ? Color.mint : .secondary)
                    }
                    RotationDial(range: model.wheel.range, steering: model.status.rawSteering,
                                 connected: connected, model: model.presentation.visibleModel)
                    Button { model.settingsTab = .wheel } label: {
                        HStack { Text("Steering & pedal settings"); Spacer(); Image(systemName: "arrow.up.right") }
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }.padding(20).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 19) {
                    Text("Live inputs").font(.headline)
                    pedal("Accelerator", model.status.input.throttle, .mint)
                    pedal("Brake", model.status.input.brake, .orange)
                    pedal("Clutch", model.status.input.clutch, .blue)
                    Divider()
                    HStack {
                        Text("Input monitor").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.settingsTab = .inputs } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain)
                    }
                    Text(connected ? "Input is forwarded to your game in real time." : "Waiting for wheel input.")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }.padding(20).frame(width: 225).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Force feedback").font(.headline)
                        Spacer()
                        Text(connected && model.status.gameActive ? "Active session" : "Standby").font(.caption).foregroundStyle(.secondary)
                    }
                    ForceMeter(value: connected ? model.status.output : 0)
                    HStack {
                        Text("Strength").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.strength, in: 0...100)
                        Text("\(Int(model.strength))%").font(.caption).monospacedDigit()
                    }
                }.padding(20).frame(maxWidth: .infinity).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                if model.showsTrueForce {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("TrueForce").font(.headline)
                            Spacer()
                            Toggle("TrueForce", isOn: $model.tfEnabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        }
                        Text("Engine, road & kerb detail").font(.caption).foregroundStyle(.secondary)
                        Text("Simulated from game telemetry").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Button("Adjust effects →") { model.settingsTab = .trueForce }.buttonStyle(.plain).font(.caption)
                    }.padding(20).frame(width: 225).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("trueForce.controls")
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                Text(model.status.gameActive && connected ? "Game connected · \(model.status.effectsPlaying) effects playing" : "Ready for your next drive")
                Spacer()
                Button("Game library →") { model.settingsTab = .games }.buttonStyle(.plain)
            }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
        }
    }
    private func pedal(_ label: String, _ raw: UInt32, _ color: Color) -> some View {
        let value = connected ? 1 - Double(raw) / 65535 : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Text(label); Spacer(); Text(connected ? "\(Int(value * 100))%" : "—").monospacedDigit() }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.06)).overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(0.8)).frame(width: geo.size.width * max(0, min(1, value)))
                }
            }.frame(height: 5)
        }
    }
}
