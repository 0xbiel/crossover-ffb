import AppKit
import SwiftUI
import WheelCore

@main
struct CrossoverFFBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // The scene must not observe the model: it publishes live status ~15×/s, and every scene
    // invalidation makes SwiftUI rebuild the menu bar extra and main menu. Only the label and
    // the dropdown's own views observe it.
    private let model = AppModel.shared
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    init() {
        // Menu-bar only: no Dock icon or app menu (Info.plist also sets LSUIElement).
        NSApplication.shared.setActivationPolicy(CommandLine.arguments.contains("--demo") ? .regular : .accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
    }
    var body: some Scene {
        MenuBarExtra(isInserted: CommandLine.arguments.contains("--demo") ? .constant(false) : $showInMenuBar) {
            MenuView().environmentObject(model)
        } label: {
            if CommandLine.arguments.contains("--demo") { Text("FFB Demo") } else { MenuBarLabel(icon: model.icon) }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var icon: AppModel.IconState
    var body: some View {
        Image(nsImage: MenuIcon.image(active: icon.gameActive, running: icon.running))
    }
}

/// Opening the app again (Finder, Spotlight, Launchpad) shows Settings, so it stays reachable
/// when someone hides the menu bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains("--demo") else { return }
        MainActor.assumeIsolated {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            AppModel.shared.setPreviewWheel(.g923)
            AppModel.shared.prepareDemoMenu()
            AppModel.shared.showSettings(.overview)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.current?.showSettings() }
        return false
    }
}

enum MenuIcon {
    static func image(active: Bool, running: Bool) -> NSImage {
        let names = active ? ["steeringwheel.circle.fill", "steeringwheel"] : running ? ["steeringwheel"] : ["steeringwheel.slash", "steeringwheel"]
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "crossover-ffb") {
                image.isTemplate = true
                return image
            }
        }
        return NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "crossover-ffb") ?? NSImage()
    }
}

/// Renders deterministic SwiftUI fixtures to PNGs (`--snapshot <dir>`).
/// AppModel returns before discovery/timers and its FFBBridge cannot start.
@MainActor
enum Snapshot {
    static func render(to dir: URL) {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { fatalError("Cannot create snapshot directory: \(error)") }
        let model = AppModel.shared
        precondition(model.isPreview, "Snapshots require the hardware-disabled model")
        func save<V: View>(_ view: V, _ name: String, _ size: NSSize) {
            let host = NSHostingView(rootView: view.environmentObject(model).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: 0), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render \(name)") }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot encode \(name)") }
            do { try png.write(to: dir.appendingPathComponent(name + ".png")) }
            catch { fatalError("Cannot save \(name): \(error)") }
        }
        for (name, wheel) in [("g923", BridgeWheelModel.g923 as BridgeWheelModel?), ("g29", .g29), ("disconnected", nil)] {
            model.setPreviewWheel(wheel)
            model.settingsTab = .overview
            save(MenuView(), "menu-" + name, NSSize(width: 360, height: wheel == .g923 ? 570 : 540))
            save(SettingsView(), "window-" + name, NSSize(width: 1100, height: 780))
            if CommandLine.arguments.contains("--snapshot-all") {
                for (tab, page) in [(AppModel.SettingsTab.games, "games"), (.wheel, "wheel"), (.forceFeedback, "ffb"), (.trueForce, "trueforce"), (.inputs, "inputs"), (.general, "general")] {
                    model.settingsTab = tab
                    save(SettingsView(), "settings-" + name + "-" + page, NSSize(width: 1100, height: 900))
                }
            }
        }
        print("Rendered fixture states only: discovery, hardware output and game scanning disabled.")
    }
}
