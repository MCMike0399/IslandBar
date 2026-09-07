import AppKit

enum IslandBarID {
    static let bundleID = "dev.burbuja-lab.islandbar"
    static let reopenNotification = Notification.Name("dev.burbuja-lab.islandbar.reopen")
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
