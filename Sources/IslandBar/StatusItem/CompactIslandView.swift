import AppKit
import SwiftUI

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
                HStack(spacing: 4) {
                    artwork
                    Spacer(minLength: 0)
                    IslandBarsView(
                        levels: levels,
                        palette: store.palette,
                        barWidth: 2.5,
                        gap: 2,
                        minHeight: 2.5,
                        maxHeight: 14
                    )
                }
                .padding(.leading, 2)
                .padding(.trailing, 8)
            }
            .frame(width: 62, height: 18)
            .frame(width: 62, height: buttonHeight, alignment: .center)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Group {
            if let image = store.session?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Color(white: 0.22)
            }
        }
        .frame(width: 14, height: 14)
        .clipShape(shape)
    }
}
