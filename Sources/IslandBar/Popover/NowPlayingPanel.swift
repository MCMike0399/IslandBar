import AppKit
import SwiftUI

enum NowPlayingMetrics {
    static let artwork: CGFloat = 80
    static let faderGap: CGFloat = 10

    /// The fader's presence follows the *mixer*, not the row. A row comes and goes with
    /// playback — a track change alone drops one for a second or two — and letting that
    /// decide the tile's height made the whole card below it jump by 42 points while the
    /// user was looking at it. With the mixer running the fader is always there; with the
    /// mixer off it never is.
    static func height(hasFader: Bool) -> CGFloat {
        ControlGlass.panelPadding * 2
            + artwork
            + (hasFader ? faderGap + ControlGlass.sliderHeight : 0)
    }
}

/// The source that is actually playing, drawn large: artwork, title, artist, the live bars,
/// transport, and its own fader.
///
/// Everything else on the card is a row; this is the one source that earns a tile, because
/// it is the only one MediaRemote can tell us anything about. The rest of the list is
/// deliberately the same control at a smaller size, so "the thing playing" and "the other
/// things making noise" are visibly the same kind of object.
struct NowPlayingPanel: View {
    let row: MixerRow?
    @Environment(NowPlayingStore.self) private var store
    @Environment(AudioMixer.self) private var mixer

    var body: some View {
        ControlPanel {
            VStack(spacing: NowPlayingMetrics.faderGap) {
                HStack(alignment: .top, spacing: 12) {
                    artwork
                    details
                }
                .frame(height: NowPlayingMetrics.artwork)
                if showsFader {
                    fader(row)
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(text: displayTitle, font: .system(size: 14, weight: .semibold))
                .frame(height: 18)
            Spacer(minLength: 0).frame(height: 2)
            Text(store.session?.artist ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 15, alignment: .leading)
            Spacer(minLength: 0).frame(height: 3)
            meta
            Spacer(minLength: 0)
            transport
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// The bars and the app's name on one line: the visualiser is IslandBar's signature and
    /// the source's name belongs beside it, not in a badge of its own.
    private var meta: some View {
        HStack(spacing: 7) {
            HeroBars()
            Text(sourceName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            transportButton("backward.fill", size: 13) { store.previousTrack() }
            transportButton(store.isPlaying ? "pause.fill" : "play.fill", size: 16) { store.togglePlayPause() }
            transportButton("forward.fill", size: 13) { store.nextTrack() }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    private var showsFader: Bool { !DebugLog.mixerDisabled }

    /// Rendered with no row when the mixer cannot see the playing app — dimmed and inert,
    /// holding its place. Losing the control for a moment is a smaller lie than the card
    /// reflowing under the pointer every time a track changes.
    @ViewBuilder
    private func fader(_ row: MixerRow?) -> some View {
        let live = row?.isAvailable == true
        HStack(spacing: ControlGlass.gutter) {
            ControlSlider(
                travel: CGFloat(sqrt(max(row?.gain ?? 1, 0))),
                isDimmed: row?.isMuted == true,
                isEnabled: live,
                leadingSymbol: "speaker.fill",
                accessibilityName: row?.name ?? "Volume",
                onScrub: { value in
                    guard let row else { return }
                    mixer.setGain(Float(value * value), for: row.id)
                }
            )
            ControlCircleButton(
                symbol: muteSymbol(isMuted: row?.isMuted == true),
                isOn: row?.isMuted == true,
                variableValue: row?.isMuted == true ? 1 : Double(sqrt(max(row?.gain ?? 1, 0))),
                accessibilityName: row.map { $0.isMuted ? "Unmute \($0.name)" : "Mute \($0.name)" }
                    ?? "Mute"
            ) {
                if let row { mixer.toggleMute(row.id) }
            }
            .disabled(!live)
        }
        .frame(height: ControlGlass.sliderHeight)
        .opacity(live ? 1 : 0.35)
    }

    private struct HeroBars: View {
        @Environment(NowPlayingStore.self) private var store
        @Environment(Preferences.self) private var preferences

        var body: some View {
            let barCount = preferences.visualizerBarCount
            IslandBarsView(
                flat: !store.isPlaying,
                animating: store.isPlaying && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                palette: store.palette,
                metrics: BarMetrics(barWidth: 3, gap: 2, minHeight: 2.5, maxHeight: 16, count: barCount),
                glow: true
            )
            .id(barCount)
        }
    }

    /// The app a person would name. MediaRemote reports whichever process registered the
    /// session, so a WebKit app arrives calling itself "Safari Graphics and Media"; the
    /// mixer's row carries the name of the `.app` that owns it.
    private var sourceName: String {
        row?.name ?? store.session?.appName ?? ""
    }

    private var displayTitle: String {
        guard let session = store.session else { return "Not Playing" }
        if !session.title.isEmpty { return session.title }
        if !session.artist.isEmpty { return session.artist }
        let name = sourceName.isEmpty ? session.appName : sourceName
        return store.isPlaying ? "Playing in \(name)" : name
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Group {
            if let image = store.session?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.18)
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: NowPlayingMetrics.artwork, height: NowPlayingMetrics.artwork)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 7, y: 3)
    }
}
