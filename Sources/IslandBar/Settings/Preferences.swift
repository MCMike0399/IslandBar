import Foundation
import Observation
import ServiceManagement

enum AnalysisSource: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case allSystemOutput
    case proceduralOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .allSystemOutput: "All system output"
        case .proceduralOnly: "Procedural only"
        }
    }
}

struct PreferencesSnapshot: Sendable {
    var showPillBackground: Bool
    var analysisSource: AnalysisSource
}

@MainActor
@Observable
final class Preferences {
    var showPillBackground: Bool {
        didSet { UserDefaults.standard.set(showPillBackground, forKey: Keys.showPillBackground) }
    }
    var analysisSource: AnalysisSource {
        didSet { UserDefaults.standard.set(analysisSource.rawValue, forKey: Keys.analysisSource) }
    }
    var automaticUpdateChecks: Bool {
        didSet { UserDefaults.standard.set(automaticUpdateChecks, forKey: Keys.automaticUpdateChecks) }
    }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                DebugLog.line("launchAtLogin failed: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var snapshot: PreferencesSnapshot {
        PreferencesSnapshot(
            showPillBackground: showPillBackground,
            analysisSource: analysisSource
        )
    }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: Keys.showPillBackground) == nil {
            d.set(true, forKey: Keys.showPillBackground)
        }
        showPillBackground = d.object(forKey: Keys.showPillBackground) as? Bool ?? true
        let raw = d.string(forKey: Keys.analysisSource) ?? AnalysisSource.automatic.rawValue
        analysisSource = AnalysisSource(rawValue: raw) ?? .automatic
        automaticUpdateChecks = d.object(forKey: Keys.automaticUpdateChecks) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private enum Keys {
        static let showPillBackground = "showPillBackground"
        static let analysisSource = "analysisSource"
        static let automaticUpdateChecks = "automaticUpdateChecks"
    }
}
