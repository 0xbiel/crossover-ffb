import SwiftUI
import WheelCore

private final class WheelRimBundleToken {}

/// User-supplied product depictions, generatively isolated for local preview.
/// See Resources/Rims/NOTICE.txt: these images are not covered by the code's MIT license.
@MainActor
enum WheelRimAssets {
    static let bundleName = "crossover-ffb_CrossoverFFBApp.bundle"
    private static let g29 = load("g29-rim")
    private static let g923 = load("g923-rim")

    /// Resolves the resource bundle without calling SwiftPM's `Bundle.module`, which with
    /// `--build-system native` only checks `Bundle.main.bundleURL` (the `.app` root) and the
    /// build machine's `.build` path, calling `fatalError` when the bundle sits in
    /// `Contents/Resources/` on another Mac.
    static func resourceURL(
        forResource name: String,
        withExtension ext: String,
        subdirectory: String? = "Rims",
        main: Bundle = .main,
        codeBundle: Bundle = Bundle(for: WheelRimBundleToken.self),
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
    ) -> URL? {
        let executableDir = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let bundleURLs: [URL?] = [
            main.resourceURL?.appendingPathComponent(bundleName),
            main.bundleURL.appendingPathComponent(bundleName),
            executableDir.appendingPathComponent(bundleName),
            codeBundle.resourceURL?.appendingPathComponent(bundleName),
            codeBundle.bundleURL.appendingPathComponent(bundleName),
            codeBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName),
        ]
        var seen = Set<URL>()
        for candidate in bundleURLs.compactMap({ $0?.standardizedFileURL }) where seen.insert(candidate).inserted {
            if let bundle = Bundle(url: candidate),
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        return main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = resourceURL(forResource: name, withExtension: "png", subdirectory: "Rims") else { return nil }
        return NSImage(contentsOf: url)
    }
    static func image(for model: BridgeWheelModel?) -> NSImage? {
        switch model {
        case .g29: return g29
        case .g923: return g923
        case nil: return nil
        }
    }
}

/// A square rendering boundary keeps the existing centre-anchored rotation.
/// Unknown/disconnected devices retain the original code-native schematic.
struct WheelRim: View {
    let model: BridgeWheelModel?
    private var accent: Color { model == .g29 ? .blue : .white.opacity(0.75) }
    var body: some View {
        if let image = WheelRimAssets.image(for: model) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().accessibilityHidden(true)
        } else {
            schematic
        }
    }
    private var schematic: some View {
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
