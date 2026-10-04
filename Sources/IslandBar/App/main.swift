import AppKit

enum IslandBarID {
    static let bundleID = "dev.burbuja-lab.islandbar"
    static let reopenNotification = Notification.Name("dev.burbuja-lab.islandbar.reopen")
    /// Opens and closes the expanded card from a script, which is the only way to get a
    /// look at it without a hand on the mouse: the status item's action needs a real
    /// `NSApp.currentEvent`, so a synthetic accessibility press reaches it and does
    /// nothing. Honoured only under `ISLANDBAR_DEBUG=1`.
    static let debugTogglePopoverNotification = Notification.Name("dev.burbuja-lab.islandbar.debugTogglePopover")
    /// Pins what `MenuBarAutoHide` reads, so a hidden or revealed menu bar can be tested
    /// without a full-screen window (which a background process cannot enter: macOS will
    /// not hand it the focus) or a hand on the pointer. The notification's `object` is
    /// `hidden`, `revealed` or `auto`. Honoured only under `ISLANDBAR_DEBUG=1`; driven by
    /// `Scripts/harness menubar`.
    static let debugMenuBarNotification = Notification.Name("dev.burbuja-lab.islandbar.debugMenuBar")
    /// Writes one `state …` line per subsystem to the debug log, so a script can assert on
    /// what the app *is* doing rather than on the last thing it happened to log. Honoured
    /// only under `ISLANDBAR_DEBUG=1`; driven by `Scripts/harness state`.
    static let debugDumpStateNotification = Notification.Name("dev.burbuja-lab.islandbar.debugDumpState")
}

let running = NSRunningApplication.runningApplications(withBundleIdentifier: IslandBarID.bundleID)
if running.count > 1 {
    DistributedNotificationCenter.default().postNotificationName(
        IslandBarID.reopenNotification,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
