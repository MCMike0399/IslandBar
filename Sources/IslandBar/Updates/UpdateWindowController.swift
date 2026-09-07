import AppKit
import SwiftUI

@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    private unowned let updater: UpdateController
    private var window: NSWindow?

    init(updater: UpdateController) {
        self.updater = updater
        super.init()
    }

    func show(activate: Bool) {
        if window == nil {
            let hosting = NSHostingController(rootView: UpdateView().environment(updater))
            hosting.sizingOptions = []
            hosting.view.frame = NSRect(origin: .zero, size: UpdateView.size)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Software Update"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(UpdateView.size)
            window.center()
            self.window = window
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        updater.windowClosedByUser()
    }
}
