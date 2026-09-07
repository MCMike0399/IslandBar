import AppKit
import Foundation
import UserNotifications

/// User Notifications for the updater: "update available" with inline actions, and a
/// one-shot "updated to X" after a successful relaunch.
@MainActor
final class UpdateNotifications: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String {
        case install = "INSTALL"
        case whatsNew = "WHATS_NEW"
        case skip = "SKIP"
        case open = "OPEN"
    }

    nonisolated private static let availableCategory = "dev.burbuja-lab.islandbar.update-available"
    nonisolated private static let installedCategory = "dev.burbuja-lab.islandbar.update-installed"
    nonisolated private static let versionKey = "version"

    /// Invoked on the main actor with the action and the version the notification was about.
    var onAction: ((Action, String) -> Void)?

    /// `UNUserNotificationCenter.current()` traps in an unbundled process, so only touch it
    /// when running from a real bundle.
    private let center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }()

    func activate() {
        guard let center else {
            DebugLog.line("notifications unavailable: not running from a bundle")
            return
        }
        center.delegate = self
        let install = UNNotificationAction(
            identifier: Action.install.rawValue, title: "Install and Relaunch", options: [.foreground]
        )
        let whatsNew = UNNotificationAction(
            identifier: Action.whatsNew.rawValue, title: "What’s New", options: [.foreground]
        )
        let skip = UNNotificationAction(identifier: Action.skip.rawValue, title: "Skip This Version", options: [])
        let available = UNNotificationCategory(
            identifier: Self.availableCategory,
            actions: [install, whatsNew, skip],
            intentIdentifiers: [],
            options: []
        )
        let open = UNNotificationAction(identifier: Action.open.rawValue, title: "See What’s New", options: [.foreground])
        let installed = UNNotificationCategory(
            identifier: Self.installedCategory, actions: [open], intentIdentifiers: [], options: []
        )
        center.setNotificationCategories([available, installed])
    }

    /// Asks for permission the first time it is needed. Returns `false` when notifications
    /// are unavailable or denied, so the caller can fall back to showing a window.
    private func ensureAuthorized() async -> Bool {
        guard let center else { return false }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    func notifyAvailable(_ release: UpdateRelease) async -> Bool {
        guard await ensureAuthorized(), let center else { return false }
        let content = UNMutableNotificationContent()
        content.title = "IslandBar \(release.version) is available"
        content.body = Self.summary(of: release.notes) ?? "You have \(AppVersion.current). Install now or see what’s new."
        content.categoryIdentifier = Self.availableCategory
        content.userInfo = [Self.versionKey: release.version.description]
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: "update-available-\(release.version)", content: content, trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            DebugLog.line("notification add failed: \(error)")
            return false
        }
    }

    func notifyInstalled(version: String) async {
        guard await ensureAuthorized(), let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "IslandBar was updated to \(version)"
        content.body = "The new version is running now."
        content.categoryIdentifier = Self.installedCategory
        content.userInfo = [Self.versionKey: version]
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: "update-installed-\(version)", content: content, trigger: nil)
        try? await center.add(request)
    }

    func removeAvailableNotification(for version: AppVersion) {
        center?.removeDeliveredNotifications(withIdentifiers: ["update-available-\(version)"])
    }

    /// First meaningful line of the release notes, trimmed to a banner-sized sentence.
    static func summary(of notes: String) -> String? {
        for rawLine in notes.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#-*>".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            guard line.count > 3 else { continue }
            if line.count > 110 {
                let cut = line.index(line.startIndex, offsetBy: 107)
                return String(line[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
            }
            return line
        }
        return nil
    }

    // MARK: - UNUserNotificationCenterDelegate (called on an arbitrary queue)

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A menu-bar app counts as "frontmost" often enough that the default (suppress) would hide us.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let version = response.notification.request.content.userInfo[Self.versionKey] as? String ?? ""
        let action: Action?
        switch identifier {
        case UNNotificationDefaultActionIdentifier:
            action = category == Self.installedCategory ? .open : .whatsNew
        case UNNotificationDismissActionIdentifier:
            action = nil
        default:
            action = Action(rawValue: identifier)
        }
        if let action {
            Task { @MainActor in self.onAction?(action, version) }
        }
        completionHandler()
    }
}
