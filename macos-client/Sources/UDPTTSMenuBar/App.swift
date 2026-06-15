import SwiftUI

@main
struct UDPTTSMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in a status-item popover managed by AppDelegate, so this
        // app has no normal windows. An empty Settings scene satisfies the
        // `App` requirement without showing anything.
        Settings { EmptyView() }
    }
}

/// Owns the menu-bar status item, the popover that hosts the SwiftUI UI, and the
/// global hotkey. Runs as an accessory (no Dock icon, no main window).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = TTSClientModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hotKey: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform",
                                     accessibilityDescription: "UDP TTS")
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(model)
                .environmentObject(HotKeyInfo()))

        hotKey = HotKeyManager { [weak self] in
            DispatchQueue.main.async { self?.togglePopover() }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Carries the active hotkey label into the UI for display.
final class HotKeyInfo: ObservableObject {
    let label = HotKeyManager.defaultDescription
}
