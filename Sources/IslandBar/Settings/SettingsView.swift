import SwiftUI

struct SettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Toggle("Launch at Login", isOn: $preferences.launchAtLogin)
            Toggle("Show island pill background", isOn: $preferences.showPillBackground)
            Picker("Analysis source", selection: $preferences.analysisSource) {
                ForEach(AnalysisSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 190)
        .padding(.bottom, 8)
    }
}
