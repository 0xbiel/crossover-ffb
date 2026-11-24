import AppKit
import SwiftUI
import WheelCore

enum AppRuntime {
    static var isDemo: Bool { isDemo(arguments: CommandLine.arguments, bundleFlag: Bundle.main.object(forInfoDictionaryKey: "FFBHardwareDisabledDemo") as? Bool) }
    static func isDemo(arguments: [String], bundleFlag: Bool?) -> Bool { arguments.contains("--demo") || bundleFlag == true }
    /// `--simulate-wheel <fixture>`: the normal app chrome over a fixture, still hardware-disabled.
    static var simulatedWheel: AppModel.PreviewFixture? {
        guard !isDemo, let i = CommandLine.arguments.firstIndex(of: "--simulate-wheel"), i + 1 < CommandLine.arguments.count else { return nil }
        return AppModel.PreviewFixture(rawValue: CommandLine.arguments[i + 1])
    }
}

@main @MainActor
enum CrossoverFFBApp {
    private static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        // Menu-bar only: no Dock icon or app menu (Info.plist also sets LSUIElement).
        app.setActivationPolicy(.accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        app.delegate = delegate
        app.run()
    }
}

/// Opening the app again (Finder, Spotlight, Launchpad) shows Settings, so it stays reachable
/// when someone hides the menu bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            menuBar = MenuBarController(model: model)
            if let fixture = AppRuntime.simulatedWheel {
                model.setPreview(fixture)
            } else if AppRuntime.isDemo {
                NSApp.appearance = NSAppearance(named: .darkAqua)
                model.setPreviewWheel(.g923)
            } else { return }
            if CommandLine.arguments.contains("--open-menu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.menuBar?.open() } }
            } else {
                model.showSettings(.overview)
            }
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
        for fixture in AppModel.PreviewFixture.allCases {
            let name = fixture.rawValue
            model.setPreview(fixture)
            model.settingsTab = .overview
            save(MenuView(), "menu-" + name, NSSize(width: 360, height: fixture == .g923 ? 570 : 540))
            save(SettingsView(), "window-" + name, NSSize(width: 1100, height: 780))
            if CommandLine.arguments.contains("--snapshot-all") {
                for (tab, page) in [(AppModel.SettingsTab.games, "games"), (.wheel, "wheel"), (.forceFeedback, "ffb"), (.trueForce, "trueforce"), (.inputs, "inputs"), (.general, "general")] {
                    model.settingsTab = tab
                    save(SettingsView(), "settings-" + name + "-" + page, NSSize(width: 1100, height: 1500))
                }
            }
        }
        print("Rendered fixture states only: discovery, hardware output and game scanning disabled.")
    }
}
