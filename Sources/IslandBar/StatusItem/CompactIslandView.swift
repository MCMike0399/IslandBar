import AppKit
import SwiftUI

enum CompactIslandMetrics {
    /// Thin bars on a 3.5 pt pitch: whole pixels at 2x, so edges stay crisp.
    static let bars = BarMetrics(barWidth: 2, gap: 1.5, minHeight: 2, maxHeight: 14)
    /// Bars only, no artwork: N bars + (N-1) gaps, plus 8 pt insets each side.
    static let pillWidth: CGFloat = bars.totalWidth + 16
    static let pillHeight: CGFloat = 18
}

struct CompactIslandView: View {
    @Environment(NowPlayingStore.self) private var store
    @Environment(Preferences.self) private var preferences
    /// The menu bar's own appearance, inherited from the status item's button: a light
    /// menu bar is `light`, a dark one `dark`. Deliberately not forced to dark — the
    /// capsule below is what makes a dark menu bar work, and on a light one it would
    /// sit there as a hard black pill.
    @Environment(\.colorScheme) private var colorScheme
    var buttonHeight: CGFloat

    /// On a light menu bar the pill's black capsule is dropped and the bars darken so
    /// they stay readable against white.
    private var onLightMenuBar: Bool { DebugLog.forcedPillIsLight ?? (colorScheme == .light) }

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // This body only runs on the rare changes below (play state, palette, background
        // toggle, menu bar appearance); level frames go straight to the layer view.
        ZStack {
            if preferences.showPillBackground && !onLightMenuBar {
                Capsule()
                    .fill(Color.black.opacity(0.92))
            }
            IslandBarsView(
                flat: !store.isPlaying,
                animating: store.isPlaying && !reduceMotion,
                palette: store.palette,
                metrics: CompactIslandMetrics.bars,
                lightBackground: onLightMenuBar
            )
        }
        .frame(width: CompactIslandMetrics.pillWidth, height: CompactIslandMetrics.pillHeight)
        .frame(width: CompactIslandMetrics.pillWidth, height: buttonHeight, alignment: .center)
    }
}
