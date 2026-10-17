import SwiftUI
import WheelCore

// The Steering Wheel page: the options Logitech G HUB has for the G923/G29, with the same
// live rotation dial, laid out like the rest of Settings.

struct WheelPage: View {
    @EnvironmentObject var model: AppModel
    private static let presets = [180, 270, 360, 540, 720, 900]

    var body: some View {
        Page(title: "Steering Wheel", subtitle: "Operating range, sensitivity and centering, as in Logitech G HUB. Changes apply right away, also while you drive.") {
            Button("Restore Defaults") { model.wheel = WheelSettings() }
                .glassButton()
                .disabled(model.wheel == WheelSettings())
        } content: {
            RotationDial(range: model.wheel.range, steering: model.status.rawSteering, connected: model.status.wheelConnected)
            Card(title: "Steering") {
                Row(symbol: "arrow.left.and.right.circle.fill", color: .blue, title: "Operating range",
                    subtitle: "Degrees lock to lock. Match the car: about 360° for F1 and GT3, 540° for road cars, 900° for trucks and rally.", divider: false) {
                    ValueSlider(value: Binding(get: { Double(model.wheel.range) }, set: { model.wheel.range = Int($0) }),
                                range: 40...900, step: 10, unit: "°")
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    ForEach(Self.presets, id: \.self) { degrees in
                        let selected = model.wheel.range == degrees
                        Button("\(degrees)°") { model.wheel.range = degrees }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(selected ? .white : .primary)
                            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                    }
                }
                .padding(.bottom, 10)
                Divider().padding(.leading, 40)
                Row(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", color: .teal, title: "Sensitivity",
                    subtitle: "50 is linear. Higher reacts more around centre, lower is calmer.", divider: false) {
                    HStack(spacing: 14) {
                        CurvePreview(sensitivity: model.wheel.sensitivity)
                        ValueSlider(value: Binding(get: { Double(model.wheel.sensitivity) }, set: { model.wheel.sensitivity = Int($0.rounded()) }),
                                    range: 0...100, step: 1, unit: "", width: 160)
                    }
                }
            }
            Card(title: "Centering spring", footer: "A return-to-centre spring for games without force feedback. Games that have their own (ACC, AC EVO, most sims) feel best with it off.") {
                Row(symbol: "arrow.uturn.backward.circle.fill", color: .green, title: "Centering spring") {
                    Toggle("Centering spring", isOn: $model.wheel.centeringSpring).toggleStyle(.switch).labelsHidden()
                }
                Group {
                    Row(symbol: "dial.medium.fill", color: .green, title: "Strength") {
                        ValueSlider(value: Binding(get: { Double(model.wheel.centeringStrength) }, set: { model.wheel.centeringStrength = Int($0.rounded()) }),
                                    range: 0...100, step: 1, unit: "%")
                    }
                    Row(symbol: "steeringwheel", color: .mint, title: "Also in force feedback games",
                        subtitle: "Adds the spring on top of the game's own forces", divider: false) {
                        Toggle("Also in force feedback games", isOn: $model.wheel.springInFFBGames).toggleStyle(.switch).labelsHidden()
                    }
                }
                .disabled(!model.wheel.centeringSpring)
                .opacity(model.wheel.centeringSpring ? 1 : 0.5)
            }
            Card(title: "TrueForce") {
                Row(symbol: "bolt.circle.fill", color: .orange, title: "Torque", subtitle: "Overall force feedback strength") {
                    PercentSlider(value: $model.strength)
                }
                Row(symbol: "waveform", color: .purple, title: "Audio effects", subtitle: "Engine, road and kerb detail from simulated TrueForce", divider: false) {
                    PercentSlider(value: $model.tfStrength)
                }
                .disabled(!model.tfEnabled)
                .opacity(model.tfEnabled ? 1 : 0.5)
            }
            Card(title: "Pedals") {
                pedal(0, "Accelerator", "arrow.up.circle.fill", .green)
                pedal(1, "Brake", "stop.circle.fill", .red)
                pedal(2, "Clutch", "c.circle.fill", .orange)
                Row(symbol: "arrow.up.arrow.down.circle.fill", color: .gray, title: "Combined pedals",
                    subtitle: "Accelerator and brake on one axis, for older games that expect it", divider: false) {
                    Toggle("Combined pedals", isOn: $model.wheel.combinedPedals).toggleStyle(.switch).labelsHidden()
                }
            }
            Card(title: "Rev lights", footer: "The rev LEDs at the top of the G923/G29 fill up with the engine rpm and flash at the limiter. Uses telemetry from Assetto Corsa, ACC and AC EVO.") {
                Row(symbol: "gauge.high", color: .red, title: "Rev lights", divider: false) {
                    HStack(spacing: 16) {
                        LEDStrip(mask: model.status.leds)
                        Toggle("Rev lights", isOn: $model.wheel.revLights).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    private func pedal(_ index: Int, _ title: String, _ symbol: String, _ color: Color) -> some View {
        Row(symbol: symbol, color: color, title: "\(title) sensitivity") {
            HStack(spacing: 14) {
                CurvePreview(sensitivity: model.wheel.pedalSensitivity[index], bipolar: false)
                ValueSlider(value: Binding(get: { Double(model.wheel.pedalSensitivity[index]) }, set: { model.wheel.pedalSensitivity[index] = Int($0.rounded()) }),
                            range: 0...100, step: 1, unit: "", width: 160)
            }
        }
    }
}

/// G HUB's rotation dial: an arc of ticks for the wheel's 900°, the operating range lit, and a
/// marker and readout that follow the wheel live.
private struct RotationDial: View {
    let range: Int
    let steering: UInt32
    let connected: Bool

    private var angle: Double { (Double(steering) / 32767.5 - 1) * Double(range) / 2 }

    var body: some View {
        VStack(spacing: 6) {
            Text(connected ? "\(Int(angle.rounded()))°" : "–")
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
            ZStack {
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height * 0.92)
                    let radius = min(size.width / 2, size.height * 0.92) - 8
                    let span = 200.0 // arc degrees shown for 900° of wheel rotation
                    let ticks = 90
                    for i in 0...ticks {
                        let wheelDegrees = (Double(i) / Double(ticks) - 0.5) * 900
                        let a = (wheelDegrees / 900 * span - 90) * .pi / 180
                        let lit = abs(wheelDegrees) <= Double(range) / 2 + 0.1
                        let major = i % 15 == 0
                        let inner = radius - (major ? 18 : 11)
                        var path = Path()
                        path.move(to: CGPoint(x: centre.x + cos(a) * inner, y: centre.y + sin(a) * inner))
                        path.addLine(to: CGPoint(x: centre.x + cos(a) * radius, y: centre.y + sin(a) * radius))
                        context.stroke(path, with: .color(lit ? Color.accentColor : Color.primary.opacity(0.15)), style: StrokeStyle(lineWidth: major ? 3 : 2, lineCap: .round))
                    }
                    if connected {
                        let a = (max(-450, min(450, angle)) / 900 * span - 90) * .pi / 180
                        let tip = CGPoint(x: centre.x + cos(a) * (radius + 2), y: centre.y + sin(a) * (radius + 2))
                        var marker = Path()
                        marker.move(to: tip)
                        let back = radius + 12
                        let side = 0.035
                        marker.addLine(to: CGPoint(x: centre.x + cos(a - side) * back, y: centre.y + sin(a - side) * back))
                        marker.addLine(to: CGPoint(x: centre.x + cos(a + side) * back, y: centre.y + sin(a + side) * back))
                        marker.closeSubpath()
                        context.fill(marker, with: .color(.primary))
                    }
                }
                Image(systemName: "steeringwheel")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(connected ? max(-450, min(450, angle)) : 0))
                    .offset(y: 30)
                    .animation(.linear(duration: 0.07), value: steering)
            }
            .frame(height: 170)
            Text("\(range)° OPERATING RANGE")
                .font(.caption.weight(.semibold)).tracking(0.5)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.quaternary.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wheel rotation")
        .accessibilityValue(connected ? "\(Int(angle.rounded())) degrees of \(range)" : "wheel not connected")
    }
}

/// Small plot of the response curve, like the one G HUB draws next to its sliders.
private struct CurvePreview: View {
    let sensitivity: Int
    var bipolar = true
    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 4
            let w = size.width - inset * 2, h = size.height - inset * 2
            var grid = Path()
            grid.move(to: CGPoint(x: inset, y: inset + h)); grid.addLine(to: CGPoint(x: inset + w, y: inset))
            context.stroke(grid, with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            var curve = Path()
            for i in 0...40 {
                let t = Double(i) / 40
                let y: Double
                if bipolar {
                    let x = t * 2 - 1
                    y = ((x < 0 ? -1 : 1) * WheelSettings.curve(abs(x), sensitivity: sensitivity) + 1) / 2
                } else { y = WheelSettings.curve(t, sensitivity: sensitivity) }
                let p = CGPoint(x: inset + w * t, y: inset + h * (1 - y))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 44, height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityHidden(true)
    }
}

/// Slider with a number readout, snapping to `step`.
private struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = ""
    var width: CGFloat = 220
    var body: some View {
        HStack(spacing: 10) {
            // Snap in the binding rather than with `step:`, which draws a tick for every step.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range).frame(width: width)
            Text("\(Int(value.rounded()))\(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

/// Live copy of the wheel's five rev LEDs: green, green, amber, amber, red.
private struct LEDStrip: View {
    let mask: UInt8
    private let colors: [Color] = [.green, .green, .orange, .orange, .red]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { i in
                let on = mask & (1 << i) != 0
                Capsule()
                    .fill(on ? colors[i] : Color.primary.opacity(0.1))
                    .frame(width: 16, height: 8)
                    .shadow(color: on ? colors[i].opacity(0.7) : .clear, radius: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rev lights")
        .accessibilityValue("\(mask.nonzeroBitCount) of 5 lit")
    }
}
