import SwiftUI

struct UpdateView: View {
    static let size = CGSize(width: 520, height: 330)

    @Environment(UpdateController.self) private var updater

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: iconName)
                .font(.system(size: 46, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconTint)
                .frame(width: 56, height: 56)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
                Spacer(minLength: 0)
                buttons
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    // MARK: - Copy

    private var release: UpdateRelease? { updater.status.release }

    private var iconName: String {
        switch updater.status {
        case .failed: "exclamationmark.triangle.fill"
        case .upToDate: "checkmark.circle.fill"
        case .relaunching: "arrow.clockwise.circle.fill"
        default: "arrow.down.app.fill"
        }
    }

    private var iconTint: AnyShapeStyle {
        switch updater.status {
        case .failed: AnyShapeStyle(.orange)
        case .upToDate: AnyShapeStyle(.green)
        default: AnyShapeStyle(.tint)
        }
    }

    private var title: String {
        switch updater.status {
        case .idle: "Check for Updates"
        case .checking: "Checking for Updates…"
        case .upToDate: "IslandBar is up to date"
        case .available(let r): "IslandBar \(r.version) is available"
        case .downloading(let r, _, _): "Downloading IslandBar \(r.version)…"
        case .verifying: "Verifying the download…"
        case .installing: "Installing…"
        case .relaunching: "Relaunching IslandBar…"
        case .failed(_, let r): r == nil ? "Couldn’t check for updates" : "The update couldn’t be installed"
        }
    }

    private var subtitle: String {
        let current = "You have \(AppVersion.current)."
        switch updater.status {
        case .idle:
            return "IslandBar checks GitHub Releases for new versions."
        case .checking:
            return current
        case .upToDate:
            return "\(AppVersion.current) is the newest version available."
        case .available(let r):
            var text = current
            if let date = r.publishedAt {
                text += " Released \(date.formatted(date: .abbreviated, time: .omitted))."
            }
            return text
        case .downloading, .verifying, .installing:
            return "IslandBar keeps running until the new version is in place."
        case .relaunching:
            return "The pill will be back in a moment."
        case .failed(let message, _):
            return message
        }
    }

    // MARK: - Body parts

    @ViewBuilder
    private var content: some View {
        switch updater.status {
        case .available(let release):
            ReleaseNotesView(notes: release.notes)
            if let blocker = updater.installBlocker {
                Label(blocker.localizedDescription, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("macOS may ask for System Audio Recording again after updating.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .downloading(_, let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                if let total, total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                    Text("\(Self.bytes(received)) of \(Self.bytes(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text(Self.bytes(received))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.top, 8)
        case .checking, .verifying, .installing, .relaunching:
            ProgressView()
                .progressViewStyle(.linear)
                .padding(.top, 8)
        case .failed(_, let release):
            if let release {
                ReleaseNotesView(notes: release.notes)
            }
        case .idle, .upToDate:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            switch updater.status {
            case .available:
                Button("Skip This Version") { updater.skipOfferedRelease() }
                Spacer()
                Button("Remind Me Later") { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
                if updater.installBlocker == nil {
                    Button("Install and Relaunch") { updater.install() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Download from GitHub") { updater.openReleasePage() }
                        .keyboardShortcut(.defaultAction)
                }
            case .downloading:
                Spacer()
                Button("Cancel") { updater.cancelInstall() }
                    .keyboardShortcut(.cancelAction)
            case .checking, .verifying, .installing, .relaunching:
                Spacer()
                Button("Cancel") {}
                    .disabled(true)
            case .failed:
                Button("Open Release Page") { updater.openReleasePage() }
                Spacer()
                Button("Close") { updater.closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { updater.retry() }
                    .keyboardShortcut(.defaultAction)
            case .upToDate:
                Spacer()
                Button("OK") { updater.closeWindow() }
                    .keyboardShortcut(.defaultAction)
            case .idle:
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.regular)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Release notes are GitHub Markdown. Headings, bullets and inline emphasis are enough
/// for a changelog; anything else is shown as plain text.
struct ReleaseNotesView: View {
    let notes: String

    var body: some View {
        GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if notes.isEmpty {
                        Text("No release notes were provided for this version.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(notes.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                            line(String(raw))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
        .font(.callout)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if trimmed.hasPrefix("#") {
            Text(inline(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                .font(.callout.weight(.semibold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(trimmed.dropFirst(2))))
            }
            .padding(.leading, raw.prefix(while: { $0 == " " }).count >= 2 ? 16 : 0)
        } else {
            Text(inline(trimmed))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
