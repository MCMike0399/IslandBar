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
            view.widthAnchor.constraint(equalToConstant: 62),
        ])
        hosting = view

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 120)
        popover.contentViewController = NSHostingController(
            rootView: ExpandedIslandView()
                .environment(store)
                .environment(preferences)
        )

        startObserving()
    }

    func showReopenSafety() {
        store.reopenVisibleUntil = Date().addingTimeInterval(8)
        applyVisibility()
        DebugLog.line("reopen safety: statusItem visible for 8s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            if let until = self.store.reopenVisibleUntil, until <= Date() {
                self.store.reopenVisibleUntil = nil
                self.applyVisibility()
            }
        }
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
        let reopen = (store.reopenVisibleUntil ?? .distantPast) > Date()
        let visible: Bool
        if reopen {
            visible = true
        } else if store.session == nil {
            visible = false
        } else if preferences.hideWhenPaused && !store.isPlaying {
            visible = false
        } else {
            visible = true
        }
        if statusItem.isVisible != visible {
            statusItem.isVisible = visible
            DebugLog.line("statusItem.isVisible=\(visible)")
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
            popover.performClose(nil)
        } else {
            popover.contentViewController = NSHostingController(
                rootView: ExpandedIslandView()
                    .environment(store)
                    .environment(preferences)
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
