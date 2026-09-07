import SwiftUI

/// Single source of truth for the popover size so the SwiftUI frame and
/// `NSPopover.contentSize` can never disagree (a mismatch clips the card).
enum ExpandedIslandMetrics {
    static let width: CGFloat = 300
    static let height: CGFloat = 150
    static let padding: CGFloat = 14
    static let artwork: CGFloat = 72
    static var size: NSSize { NSSize(width: width, height: height) }
}

struct ExpandedIslandView: View {
    @Environment(NowPlayingStore.self) private var store

    var body: some View {
        ZStack {
            HUDBackground()
            HStack(alignment: .center, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 5) {
                    MarqueeText(text: displayTitle, font: .headline.bold())
                        .frame(height: 18)
                    Text(store.session?.artist ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                    Text(store.session?.appName ?? "")
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                        .frame(height: 18, alignment: .leading)
                    ExpandedBars()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 22) {
                        transportButton("backward.end.fill") { store.previousTrack() }
                        transportButton(store.isPlaying ? "pause.fill" : "play.fill") { store.togglePlayPause() }
                        transportButton("forward.end.fill") { store.nextTrack() }
                    }
                    .font(.title3)
                    .frame(height: 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
            .padding(ExpandedIslandMetrics.padding)
            .foregroundStyle(.white)
        }
        .frame(width: ExpandedIslandMetrics.width, height: ExpandedIslandMetrics.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private struct ExpandedBars: View {
        @Environment(NowPlayingStore.self) private var store

        var body: some View {
            IslandBarsView(
                flat: !store.isPlaying,
                animating: store.isPlaying && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                palette: store.palette,
                metrics: BarMetrics(barWidth: 5, gap: 3, minHeight: 4, maxHeight: 24),
                glow: true
            )
        }
    }

    private var displayTitle: String {
        guard let session = store.session else { return "Not Playing" }
        if !session.title.isEmpty { return session.title }
        if !session.artist.isEmpty { return session.artist }
        return session.appName
    }

    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Group {
            if let image = store.session?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Color(white: 0.2)
            }
        }
        .frame(width: ExpandedIslandMetrics.artwork, height: ExpandedIslandMetrics.artwork)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }
}

struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !overflow)) { timeline in
                let x = overflow
                    ? marqueeOffset(
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        textWidth: textWidth,
                        viewWidth: geo.size.width
                    )
                    : 0
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: WidthKey.self, value: inner.size.width)
                        }
                    )
                    .offset(x: x)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
            .clipped()
            .mask(edgeFade(overflow: overflow))
            .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        }
    }

    /// Soft fade on the trailing edge while the text is scrolling.
    private func edgeFade(overflow: Bool) -> some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: overflow ? 0.9 : 1),
                .init(color: overflow ? .clear : .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func marqueeOffset(time: TimeInterval, textWidth: CGFloat, viewWidth: CGFloat) -> CGFloat {
        let extra = textWidth - viewWidth
        guard extra > 0 else { return 0 }
        let pause = 1.4
        let speed = 28.0
        let travel = Double(extra + 16)
        let scroll = travel / speed
        let hold = 1.0
        let period = pause + scroll + hold
        let t = time.truncatingRemainder(dividingBy: period)
        if t < pause { return 0 }
        if t > pause + scroll { return -CGFloat(travel) }
        let p = (t - pause) / scroll
        // Ease in/out so the start and stop are not abrupt.
        let eased = 0.5 - 0.5 * cos(p * .pi)
        return -CGFloat(eased) * CGFloat(travel)
    }
}
