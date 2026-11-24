import AppKit
import SwiftUI
import WheelCore

// Control Center style: one glass surface, quiet inset modules, native controls.

private enum MenuMetrics {
    static let width: CGFloat = 340
    static let padding: CGFloat = 12
    static let corner: CGFloat = 24
    /// Concentric with the outer corner at the panel's padding.
    static let moduleCorner: CGFloat = corner - padding
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.closeMenu) private var closeMenu
    private var presentation: WheelPresentation { model.presentation }
    private var connected: Bool { presentation.isConnected }
    private var angle: Double { WheelPresentation.angle(steering: model.status.rawSteering, range: model.wheel.range) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.padding(.horizontal, 6).padding(.bottom, 4)
            module {
                if let empty = presentation.emptyMessage { emptyState(empty) } else { steering }
                Divider()
                pedal("Accelerator", model.status.input.throttle, .mint)
                pedal("Brake", model.status.input.brake, .orange)
                pedal("Clutch", model.status.input.clutch, .blue)
            }
            module { forceFeedback }
            VStack(spacing: 0) {
                MenuRow(title: "Open dashboard", symbol: "macwindow") { open(.overview) }
                MenuRow(title: "Game library", symbol: "square.grid.2x2", detail: "\(model.installedGames.count) ready") { open(.games) }
                Divider().padding(.horizontal, 8).padding(.vertical, 4)
                MenuRow(title: "Quit crossover-ffb", symbol: "power", detail: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            if model.showsPreviewChrome {
                Text("PREVIEW · NO HARDWARE").font(.system(size: 8, weight: .medium)).tracking(1.2)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 2)
            }
        }
        .padding(MenuMetrics.padding)
        .frame(width: MenuMetrics.width)
        .modifier(MenuGlassSurface())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    // Clear glass renders fully opaque foreground colours as white; keep a hint of transparency.
                    Circle().fill(presentation.statusColor.opacity(0.9)).frame(width: 6, height: 6)
                    Text(model.running ? presentation.statusLabel : "Bridge off").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Wheel bridge", isOn: Binding(get: { model.running }, set: { _ in model.toggleRunning() }))
                .toggleStyle(.switch).labelsHidden().help("Wheel bridge")
        }
    }

    private var steering: some View {
        HStack(spacing: 14) {
            WheelRim(model: presentation.visibleModel)
                .frame(width: 56, height: 56)
                .rotationEffect(.degrees(angle))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%+.0f°", angle))
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("Steering · \(model.wheel.range)° range").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func emptyState(_ empty: (title: String, detail: String)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.unsupportedModel != nil ? "exclamationmark.triangle" : "cable.connector")
                .font(.system(size: 17, weight: .regular)).frame(width: 24, height: 24)
                .foregroundStyle(presentation.unsupportedModel != nil ? Color.orange.opacity(0.9) : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(empty.title).font(.system(size: 13, weight: .medium))
                Text(empty.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var forceFeedback: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Force feedback").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(connected && model.status.gameActive ? "Active" : "Standby").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForceMeter(value: connected ? model.status.output : 0, compact: true)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $model.strength, in: 0...100).accessibilityLabel("Strength")
                Text("\(Int(model.strength))%").font(.system(size: 11)).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            if model.showsTrueForce {
                Divider()
                HStack {
                    Label("TrueForce", systemImage: "waveform").font(.system(size: 12))
                    Spacer()
                    Toggle("TrueForce", isOn: $model.tfEnabled).toggleStyle(.switch).labelsHidden()
                }.accessibilityIdentifier("trueForce.controls")
            }
            if model.needsInputPermission {
                Button("Allow Input Monitoring…") { model.openInputMonitoringSettings() }.controlSize(.small)
            }
        }
    }

    private func pedal(_ name: String, _ raw: UInt32, _ color: Color) -> some View {
        let value = connected ? max(0, min(1, 1 - Double(raw) / 65535)) : 0
        return HStack(spacing: 10) {
            Text(name).frame(width: 74, alignment: .leading).foregroundStyle(.secondary)
            Capsule().fill(Color.primary.opacity(0.08)).frame(height: 4).overlay(alignment: .leading) {
                GeometryReader { geo in Capsule().fill(color.opacity(0.85)).frame(width: geo.size.width * value) }
            }
            Text(connected ? "\(Int(value * 100))%" : "—").monospacedDigit().frame(width: 34, alignment: .trailing)
        }.font(.system(size: 11))
    }

    private func module<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: MenuMetrics.moduleCorner, style: .continuous))
    }

    private func open(_ tab: AppModel.SettingsTab) { closeMenu(); model.showSettings(tab) }
}

/// A menu-style row: full-width hover highlight, like the rows in native menus.
private struct MenuRow: View {
    let title: String, symbol: String
    var detail: String? = nil
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MenuMetrics.corner, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(MenuBackdrop().clipShape(shape))
        }
    }
}

private struct MenuBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Bipolar force meter: grows left or right from the centre line.
struct ForceMeter: View {
    let value: Double
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Force").font(compact ? .system(size: 11) : .callout).foregroundStyle(compact ? .secondary : .primary)
                Spacer()
                Text(String(format: "%@%.0f%%", value < -0.005 ? "← " : value > 0.005 ? "→ " : "", abs(value) * 100))
                    .font(compact ? .system(size: 11) : .callout).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let half = geo.size.width / 2, w = half * min(1, abs(value))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: abs(value) > 0.95 ? [.orange, .red] : [.accentColor.opacity(0.7), .accentColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w)
                        .offset(x: value < 0 ? half - w : half)
                    Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1).offset(x: half)
                }
            }
            .frame(height: compact ? 6 : 10)
            .animation(.linear(duration: 0.07), value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Force")
        .accessibilityValue("\(Int(abs(value) * 100)) percent \(value < 0 ? "left" : "right")")
    }
}

// MARK: Liquid Glass with fallbacks for macOS 13–15

extension View {
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
