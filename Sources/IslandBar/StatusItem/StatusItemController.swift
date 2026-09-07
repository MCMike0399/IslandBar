import AppKit
import Observation
import SwiftUI

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusItemController: NSObject {
    private let store: NowPlayingStore
    private let preferences: Preferences
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var hosting: PassthroughHostingView<AnyView>?
    private let settings: SettingsWindowController
    /// Accessory apps do not reliably get transient popovers dismissed by clicks in
    /// other apps, so watch for clicks ourselves while the popover is up.
    private var clickAwayMonitors: [Any] = []

    init(store: NowPlayingStore, preferences: Preferences, settings: SettingsWindowController) {
        self.store = store
        self.preferences = preferences
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(handleClick(_:))

        let height = max(button.bounds.height, 22)
        let root = AnyView(
            CompactIslandView(buttonHeight: height)
                .environment(store)
                .environment(preferences)
        )
        let view = PassthroughHostingView(rootView: root)
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: CompactIslandMetrics.pillWidth),
        ])
        hosting = view

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = ExpandedIslandMetrics.size
        popover.contentViewController = NSHostingController(
            rootView: ExpandedIslandView()
                .environment(store)
                .environment(preferences)
        )

        startObserving()
    }

    /// The status item is persistent now; a relaunch attempt just brings the
    /// existing instance forward, so there is nothing to reveal.
    func showReopenSafety() {
        DebugLog.line("reopen requested; status item is always visible")
    }

    private func startObserving() {
        tick()
    }

    private func tick() {
        withObservationTracking {
            applyVisibility()
            _ = store.audioPermissionDenied
            _ = store.isPlaying
            _ = store.session?.paletteKey
            _ = preferences.launchAtLogin
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    func applyVisibility() {
        // Persistent pill: always visible. When nothing plays the bars collapse to a flat line.
        if !statusItem.isVisible {
            statusItem.isVisible = true
            DebugLog.line("statusItem.isVisible=true")
        }
        if let hosting, let button = statusItem.button {
            let height = max(button.bounds.height, 22)
            hosting.rootView = AnyView(
                CompactIslandView(buttonHeight: height)
                    .environment(store)
                    .environment(preferences)
            )
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        if event.type == .rightMouseUp {
            contextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopoverIfShown()
        } else {
            popover.contentViewController = NSHostingController(
                rootView: ExpandedIslandView()
                    .environment(store)
                    .environment(preferences)
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installClickAwayMonitors()
        }
    }

    private func installClickAwayMonitors() {
        removeClickAwayMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.closePopoverIfShown() }
        }) {
            clickAwayMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            let inPopover = event.window != nil && event.window == popoverWindow
            let onButton = event.window != nil && event.window == self.statusItem.button?.window
            if !inPopover && !onButton {
                Task { @MainActor in self.closePopoverIfShown() }
            }
            return event
        }) {
            clickAwayMonitors.append(local)
        }
    }

    private func removeClickAwayMonitors() {
        for monitor in clickAwayMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickAwayMonitors.removeAll()
    }

    private func closePopoverIfShown() {
        removeClickAwayMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if store.audioPermissionDenied {
            let item = NSMenuItem(
                title: "Enable audio analysis…",
                action: #selector(openAudioPrivacy),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let login = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = preferences.launchAtLogin ? .on : .off
        menu.addItem(login)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openAudioPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        preferences.launchAtLogin.toggle()
    }

    @objc private func showSettings() {
        settings.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeClickAwayMonitors()
    }
}
