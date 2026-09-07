import AppKit
import SwiftUI

enum CompactIslandMetrics {
    static let bars = BarMetrics(barWidth: 2.5, gap: 2, minHeight: 2.5, maxHeight: 14)
    /// Bars only, no artwork: N bars + (N-1) gaps, plus 8 pt insets each side.
    static let pillWidth: CGFloat = bars.totalWidth + 16
    static let pillHeight: CGFloat = 18
}

struct CompactIslandView: View {
    @Environment(NowPlayingStore.self) private var store
    @Environment(Preferences.self) private var preferences
    var buttonHeight: CGFloat

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // This body only runs on the rare changes below (play state, palette,
        // background toggle); level frames go straight to the layer view.
        ZStack {
            if preferences.showPillBackground {
                Capsule()
                    .fill(Color.black.opacity(0.92))
            }
            IslandBarsView(
                flat: !store.isPlaying,
                animating: store.isPlaying && !reduceMotion,
                palette: store.palette,
                metrics: CompactIslandMetrics.bars
            )
        }
        .frame(width: CompactIslandMetrics.pillWidth, height: CompactIslandMetrics.pillHeight)
        .frame(width: CompactIslandMetrics.pillWidth, height: buttonHeight, alignment: .center)
        .environment(\.colorScheme, .dark)
    }
}
