import AppKit
import Combine
import SwiftUI

/// Owns the status item and a borderless, clear panel, so the menu's only background is its own
/// glass. MenuBarExtra(.window) draws an opaque rectangle behind its content that no public
/// SwiftUI API removes.
@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel = makePanel()
    private var outsideClick: Any?
    private var escapeKey: Any?
    private var observers: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        if AppRuntime.isDemo {
            item.button?.title = "FFB Demo"
        } else {
            model.icon.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.updateIcon() }
                .store(in: &observers)
            updateIcon()
            model.$showInMenuBar
                .sink { [weak self] visible in
                    self?.item.isVisible = visible
                    if !visible { self?.close() }
                }
                .store(in: &observers)
        }
    }

    var isOpen: Bool { panel.isVisible }

    @objc func toggle() { isOpen ? close() : open() }

    func open() {
        guard let button = item.button, let anchor = button.window?.frame else { return }
        let host = panel.contentView!
        let size = host.fittingSize
        let screen = (button.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        button.highlight(true)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                // The status item's own click arrives here too; its action toggles instead.
                guard let self, !(self.item.button?.window?.frame.contains(NSEvent.mouseLocation) ?? false) else { return }
                self.close()
            }
        }
        escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    func close() {
        guard isOpen else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        [outsideClick, escapeKey].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        outsideClick = nil; escapeKey = nil
    }

    private func updateIcon() {
        item.button?.image = MenuIcon.image(active: model.icon.gameActive, running: model.icon.running)
    }

    private func makePanel() -> NSPanel {
        let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system shadow outlines the rectangular frame, not the glass shape.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: MenuView()
            .environmentObject(model)
            .environment(\.closeMenu, { [weak self] in self?.close() }))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        // Content height changes with the wheel state; keep the top edge under the menu bar.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak panel, weak host] in
                guard let self, let panel, let host, self.isOpen else { return }
                let size = host.fittingSize
                guard abs(size.height - panel.frame.height) > 0.5 else { return }
                panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: true)
            }
            .store(in: &observers)
        return panel
    }
}

/// Borderless panels refuse key status by default; the menu needs it for sliders and Escape.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CloseMenuKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var closeMenu: @MainActor @Sendable () -> Void {
        get { self[CloseMenuKey.self] }
        set { self[CloseMenuKey.self] = newValue }
    }
}
