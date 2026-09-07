import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let preferences: Preferences
    private let updater: UpdateController
    private var window: NSWindow?

    init(preferences: Preferences, updater: UpdateController) {
        self.preferences = preferences
        self.updater = updater
        super.init()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(preferences).environment(updater))
            let window = NSWindow(contentViewController: hosting)
            window.title = "IslandBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
