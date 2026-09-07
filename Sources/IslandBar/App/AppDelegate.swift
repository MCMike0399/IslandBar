import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: NowPlayingStore!
    private var preferences: Preferences!
    private var monitor: NowPlayingMonitor!
    private var tapController: TapController!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController!
    private var lastAppliedPlay = false
    private var lastAppliedSession: NowPlayingSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = Preferences()
        store = NowPlayingStore()
        monitor = NowPlayingMonitor(store: store)
        settings = SettingsWindowController(preferences: preferences)

        let shared = SharedBarState()
        let registry = AudioProcessRegistry()
        tapController = TapController(registry: registry, shared: shared) { [weak self] levels, _, _ in
            Task { @MainActor in
                guard let self, self.store.isPlaying else { return }
                self.store.barLevels = levels
            }
        }
        tapController.onPermissionDenied = { [weak self] in
            Task { @MainActor in
                self?.store.audioPermissionDenied = true
            }
        }
        tapController.onUsingProcedural = { [weak self] active in
            Task { @MainActor in
                self?.store.usingProcedural = active
            }
        }
        tapController.onTapEvent = { message in
            DebugLog.line(message)
        }

        statusItem = StatusItemController(store: store, preferences: preferences, settings: settings)
        tapController.start()
        monitor.start()
        observeStore()

        DistributedNotificationCenter.default().addObserver(
            forName: IslandBarID.reopenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.statusItem.showReopenSafety()
            }
        }

        if DebugLog.forceProcedural {
            store.audioPermissionDenied = true
            DebugLog.line("audioPermissionDenied=true (ISLANDBAR_FORCE_PROCEDURAL)")
        }

        DebugLog.line("IslandBar launched pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.showReopenSafety()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        tapController.stop()
    }

    private func observeStore() {
        tick()
    }

    private func tick() {
        withObservationTracking {
            let session = store.session?.tapSession
            let playing = store.isPlaying
            let prefs = preferences.snapshot
            if session != lastAppliedSession || playing != lastAppliedPlay {
                lastAppliedSession = session
                lastAppliedPlay = playing
                if !playing {
                    withAnimation(.easeOut(duration: 0.4)) {
                        store.barLevels = .rest
                    }
                }
                tapController.apply(session: session, isPlaying: playing, preferences: prefs)
            } else {
                tapController.apply(session: session, isPlaying: playing, preferences: prefs)
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.tick() }
        }
    }
}
