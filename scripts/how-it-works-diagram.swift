// Renders docs/images/how-it-works.png, the README architecture diagram.
// swiftc scripts/how-it-works-diagram.swift -o /tmp/how-it-works && /tmp/how-it-works docs/images/how-it-works.png
import AppKit
import SwiftUI

struct Tile: View {
    let symbol: String, color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.gradient))
    }
}
struct Node: View {
    let symbol: String, color: Color, title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Tile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 168, height: 168, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }
}
struct Link: View {
    let forward: String, back: String
    var body: some View {
        VStack(spacing: 7) {
            arrow(forward, Color(red: 0.25, green: 0.55, blue: 1), right: true)
            arrow(back, Color(red: 0.35, green: 0.85, blue: 0.75), right: false)
        }.frame(width: 74).padding(.horizontal, 4)
    }
    func arrow(_ label: String, _ color: Color, right: Bool) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(color).lineLimit(1).fixedSize()
            HStack(spacing: 0) {
                if !right { Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold)) }
                Capsule().frame(height: 2)
                if right { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)) }
            }.foregroundStyle(color)
        }
    }
}
struct Zone<Content: View>: View {
    let title: String
    var bordered = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 0) { content }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(bordered ? 0.10 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}
struct Diagram: View {
    /// Zone title line plus its spacing, so links between zones line up with links inside them.
    private let titleRow: CGFloat = 23
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 0) {
                Zone(title: "INSIDE WINE") {
                    Node(symbol: "flag.checkered", color: .indigo, title: "Windows game", detail: "Running in CrossOver, NotProton or Wine")
                    Link(forward: "effects", back: "input")
                    Node(symbol: "puzzlepiece.extension.fill", color: .purple, title: "dinput8.dll", detail: "Bridge next to the .exe. A virtual G923 or G29, plus game telemetry")
                }
                Link(forward: "effects", back: "input").padding(.top, titleRow)
                Zone(title: "BETWEEN THEM", bordered: false) {
                    Node(symbol: "memorychip.fill", color: .gray, title: "Shared memory", detail: "One small file in /tmp that the bridge and the app both map")
                }
                Link(forward: "effects", back: "input").padding(.top, titleRow)
                Zone(title: "ON YOUR MAC") {
                    Node(symbol: "menubar.rectangle", color: .teal, title: "crossover-ffb", detail: "Menu bar app. Turns effects into motor force and TrueForce")
                    Link(forward: "forces", back: "input")
                    Node(symbol: "steeringwheel", color: .orange, title: "Logitech wheel", detail: "G923 or G29 over USB HID")
                }
            }
            HStack(spacing: 18) {
                legend(Color(red: 0.25, green: 0.55, blue: 1), "Forces the game asks for, played at 500 Hz (TrueForce at 4 kHz)")
                legend(Color(red: 0.35, green: 0.85, blue: 0.75), "Steering, pedals and buttons")
            }.padding(.leading, 4)
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.118)))
        .padding(1)
    }
    func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 7) {
            Capsule().fill(color).frame(width: 18, height: 3)
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
    }
}
let app = NSApplication.shared
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Diagram().environment(\.colorScheme, .dark))
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print(rep.pixelsWide, rep.pixelsHigh)
}
