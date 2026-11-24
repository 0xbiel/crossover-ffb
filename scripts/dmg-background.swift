// Renders the installer disk image background in the app's style.
// swiftc scripts/dmg-background.swift -o .build/dmg-background && .build/dmg-background <version> <out.tiff>
// scripts/package-app runs this and places the icons at the slots drawn here.
import AppKit
import SwiftUI

enum Layout {
    static let size = CGSize(width: 660, height: 420)
    /// Icon centres; package-app passes the same points to Finder.
    static let app = CGPoint(x: 180, y: 205)
    static let applications = CGPoint(x: 480, y: 205)
    /// Finder draws icon labels in dark text even in dark mode, so each gets a light plate.
    /// Measured with 112 pt icons and 13 pt text: label centre 78 pt below the icon centre.
    static let labelDrop: CGFloat = 78
}

private let mint = Color(red: 0.35, green: 0.85, blue: 0.75)
private let blue = Color(red: 0.25, green: 0.55, blue: 1)

/// The rotation dial from the Steering page, as a quiet frame around the app icon.
struct Dial: View {
    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = size.width / 2 - 2
            for i in 0...60 {
                let a = (Double(i) / 60 * 200 - 190) * .pi / 180
                let major = i % 10 == 0
                let inner = radius - (major ? 12 : 7)
                var path = Path()
                path.move(to: CGPoint(x: centre.x + cos(a) * inner, y: centre.y + sin(a) * inner))
                path.addLine(to: CGPoint(x: centre.x + cos(a) * radius, y: centre.y + sin(a) * radius))
                context.stroke(path, with: .color(blue.opacity(major ? 0.55 : 0.3)), style: StrokeStyle(lineWidth: major ? 2.5 : 1.5, lineCap: .round))
            }
        }
        .frame(width: 210, height: 210)
    }
}

struct Background: View {
    let version: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.14), Color(white: 0.095)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 10) {
                Image(systemName: "steeringwheel")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.teal.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("crossover-ffb").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text("Version \(version)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .position(x: 112, y: 42)
            Dial().position(Layout.app)
            // Drop target for Applications.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(width: 150, height: 150)
                .position(Layout.applications)
            // The gap between the dial (radius 105) and the drop target (half width 75).
            let gapStart = Layout.app.x + 115, gapEnd = Layout.applications.x - 85
            HStack(spacing: 0) {
                Capsule().fill(LinearGradient(colors: [blue.opacity(0.2), mint], startPoint: .leading, endPoint: .trailing)).frame(width: gapEnd - gapStart - 10, height: 3)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(mint).offset(x: -4)
            }
            .position(x: (gapStart + gapEnd) / 2, y: Layout.app.y)
            Text("Drag to Applications").font(.system(size: 11, weight: .medium)).foregroundStyle(mint).fixedSize()
                .position(x: (gapStart + gapEnd) / 2, y: Layout.app.y - 20)
            ForEach([(Layout.app, 136.0), (Layout.applications, 108.0)], id: \.1) { point, width in
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.88))
                    .frame(width: width, height: 22)
                    .position(x: point.x, y: point.y + Layout.labelDrop)
            }
            VStack(spacing: 4) {
                Text("First launch: right-click crossover-ffb in Applications and choose Open.")
                Text("It isn't notarized yet. Then allow Input Monitoring when asked.")
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            .frame(width: Layout.size.width)
            .position(x: Layout.size.width / 2, y: 380)
        }
        .frame(width: Layout.size.width, height: Layout.size.height)
        .environment(\.colorScheme, .dark)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { FileHandle.standardError.write(Data("usage: dmg-background <version> <out.tiff>\n".utf8)); exit(2) }
_ = NSApplication.shared
MainActor.assumeIsolated {
    // One TIFF with 1x and 2x representations, so Finder picks the sharp one on Retina.
    let tiff = NSImage(size: Layout.size)
    for scale in [1.0, 2.0] {
        let renderer = ImageRenderer(content: Background(version: arguments[1]))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { fatalError("render failed at \(scale)x") }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = Layout.size
        tiff.addRepresentation(rep)
    }
    guard let data = tiff.tiffRepresentation(using: .lzw, factor: 1) else { fatalError("encode failed") }
    try! data.write(to: URL(fileURLWithPath: arguments[2]))
}
