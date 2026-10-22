import SwiftUI
import WheelCore

/// Asset boundary: only known fixed-rim models have keys. Future licensed PNGs
/// must be square, transparent and centred on the steering axis. Base PIDs do
/// not identify interchangeable rims. Until cleared artwork ships, use this
/// original schematic (not a manufacturer photograph or logo).
struct WheelRim: View {
    let model: BridgeWheelModel?
    private var accent: Color { model == .g29 ? .blue : .white.opacity(0.75) }
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(Color.black.opacity(0.8), lineWidth: size * 0.13).padding(size * 0.08)
                Circle().stroke(.white.opacity(0.18), lineWidth: 1).padding(size * 0.025)
                Circle().stroke(.white.opacity(0.12), lineWidth: 1).padding(size * 0.15)
                ForEach([0.0, 120.0, 240.0], id: \.self) { degrees in
                    RoundedRectangle(cornerRadius: size * 0.04)
                        .fill(LinearGradient(colors: [.gray.opacity(0.85), .black], startPoint: .top, endPoint: .bottom))
                        .frame(width: size * 0.15, height: size * 0.43)
                        .offset(y: size * 0.19).rotationEffect(.degrees(degrees))
                }
                Circle().fill(Color(white: 0.13)).frame(width: size * 0.35, height: size * 0.35)
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                Text(model == .g29 ? "G29" : model == .g923 ? "G923" : "")
                    .font(.system(size: size * 0.09, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: size * 0.045, height: size * 0.1).offset(y: -size * 0.42)
                ForEach([-1.0, 1.0], id: \.self) { side in
                    VStack(spacing: size * 0.035) {
                        Circle().fill(accent).frame(width: size * 0.04, height: size * 0.04)
                        Circle().fill(.white.opacity(0.4)).frame(width: size * 0.04, height: size * 0.04)
                    }.offset(x: side * size * 0.28)
                }
            }.frame(width: geo.size.width, height: geo.size.height)
        }.accessibilityHidden(true)
    }
}
