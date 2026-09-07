import SwiftUI

struct SettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(UpdateController.self) private var updater

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Launch at Login", isOn: $preferences.launchAtLogin)
                Toggle("Show island pill background", isOn: $preferences.showPillBackground)
                Picker("Analysis source", selection: $preferences.analysisSource) {
                    ForEach(AnalysisSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $preferences.automaticUpdateChecks)
                LabeledContent("Version", value: "\(AppVersion.current) (\(AppVersion.currentBuild))")
                HStack(alignment: .firstTextBaseline) {
                    Text(updater.statusLine)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(updateButtonTitle) { updater.checkForUpdates() }
                        .disabled(updater.status == .checking)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 330)
        .padding(.bottom, 8)
    }

    private var updateButtonTitle: String {
        if case .available = updater.status { return "Update…" }
        if updater.status.isInstalling { return "Show Progress" }
        return "Check Now"
    }
}
