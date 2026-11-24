// Renders the app icon: the teal steering-wheel tile used across the app, docs and installer.
// swiftc scripts/app-icon.swift -o .build/app-icon && .build/app-icon <out.iconset>
// then: iconutil -c icns <out.iconset> -o AppIcon.icns  (scripts/package-app does both)
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        // macOS icon grid: an 824 pt body centred on a 1024 pt canvas.
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.86, blue: 0.84), Color(red: 0.0, green: 0.55, blue: 0.62)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            Image(systemName: "steeringwheel")
                .font(.system(size: 470, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 6)
        }
        .frame(width: 1024, height: 1024)
    }
}

guard CommandLine.arguments.count == 2 else { FileHandle.standardError.write(Data("usage: app-icon <out.iconset>\n".utf8)); exit(2) }
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
_ = NSApplication.shared
MainActor.assumeIsolated {
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let renderer = ImageRenderer(content: Icon())
            renderer.scale = CGFloat(points * scale) / 1024
            guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { fatalError("render failed") }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try! png.write(to: iconset.appendingPathComponent(name))
        }
    }
}
