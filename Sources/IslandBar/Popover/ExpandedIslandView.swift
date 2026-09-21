import AppKit
import SwiftUI

/// Single source of truth for the popover's size. The card's height depends on what is
/// playing, on how many apps the mixer is showing, and on whether the output list is open,
/// so the SwiftUI root does not pin it: `StatusItemController` sets `NSPopover.contentSize`
/// and the hosting view's frame together from these numbers, and the root fills what it is
/// given. That keeps one authority for a height that changes, instead of three that have
/// to be kept in agreement.
enum ExpandedIslandMetrics {
    /// Control Centre's own width, near enough. The card is a mixing desk now: a fader per
    /// source needs room for a name and a usable throw, which 300 did not have.
    static let width: CGFloat = 340
    static let padding: CGFloat = 14
    static let sectionGap: CGFloat = 10

    /// Nothing playing, nothing making noise: just the system's output. The card is never
    /// empty, which is the whole point of the redesign.
    static var idleSize: NSSize {
        NSSize(width: width, height: padding * 2 + SoundMetrics.base)
    }

    /// Everything except the output list. This is the part `StatusItemController` holds
    /// monotonic while the popover is open, so a row can never vanish from under a fader
    /// mid-drag.
    static func baseHeight(for plan: SourcePlan) -> CGFloat {
        var sections: [CGFloat] = []
        if plan.hasHero {
            sections.append(NowPlayingMetrics.height(hasFader: !DebugLog.mixerDisabled))
        }
        if !plan.others.isEmpty {
            sections.append(SourceListMetrics.height(rows: plan.others.count))
        }
        sections.append(SoundMetrics.base)
        let gaps = sectionGap * CGFloat(max(sections.count - 1, 0))
        return padding * 2 + sections.reduce(0, +) + gaps
    }

    /// The output list, which the user opened and may close again.
    static func pickerHeight(for plan: SourcePlan) -> CGFloat {
        SoundMetrics.picker(devices: plan.outputDeviceCount, expanded: plan.isPickingOutput)
    }

    static func size(for plan: SourcePlan) -> NSSize {
        NSSize(width: width, height: baseHeight(for: plan) + pickerHeight(for: plan))
    }
}

/// The expanded card: every audio source on the Mac, and the output they all land in.
///
/// One list, not two. The source with a Now Playing session is drawn as a tile with its
/// artwork and transport; every other app holding an output connection is the same control
/// at row size. Nothing appears twice, and the panel degrades cleanly — no session means no
/// tile, no apps means no list, and the Sound panel is always there.
struct ExpandedIslandView: View {
    @Environment(NowPlayingStore.self) private var store
    @Environment(AudioMixer.self) private var mixer
    @Environment(SystemAudioController.self) private var system

    var body: some View {
        let plan = SourcePlan.make(session: store.session, mixer: mixer, system: system)
        // Top-aligned: the card's height is monotonic while it is open, so when a source
        // disappears the card stays tall for a moment. A centred stack would slide
        // everything down into the gap.
        //
        // The blurred backdrop is deliberately *not* here. It is an `NSVisualEffectView`
        // installed as the popover's own container (see `StatusItemController`), because a
        // representable inside this tree is resized by a SwiftUI layout pass that lands
        // after the popover's frame has already grown: the blur stayed at the old height
        // and the strip below it showed the window's raw backing, which read as the Sound
        // panel being cut off below its slider.
        VStack(spacing: ExpandedIslandMetrics.sectionGap) {
            if plan.hasHero {
                NowPlayingPanel(row: plan.heroRow)
            }
            if !plan.others.isEmpty {
                SourceListPanel(rows: plan.others)
            }
            SoundPanel()
        }
        // Ideal heights, never negotiated. The card's height is resized from outside
        // SwiftUI, so for a frame after a section grows the stack is still being offered
        // the old height; without this the panels compress to fit.
        .fixedSize(horizontal: false, vertical: true)
        .padding(ExpandedIslandMetrics.padding)
        .frame(width: ExpandedIslandMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }
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
                    .clipped()
                    // The mask follows the scroll rather than sitting still: a title that
                    // has moved left is cut mid-word at the leading edge, and a hard cut
                    // there reads as a clipping bug rather than as a marquee.
                    .mask(edgeFade(trailing: overflow, leading: x < -1))
            }
            .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        }
    }

    private func edgeFade(trailing: Bool, leading: Bool) -> some View {
        LinearGradient(
            stops: [
                .init(color: leading ? .clear : .black, location: 0),
                .init(color: .black, location: leading ? 0.06 : 0),
                .init(color: .black, location: trailing ? 0.92 : 1),
                .init(color: trailing ? .clear : .black, location: 1),
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
