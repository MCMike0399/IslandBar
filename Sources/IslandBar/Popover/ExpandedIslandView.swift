import SwiftUI

struct ExpandedIslandView: View {
    @Environment(NowPlayingStore.self) private var store

    var body: some View {
        ZStack {
            HUDBackground()
            HStack(alignment: .center, spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 6) {
                    MarqueeText(text: store.session?.title.isEmpty == false ? store.session!.title : "Not Playing", font: .headline.bold())
                        .frame(height: 16)
                    Text(store.session?.artist ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(store.session?.appName ?? "")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                    IslandBarsView(
                        levels: store.isPlaying ? store.barLevels : .rest,
                        palette: store.palette,
                        barWidth: 5,
                        gap: 3,
                        minHeight: 4,
                        maxHeight: 36
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 18) {
                        Button(action: { store.previousTrack() }) {
                            Image(systemName: "backward.end.fill")
                        }
                        .buttonStyle(.plain)
                        Button(action: { store.togglePlayPause() }) {
                            Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.plain)
                        Button(action: { store.nextTrack() }) {
                            Image(systemName: "forward.end.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.title3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .foregroundStyle(.white)
        }
        .frame(width: 280, height: 120)
        .environment(\.colorScheme, .dark)
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Group {
            if let image = store.session?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.2)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(shape)
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
            }
            .clipped()
            .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        }
    }

    private func marqueeOffset(time: TimeInterval, textWidth: CGFloat, viewWidth: CGFloat) -> CGFloat {
        let extra = textWidth - viewWidth
        guard extra > 0 else { return 0 }
        let pause = 1.1
        let speed = 26.0
        let travel = Double(extra + 12)
        let scroll = travel / speed
        let period = pause + scroll + 0.4
        let t = time.truncatingRemainder(dividingBy: period)
        if t < pause { return 0 }
        let p = min(1, (t - pause) / scroll)
        return -CGFloat(p) * CGFloat(travel)
    }
}
