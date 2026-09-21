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
    private var mixer: AudioMixer!
    private var system: SystemAudioController!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController!
    private var updater: UpdateController!
    private let watchdog = RelaunchWatchdog()
    private var termSignal: DispatchSourceSignal?
    private var lastAppliedPlay = false
    private var lastAppliedSession: NowPlayingSession?
    private var lastAppliedBarCount = BarCount.default

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = Preferences()
        store = NowPlayingStore(barCount: preferences.visualizerBarCount)
        let registry = AudioProcessRegistry()
        // Deliberately the same registry the monitor and tap controller use. A second one
        // would double every property-listener registration, and `removeListeners()` only
        // removes its own.
        mixer = AudioMixer(registry: registry)
        system = SystemAudioController()
        let shared = SharedBarState()
        monitor = NowPlayingMonitor(store: store, registry: registry, shared: shared)
        updater = UpdateController(preferences: preferences)
        settings = SettingsWindowController(preferences: preferences, updater: updater)

        tapController = TapController(
            registry: registry,
            shared: shared,
            barCount: preferences.visualizerBarCount
        ) { [weak self] levels, _, _ in
            // The pump already fires on the main queue; skip the actor hop on every frame.
            MainActor.assumeIsolated {
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

        statusItem = StatusItemController(
            store: store,
            preferences: preferences,
            mixer: mixer,
            system: system,
            settings: settings,
            updater: updater
        )
        tapController.start()
        mixer.start()
        system.start()
        monitor.start()
        observeStore()
        updater.start()

        DistributedNotificationCenter.default().addObserver(
            forName: IslandBarID.reopenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.statusItem.showReopenSafety()
            }
        }

        if DebugLog.enabled {
            DistributedNotificationCenter.default().addObserver(
                forName: IslandBarID.debugTogglePopoverNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.statusItem.debugTogglePopover()
                }
            }
        }

        if DebugLog.forceProcedural {
            store.audioPermissionDenied = true
            DebugLog.line("audioPermissionDenied=true (ISLANDBAR_FORCE_PROCEDURAL)")
        }

        DebugLog.line("IslandBar launched pid=\(ProcessInfo.processInfo.processIdentifier)")
        installTerminationSignalHandler()
        watchdog.arm()
    }

    /// `pkill`/`kill` send SIGTERM, which would otherwise skip `applicationWillTerminate`
    /// and leave the relaunch watchdog armed. Route it through a clean quit instead.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            DebugLog.line("SIGTERM received; quitting cleanly")
            NSApp.terminate(nil)
        }
        source.resume()
        termSignal = source
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.showReopenSafety()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog.disarm()
        monitor.stop()
        // Before the tap controller, and synchronous: every mixer tap must be destroyed
        // before the process exits, or an app is left muted with nothing left to unmute it.
        mixer.stop()
        system.stop()
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
            if prefs.barCount != lastAppliedBarCount {
                lastAppliedBarCount = prefs.barCount
                store.barCount = prefs.barCount
                store.palette = ArtworkPalette.make(from: store.session?.artwork, count: prefs.barCount)
                store.barLevels = BarLevels.rest(count: prefs.barCount)
            }
            if session != lastAppliedSession || playing != lastAppliedPlay {
                // The mixer keeps this app's row open across a pause, so the card's hero
                // tile keeps a working fader. It is wired here because the mixer has no
                // view of Now Playing and this is already the one place that watches it.
                mixer.setNowPlaying(bundleID: session?.bundleID, pid: session?.pid ?? 0)
                lastAppliedSession = session
                lastAppliedPlay = playing
                if !playing {
                    store.barLevels = BarLevels.rest(count: prefs.barCount)
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
