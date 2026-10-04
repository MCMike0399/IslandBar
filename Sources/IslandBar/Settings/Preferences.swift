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
    var barCount: Int
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
    /// Bars drawn by the visualizer, 8…12. Clamped on the way in so a hand-edited
    /// defaults file cannot take the pipeline out of the range its buffers assume.
    var visualizerBarCount: Int {
        didSet {
            let clamped = BarCount.clamped(visualizerBarCount)
            if clamped != visualizerBarCount {
                visualizerBarCount = clamped
                return
            }
            UserDefaults.standard.set(visualizerBarCount, forKey: Keys.visualizerBarCount)
        }
    }
    /// Stop capturing audio while the menu bar is hidden (full screen, or the desktop's own
    /// auto-hide). Nothing can see the bars then, and the capture is what lights macOS's
    /// purple recording indicator.
    var pauseCaptureWhileMenuBarHidden: Bool {
        didSet {
            UserDefaults.standard.set(pauseCaptureWhileMenuBarHidden, forKey: Keys.pauseCaptureWhileMenuBarHidden)
        }
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
            analysisSource: analysisSource,
            barCount: visualizerBarCount
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
        let storedBarCount = d.object(forKey: Keys.visualizerBarCount) as? Int ?? BarCount.default
        visualizerBarCount = BarCount.clamped(storedBarCount)
        pauseCaptureWhileMenuBarHidden = d.object(forKey: Keys.pauseCaptureWhileMenuBarHidden) as? Bool ?? true
        automaticUpdateChecks = d.object(forKey: Keys.automaticUpdateChecks) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private enum Keys {
        static let showPillBackground = "showPillBackground"
        static let analysisSource = "analysisSource"
        static let visualizerBarCount = "visualizerBarCount"
        static let pauseCaptureWhileMenuBarHidden = "pauseCaptureWhileMenuBarHidden"
        static let automaticUpdateChecks = "automaticUpdateChecks"
    }
}
