import AppKit
import Foundation
import Observation

/// Drives the update lifecycle: scheduled checks against GitHub Releases, the
/// notification / window that offers an update, and the download-verify-swap-relaunch.
@MainActor
@Observable
final class UpdateController {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease, received: Int64, total: Int64?)
        case verifying(UpdateRelease)
        case installing(UpdateRelease)
        case relaunching(UpdateRelease)
        case failed(message: String, release: UpdateRelease?)

        var release: UpdateRelease? {
            switch self {
            case .available(let r), .downloading(let r, _, _), .verifying(let r), .installing(let r), .relaunching(let r):
                r
            case .failed(_, let r):
                r
            case .idle, .checking, .upToDate:
                nil
            }
        }

        var isInstalling: Bool {
            switch self {
            case .downloading, .verifying, .installing, .relaunching: true
            default: false
            }
        }
    }

    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let minimumGapBetweenAutomaticChecks: TimeInterval = 60 * 60
    static let snoozeDuration: TimeInterval = 24 * 60 * 60
    /// Test hook for exercising the install path unattended. Only honoured together with a
    /// feed override, so it can never fire against the real GitHub feed.
    static var autoInstallForTesting: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ISLANDBAR_UPDATE_AUTO_INSTALL"] == "1" && env["ISLANDBAR_UPDATE_FEED_URL"] != nil
    }
    static var launchDelay: TimeInterval {
        ProcessInfo.processInfo.environment["ISLANDBAR_UPDATE_CHECK_DELAY"].flatMap(TimeInterval.init) ?? 20
    }

    private(set) var status: Status = .idle
    private(set) var lastCheck: Date?
    private(set) var skippedVersion: AppVersion?
    /// Why an in-place install cannot happen (translocation, read-only folder); nil when it can.
    let installBlocker: UpdateInstallError?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let notifications = UpdateNotifications()
    @ObservationIgnored private lazy var window = UpdateWindowController(updater: self)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    /// Bumped whenever a check / install starts so a superseded task cannot touch state
    /// after it is cancelled (URLSession surfaces cancellation as `URLError.cancelled`).
    @ObservationIgnored private var checkGeneration = 0
    @ObservationIgnored private var installGeneration = 0

    private enum Keys {
        static let lastCheck = "updates.lastCheck"
        static let skippedVersion = "updates.skippedVersion"
        static let snoozedVersion = "updates.snoozedVersion"
        static let snoozeUntil = "updates.snoozeUntil"
        static let notifiedVersion = "updates.notifiedVersion"
        static let notifiedAt = "updates.notifiedAt"
        static let announceVersion = "updates.announceVersion"
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        let defaults = UserDefaults.standard
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        skippedVersion = defaults.string(forKey: Keys.skippedVersion).flatMap(AppVersion.init)
        installBlocker = UpdateInstaller.installBlocker(for: Bundle.main.bundleURL)
        notifications.onAction = { [weak self] action, version in
            self?.handleNotification(action, version: version)
        }
    }

    func start() {
        notifications.activate()
        announceIfJustUpdated()

        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in self.automaticCheck(reason: "interval") }
        }
        timer?.tolerance = 15 * 60
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                self.automaticCheck(reason: "wake")
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.launchDelay))
            automaticCheck(reason: "launch", ignoringGap: true)
        }
        if let installBlocker {
            DebugLog.line("updates: in-place install blocked: \(installBlocker.localizedDescription)")
        }
    }

    // MARK: - Checking

    private func automaticCheck(reason: String, ignoringGap: Bool = false) {
        guard preferences.automaticUpdateChecks else { return }
        guard !status.isInstalling, checkTask == nil else { return }
        if !ignoringGap, let lastCheck, Date().timeIntervalSince(lastCheck) < Self.minimumGapBetweenAutomaticChecks {
            return
        }
        DebugLog.line("updates: automatic check (\(reason))")
        performCheck(userInitiated: false)
    }

    func checkForUpdates() {
        guard !status.isInstalling else { showWindow() ; return }
        if case .available = status {
            showWindow()
            return
        }
        performCheck(userInitiated: true)
    }

    private func performCheck(userInitiated: Bool) {
        checkTask?.cancel()
        checkGeneration += 1
        let generation = checkGeneration
        let previous = status
        status = .checking
        if userInitiated { showWindow() }
        checkTask = Task { @MainActor in
            defer { if generation == checkGeneration { checkTask = nil } }
            do {
                let release = try await UpdateFeed().fetchLatest()
                guard generation == checkGeneration else { return }
                lastCheck = Date()
                UserDefaults.standard.set(lastCheck, forKey: Keys.lastCheck)
                if let release, release.version > AppVersion.current {
                    DebugLog.line("updates: \(release.version) available (running \(AppVersion.current))")
                    status = .available(release)
                    if !userInitiated { offer(release) }
                } else {
                    DebugLog.line("updates: up to date (latest \(release?.version.description ?? "none"))")
                    status = .upToDate
                }
            } catch {
                guard generation == checkGeneration else { return }
                DebugLog.line("updates: check failed: \(error)")
                if userInitiated {
                    status = .failed(message: error.localizedDescription, release: nil)
                } else {
                    status = previous == .checking ? .idle : previous
                }
            }
        }
    }

    /// Automatic check found something: notify unless the user skipped or snoozed it.
    private func offer(_ release: UpdateRelease) {
        if let skippedVersion, skippedVersion == release.version {
            DebugLog.line("updates: \(release.version) skipped by user")
            return
        }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Keys.snoozedVersion) == release.version.description,
           let until = defaults.object(forKey: Keys.snoozeUntil) as? Date, until > Date() {
            DebugLog.line("updates: \(release.version) snoozed until \(until)")
            return
        }
        // An ignored notification is not repeated on every 6 h check; once a day is enough.
        if defaults.string(forKey: Keys.notifiedVersion) == release.version.description,
           let at = defaults.object(forKey: Keys.notifiedAt) as? Date,
           Date().timeIntervalSince(at) < Self.snoozeDuration {
            DebugLog.line("updates: \(release.version) already offered at \(at)")
            return
        }
        defaults.set(release.version.description, forKey: Keys.notifiedVersion)
        defaults.set(Date(), forKey: Keys.notifiedAt)
        if Self.autoInstallForTesting {
            DebugLog.line("updates: ISLANDBAR_UPDATE_AUTO_INSTALL set, installing without asking")
            install()
            return
        }
        Task { @MainActor in
            let delivered = await notifications.notifyAvailable(release)
            if !delivered {
                // Notifications denied or unavailable: the window is the only channel left.
                showWindow(activate: false)
            }
        }
    }

    // MARK: - User actions

    func showWindow(activate: Bool = true) {
        window.show(activate: activate)
    }

    func closeWindow() {
        window.close()
    }

    /// Red close button: while an update is on offer that means "not now", like Remind Me Later.
    func windowClosedByUser() {
        if case .available = status { remindLater() }
    }

    func remindLater() {
        if let release = status.release {
            UserDefaults.standard.set(release.version.description, forKey: Keys.snoozedVersion)
            UserDefaults.standard.set(Date().addingTimeInterval(Self.snoozeDuration), forKey: Keys.snoozeUntil)
        }
        closeWindow()
    }

    func skipOfferedRelease() {
        guard let release = status.release else { return }
        skippedVersion = release.version
        UserDefaults.standard.set(release.version.description, forKey: Keys.skippedVersion)
        notifications.removeAvailableNotification(for: release.version)
        status = .upToDate
        closeWindow()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(status.release?.pageURL ?? UpdateFeed.releasesPage)
    }

    func install() {
        guard let release = status.release, !status.isInstalling else { return }
        if let installBlocker {
            status = .failed(message: installBlocker.localizedDescription, release: release)
            showWindow()
            return
        }
        showWindow()
        notifications.removeAvailableNotification(for: release.version)
        status = .downloading(release, received: 0, total: release.archiveSize)
        installGeneration += 1
        let generation = installGeneration
        let installer = UpdateInstaller(release: release, currentApp: Bundle.main.bundleURL)
        installTask = Task { @MainActor in
            defer { if generation == installGeneration { installTask = nil } }
            do {
                let result = try await installer.install { progress in
                    Task { @MainActor in
                        guard generation == self.installGeneration else { return }
                        self.apply(progress, for: release)
                    }
                }
                guard generation == installGeneration else { return }
                status = .relaunching(release)
                relaunch(with: result, release: release)
            } catch {
                guard generation == installGeneration else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    status = .available(release)
                    return
                }
                DebugLog.line("updates: install failed: \(error)")
                status = .failed(message: error.localizedDescription, release: release)
                // The user may have closed the window during the download; a failure must be seen.
                showWindow()
            }
        }
    }

    func cancelInstall() {
        guard case .downloading(let release, _, _) = status else { return }
        installTask?.cancel()
        installTask = nil
        installGeneration += 1
        status = .available(release)
    }

    func retry() {
        switch status {
        case .failed(_, .some):
            install()
        default:
            performCheck(userInitiated: true)
        }
    }

    private func apply(_ progress: InstallProgress, for release: UpdateRelease) {
        guard status.isInstalling else { return }
        switch progress {
        case .downloading(let received, let total):
            // Progress hops are separate tasks; never let a late byte count undo "Verifying…".
            guard case .downloading = status else { return }
            status = .downloading(release, received: received, total: total)
        case .verifying:
            status = .verifying(release)
        case .installing:
            status = .installing(release)
        }
    }

    // MARK: - Relaunch

    /// A detached shell waits for this process to exit, opens the new bundle and then
    /// clears the parked previous version and the staging folder.
    private func relaunch(with result: InstalledUpdate, release: UpdateRelease) {
        UserDefaults.standard.set(release.version.description, forKey: Keys.announceVersion)
        let script = """
        trap '' HUP
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if [ "$5" = "1" ]; then
            /usr/bin/open --env ISLANDBAR_DEBUG=1 "$2"
        else
            /usr/bin/open "$2"
        fi
        sleep 8
        rm -rf "$3" "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "islandbar-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            result.appURL.path,
            result.backupURL.path,
            result.stagingDirectory.path,
            DebugLog.enabled ? "1" : "0",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            DebugLog.line("updates: relaunch helper failed: \(error)")
            status = .failed(
                message: "The update is installed, but IslandBar could not relaunch itself. Quit and reopen it.",
                release: release
            )
            return
        }
        DebugLog.line("updates: installed \(release.version), relaunching")
        // Give the window one frame to show "Relaunching…", then go through the normal quit path
        // (which also disarms the crash watchdog so it does not race the relaunch helper).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
        }
    }

    private func announceIfJustUpdated() {
        let defaults = UserDefaults.standard
        guard let announced = defaults.string(forKey: Keys.announceVersion) else { return }
        defaults.removeObject(forKey: Keys.announceVersion)
        guard let version = AppVersion(announced), version == AppVersion.current else { return }
        DebugLog.line("updates: running freshly installed \(version)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await notifications.notifyInstalled(version: version.description)
        }
    }

    private func handleNotification(_ action: UpdateNotifications.Action, version: String) {
        switch action {
        case .install:
            if status.release?.version.description == version {
                install()
            } else {
                checkForUpdates()
            }
        case .whatsNew:
            if status.release == nil { checkForUpdates() } else { showWindow() }
        case .skip:
            if status.release?.version.description == version { skipOfferedRelease() }
        case .open:
            NSWorkspace.shared.open(UpdateFeed.releasesPage)
        }
    }

    // MARK: - Presentation helpers

    var statusLine: String {
        switch status {
        case .checking:
            return "Checking for updates…"
        case .available(let release):
            return "IslandBar \(release.version) is available"
        case .downloading, .verifying, .installing, .relaunching:
            return "Installing update…"
        case .failed(let message, _):
            return message
        case .idle, .upToDate:
            guard let lastCheck else { return "Not checked yet" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Last checked \(formatter.localizedString(for: lastCheck, relativeTo: Date()))"
        }
    }
}
