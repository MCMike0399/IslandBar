import AppKit
import SwiftUI

enum CompactIslandMetrics {
    static let barWidth: CGFloat = 2.5
    static let gap: CGFloat = 2
    /// Bars only, no artwork: N bars + (N-1) gaps, plus 8 pt insets each side.
    static let pillWidth: CGFloat = CGFloat(BarLevels.count) * barWidth + CGFloat(BarLevels.count - 1) * gap + 16
    static let pillHeight: CGFloat = 18
}

struct CompactIslandView: View {
    @Environment(NowPlayingStore.self) private var store
    @Environment(Preferences.self) private var preferences
    var buttonHeight: CGFloat

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let playing = store.isPlaying && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { _ in
            let levels = (playing ? store.barLevels : .rest)
            ZStack {
                if preferences.showPillBackground {
                    Capsule()
                        .fill(Color.black.opacity(0.92))
                }
                IslandBarsView(
                    levels: levels,
                    flat: !store.isPlaying,
                    palette: store.palette,
                    barWidth: CompactIslandMetrics.barWidth,
                    gap: CompactIslandMetrics.gap,
                    minHeight: 2.5,
                    maxHeight: 14
                )
            }
            .frame(width: CompactIslandMetrics.pillWidth, height: CompactIslandMetrics.pillHeight)
            .frame(width: CompactIslandMetrics.pillWidth, height: buttonHeight, alignment: .center)
        }
        .environment(\.colorScheme, .dark)
    }
}
