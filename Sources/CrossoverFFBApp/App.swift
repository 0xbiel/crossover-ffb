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
        NSApplication.shared.setActivationPolicy(.accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
    }
    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuView().environmentObject(model)
        } label: {
            MenuBarLabel(icon: model.icon)
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

/// Renders the menu and each settings tab to PNGs (development aid: `--snapshot <dir>`).
@MainActor
enum Snapshot {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        model.scanNow()
        func save<V: View>(_ view: V, _ name: String, _ size: NSSize) {
            let host = NSHostingView(rootView: view.environmentObject(model).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: 0), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        save(MenuView(), "menu", NSSize(width: 352, height: 470))
        for (tab, name) in [(AppModel.SettingsTab.games, "games"), (.wheel, "wheel"), (.forceFeedback, "ffb"), (.trueForce, "trueforce"), (.inputs, "inputs"), (.general, "general")] {
            model.settingsTab = tab
            save(SettingsView(), "settings-" + name, NSSize(width: 960, height: tab == .wheel ? 1560 : 640))
        }
    }
}
