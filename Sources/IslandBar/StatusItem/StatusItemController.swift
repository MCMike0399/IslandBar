import AppKit
import Observation
import QuartzCore
import SwiftUI

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusItemController: NSObject {
    private let store: NowPlayingStore
    private let preferences: Preferences
    private let mixer: AudioMixer
    private let system: SystemAudioController
    private let statusItem: NSStatusItem
    /// Owned here so it outlives every rebuild of the hosted root view: a fresh instance
    /// per rebuild would take its first reading as committed and let the ringing back in.
    private let menuBarAppearance = MenuBarAppearance()
    private let menuBarAutoHide = MenuBarAutoHide()
    private let popover = NSPopover()
    private var hosting: PassthroughHostingView<AnyView>?
    private var hostedHeight: CGFloat = 0
    /// Tallest the card's fixed sections have been since it opened. Everything except the
    /// output list only ever grows while the popover is up, so a source cannot vanish from
    /// under a fader mid-drag. Reset on every open.
    private var baseHeightFloor: CGFloat = 0
    private let settings: SettingsWindowController
    private let updater: UpdateController
    /// The slot's width follows the pill: full while playing, contracted around the idle
    /// mark once its shrink animation has landed. AppKit reflows the menu bar instantly,
    /// so this can never be animated — only sequenced.
    private var slotWork: DispatchWorkItem?
    private var slotWidth: CGFloat = 0
    private var slotWidthConstraint: NSLayoutConstraint?
    private var pillWidth: CGFloat {
        CompactIslandMetrics.pillWidth(count: preferences.visualizerBarCount)
    }
    /// Accessory apps do not reliably get transient popovers dismissed by clicks in
    /// other apps, so watch for clicks ourselves while the popover is up.
    private var clickAwayMonitors: [Any] = []

    init(
        store: NowPlayingStore,
        preferences: Preferences,
        mixer: AudioMixer,
        system: SystemAudioController,
        settings: SettingsWindowController,
        updater: UpdateController
    ) {
        self.store = store
        self.preferences = preferences
        self.mixer = mixer
        self.system = system
        self.settings = settings
        self.updater = updater
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(handleClick(_:))

        let height = max(button.bounds.height, 22)
        hostedHeight = height
        let root = AnyView(
            CompactIslandView(buttonHeight: height)
                .environment(store)
                .environment(preferences)
                .environment(menuBarAppearance)
                .environment(menuBarAutoHide)
        )
        let view = PassthroughHostingView(rootView: root)
        // The pill has a fixed size. Without this, NSHostingView re-runs
        // updateConstraints/layout for the whole button on every animation frame.
        view.sizingOptions = []
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        // The width constraint is what sizes a variable-length status item: setting
        // `NSStatusItem.length` looked like it worked (the property read back 37) but the
        // item kept its old footprint, because the button was still being measured from
        // these constraints. So the slot's width is driven from here instead.
        let width = view.widthAnchor.constraint(equalToConstant: pillWidth)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            width,
        ])
        slotWidthConstraint = width
        slotWidth = pillWidth
        hosting = view

        popover.behavior = .transient
        popover.delegate = self
        // No animation, ever. `NSPopover` animates by growing the *window* from the status
        // item while the card inside is already laid out at its final size, so the content
        // is drawn full-size and merely revealed — and because the window's origin travels
        // as it grows, the whole card visibly slides across the screen on the way in. The
        // old card was small enough to get away with it; this one is twice the height and
        // it reads as the contents jumping. The same animation on a content-size change
        // drags the card's contents behind the new height when the output list opens.
        popover.animates = false
        popover.contentSize = ExpandedIslandMetrics.idleSize
        // The card is built on first open (see togglePopover); a hosting tree that may
        // never be shown is not worth keeping resident.

        // Nothing has reported yet, so this reaches its conclusion at once: an app that
        // launches idle starts as the mark, not as a pill that shrinks a second later.
        applyPresence(immediate: true)
        startObserving()
    }

    /// The status item is persistent now; a relaunch attempt just brings the
    /// existing instance forward, so there is nothing to reveal.
    func showReopenSafety() {
        DebugLog.line("reopen requested; status item is always visible")
    }

    private func startObserving() {
        tick()
        layoutTick()
    }

    /// Deliberately separate from `tick()`. Folding the card's layout inputs into that read
    /// set would re-run `applyPresence` and `applyVisibility` — which reflow the menu bar
    /// slot — every time an app starts playing or the output list is opened.
    private func layoutTick() {
        withObservationTracking {
            // Read unconditionally: `resizeCard` returns early while the popover is closed,
            // and a tracking closure that reads nothing is never called again.
            _ = currentPlan()
            resizeCard()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.layoutTick() }
        }
    }

    private func currentPlan() -> SourcePlan {
        SourcePlan.make(session: store.session, mixer: mixer, system: system)
    }

    private func tick() {
        withObservationTracking {
            applyVisibility()
            applyPresence(immediate: false)
            _ = store.audioPermissionDenied
            _ = store.isPlaying
            _ = store.session?.paletteKey
            _ = preferences.launchAtLogin
            _ = preferences.visualizerBarCount
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    /// Contracts the slot once the pill's shrink spring has landed, and expands it up
    /// front so the pill grows into space that is already there. The idle mark is drawn
    /// at the slot's final trailing inset the whole time, so the snap itself moves
    /// nothing on screen; only the neighbouring status items reflow, which AppKit does
    /// without animation and which no amount of sequencing here could smooth.
    private func applyPresence(immediate: Bool) {
        slotWork?.cancel()
        slotWork = nil
        guard !store.isPlaying else {
            setSlotWidth(pillWidth)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !immediate, !reduceMotion else {
            setSlotWidth(CompactIslandMetrics.idleSlotWidth)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.setSlotWidth(CompactIslandMetrics.idleSlotWidth)
        }
        slotWork = work
        // Longer than the content's `smooth` shrink, so the slot only snaps once the
        // mark has come to rest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func setSlotWidth(_ width: CGFloat) {
        guard width != slotWidth else { return }
        slotWidth = width
        slotWidthConstraint?.constant = width
        DebugLog.line("status item slot width=\(Int(width))")
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            DebugLog.line(
                "slot layout length=\(Int(self.statusItem.length)) button=\(button.frame) "
                    + "window=\(button.window?.frame ?? .zero)"
            )
        }
    }

    func applyVisibility() {
        // Persistent pill: always visible. When nothing plays it contracts to the idle mark.
        if !statusItem.isVisible {
            statusItem.isVisible = true
            DebugLog.line("statusItem.isVisible=true")
        }
        // The hosted view observes the store itself; replacing the root view here
        // on every Now Playing update forced a constraints + layout pass each time.
        if let hosting, let button = statusItem.button {
            let height = max(button.bounds.height, 22)
            guard height != hostedHeight else { return }
            hostedHeight = height
            hosting.rootView = AnyView(
                CompactIslandView(buttonHeight: height)
                    .environment(store)
                    .environment(preferences)
                    .environment(menuBarAppearance)
                    .environment(menuBarAutoHide)
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

    /// See `IslandBarID.debugTogglePopoverNotification`.
    func debugTogglePopover() {
        togglePopover()
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopoverIfShown()
        } else {
            mixer.setPopoverOpen(true)
            system.setPopoverOpen(true)
            baseHeightFloor = 0
            popover.contentSize = ExpandedIslandMetrics.size(for: currentPlan())
            popover.contentViewController = makeExpandedController()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installClickAwayMonitors()
        }
    }

    /// The card is sized imperatively, here and in `resizeCard`. Without clearing
    /// `sizingOptions` the hosting view re-measures the popover frame on every bar frame
    /// while the popover is open.
    ///
    /// The blurred backdrop is an `NSVisualEffectView` here rather than a representable
    /// inside the SwiftUI tree, and it is the popover's own view so autoresizing carries
    /// the frame straight to it. As a representable it was resized by a SwiftUI layout
    /// pass that lands *after* the popover has already grown, so opening the output list
    /// left the blur at its old height and the strip below it showed the window's raw
    /// backing — which read as the Sound panel being cut off below its slider.
    private func makeExpandedController() -> NSViewController {
        let host = NSHostingController(
            rootView: ExpandedIslandView()
                .environment(store)
                .environment(preferences)
                .environment(mixer)
                .environment(system)
        )
        host.sizingOptions = []

        let backdrop = NSVisualEffectView(
            frame: NSRect(origin: .zero, size: ExpandedIslandMetrics.size(for: currentPlan()))
        )
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .vibrantDark)
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.masksToBounds = true
        backdrop.autoresizesSubviews = true
        backdrop.autoresizingMask = [.width, .height]

        host.view.frame = backdrop.bounds
        host.view.autoresizingMask = [.width, .height]
        backdrop.addSubview(host.view)

        let controller = NSViewController()
        controller.view = backdrop
        controller.addChild(host)
        return controller
    }

    /// The popover's height and its hosting view's frame are the only two consumers of the
    /// card height, and they are always assigned together here.
    private func resizeCard() {
        guard popover.isShown else { return }
        let plan = currentPlan()
        // Monotonic in its fixed sections. A row vanishing under a fader mid-drag is the
        // worst thing this card can do, so those only grow until the popover closes. The
        // output list is the user's own doing, so it is allowed to fold away again.
        baseHeightFloor = max(baseHeightFloor, ExpandedIslandMetrics.baseHeight(for: plan))
        let size = NSSize(
            width: ExpandedIslandMetrics.width,
            height: baseHeightFloor + ExpandedIslandMetrics.pickerHeight(for: plan)
        )
        guard size != popover.contentSize else { return }
        DebugLog.line(
            "card resize \(Int(popover.contentSize.height)) -> \(Int(size.height)) "
                + "hero=\(plan.hasHero) heroFader=\(plan.heroRow != nil) others=\(plan.others.count) "
                + "picking=\(plan.isPickingOutput) devices=\(plan.outputDeviceCount) floor=\(Int(baseHeightFloor))"
        )
        // `contentSize` only. The content view's frame belongs to `NSPopover`, which lays
        // it out into an area a little wider than the content size it was given — setting
        // the frame to that size instead left the blurred backdrop 12 pt narrower than the
        // card, as a lighter unblurred band down the right-hand edge. The hosting view
        // autoresizes inside the backdrop, so one assignment moves everything.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popover.contentSize = size
        CATransaction.commit()
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
        if let release = updater.status.release, !updater.status.isInstalling {
            let item = NSMenuItem(
                title: "Update to IslandBar \(release.version)…",
                action: #selector(showUpdate),
                keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }
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
        if store.browserAccessDenied {
            let item = NSMenuItem(
                title: "Allow reading browser tabs…",
                action: #selector(openAutomationPrivacy),
                keyEquivalent: ""
            )
            item.target = self
            item.toolTip = "IslandBar reads the playing tab's title from the browser when the browser reports no track. Enable it under Privacy & Security › Automation."
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
        let updates = NSMenuItem(
            title: updater.status.isInstalling ? "Installing Update…" : "Check for Updates…",
            action: #selector(showUpdate),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)
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

    @objc private func openAutomationPrivacy() {
        store.retryBrowserAccess?()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        preferences.launchAtLogin.toggle()
    }

    @objc private func showSettings() {
        settings.show()
    }

    @objc private func showUpdate() {
        updater.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeClickAwayMonitors()
        mixer.setPopoverOpen(false)
        system.setPopoverOpen(false)
    }
}
