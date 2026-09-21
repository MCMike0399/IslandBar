import AppKit
import SwiftUI

/// Whether the space the user is looking at hides its menu bar, and whether the pill may
/// animate inside it.
///
/// A status item that redraws sixty times a second holds the menu bar open. Measured with a
/// full-screen window and the pointer parked at the middle of the screen: with IslandBar
/// quit the bar was hidden from the first sample and stayed hidden; with IslandBar running
/// but idle it hid after ten seconds; with music playing it never hid at all, for as long as
/// the test ran. The visualiser is not drawing over the app — it is keeping the bar, and the
/// window's title bar with it, down on top of it.
///
/// So where the bar hides itself, the bars animate only while the pointer is actually up
/// there, which is the only time anyone can see them: move away and the animation stops, and
/// the bar hides the way it always did. On an ordinary desktop the bar never hides, none of
/// this applies, and the pill animates exactly as before.
@MainActor
@Observable
final class MenuBarAutoHide {
    /// True where the menu bar hides itself: a full-screen space, or a desktop whose owner
    /// asked for auto-hide in Settings.
    private(set) var isActive = false
    /// True while the pill may animate.
    private(set) var animationAllowed = true

    /// Slower than the eye and far slower than the thing it is gating. Pointing at the menu
    /// bar starts the bars within a fifth of a second, which reads as immediate.
    private static let pointerInterval: TimeInterval = 0.2
    private var pointerTimer: Timer?
    private var modeTimer: Timer?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // Notifications make it responsive; this makes it correct. Entering or leaving full
        // screen is not always a space change (a window can be resized into it), and the
        // desktop's own auto-hide setting changes with no notification at all. Two seconds
        // of a stale answer costs nothing next to what it is gating.
        modeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.reevaluate() }
        }
        reevaluate()
    }

    @objc private func spaceChanged() {
        // The notification lands when the switch *starts*: a window on its way into full
        // screen is still mid-animation and not yet the size of a display, so a single
        // reading here sees an ordinary space and settles on the wrong answer. Ask again
        // while the switch finishes; the standing timer is the backstop after that.
        reevaluate()
        for delay in [0.4, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reevaluate() }
        }
    }

    private func reevaluate() {
        let active = Self.hidesMenuBarAlways || Self.spaceIsFullScreen()
        guard active != isActive else { return }
        isActive = active
        DebugLog.line("menu bar auto-hide=\(active ? "on" : "off")")
        if active {
            // Start from where the pointer already is, so entering full screen with the
            // pointer at the top does not freeze the bars until the next tick.
            updateForPointer()
            let timer = Timer.scheduledTimer(withTimeInterval: Self.pointerInterval, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.updateForPointer() }
            }
            pointerTimer = timer
        } else {
            pointerTimer?.invalidate()
            pointerTimer = nil
            setAllowed(true)
        }
    }

    private func updateForPointer() {
        guard isActive else { return }
        setAllowed(Self.pointerIsInMenuBar())
    }

    private func setAllowed(_ allowed: Bool) {
        guard allowed != animationAllowed else { return }
        animationAllowed = allowed
        DebugLog.line("pill animation allowed=\(allowed)")
    }

    /// "Automatically hide and show the menu bar" on the desktop. Written to the global
    /// domain, which `UserDefaults.standard` falls back to.
    private static var hidesMenuBarAlways: Bool {
        UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    }

    /// How much of a screen the menu bar takes. `NSStatusBar.system.thickness` is not it:
    /// on a notched Mac the bar is 33 pt tall and that property still answers 24, which is
    /// enough to make every full-screen window miss its match by nine points.
    private static func menuBarInset(of screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
    }

    /// Windows that belong to the system rather than to whatever the user is looking at.
    /// Stage Manager puts its own layer-0 windows up during a space switch.
    private static let systemOwners: Set<String> = ["WindowManager", "Window Server", "Dock"]

    /// A full-screen space, recognised by what is in it rather than by asking — there is no
    /// public API that answers this for another app's window.
    ///
    /// Two marks together, because either alone is ambiguous. Every ordinary window on the
    /// current space belongs to one application, which is what a full-screen space *is*; and
    /// that application has a window as wide as a display which either fills its height or
    /// falls exactly one menu bar short of it. The short one is not a detail: a full-screen
    /// window whose menu bar is being held open is pushed down to 0,33 1728x1084 and shows
    /// its title bar, which is the state this class exists to get out of.
    private static func spaceIsFullScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        // Each screen contributes the two heights a full-screen window on it can have: its
        // own, and its own less the menu bar — the size the window is squeezed to while the
        // bar is being held open, which is the state this is here to detect.
        let shapes: [(width: CGFloat, heights: [CGFloat])] = NSScreen.screens.map {
            (.init($0.frame.width), [$0.frame.height, $0.frame.height - menuBarInset(of: $0)])
        }
        var owners = Set<String>()
        var covering = false
        for window in list {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  !systemOwners.contains(owner),
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            owners.insert(owner)
            let width = bounds["Width"] ?? 0, height = bounds["Height"] ?? 0
            if shapes.contains(where: { shape in
                abs(shape.width - width) < 1 && shape.heights.contains { abs($0 - height) < 1 }
            }) {
                covering = true
            }
        }
        return owners.count == 1 && covering
    }

    private static func pointerIsInMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        // A little taller than the bar itself: the pointer is what reveals it, and being
        // strict about the last point would flicker the bars along its bottom edge.
        return point.y >= screen.frame.maxY - (menuBarInset(of: screen) + 4)
    }
}
