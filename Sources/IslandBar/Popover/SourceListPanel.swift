import AppKit
import SwiftUI

enum SourceListMetrics {
    /// Tall enough to grab anywhere, following Control Centre's sliders rather than the
    /// hairline track a conventional slider draws.
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 6
    static let icon: CGFloat = 20
    /// A fixed column rather than a flexible one: names vary wildly in length, and sliders
    /// that start at a different x on every row look like a bug.
    static let name: CGFloat = 80
    /// Inset of the icon-and-name button, which is the row's "bring this to the front"
    /// control. Kept off the slider so the two never compete for the same pointer.
    static let selectorInset: CGFloat = 5

    /// Just the rows, without the panel's own padding — the height a scrolling list has to
    /// be pinned to, since a `ScrollView` under `fixedSize` would otherwise ask for all of
    /// its content.
    static func listHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        let visible = CGFloat(min(rows, SourcePlan.maxVisibleSources))
        return visible * rowHeight + (visible - 1) * rowSpacing
    }

    static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return ControlGlass.panelPadding * 2 + listHeight(rows: rows)
    }
}

/// Every other app currently holding an output connection — the per-app mixer macOS does
/// not have. One row each: the app's icon, its name, a fader, and a mute.
///
/// The playing app is not here; it is the hero above, with the same fader built into it.
/// Nothing on this card is listed twice.
struct SourceListPanel: View {
    let rows: [MixerRow]
    @Environment(AudioMixer.self) private var mixer

    var body: some View {
        ControlPanel {
            // The card grows to fit up to `maxVisibleSources`, so scrolling only ever
            // applies beyond that. Below it a plain stack is both correct and one less
            // thing between the pointer and a slider.
            if rows.count > SourcePlan.maxVisibleSources {
                ScrollView(.vertical) { list }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                    .frame(height: SourceListMetrics.listHeight(rows: rows.count))
            } else {
                list
            }
        }
        .animation(listAnimation, value: rows.map(\.id))
    }

    private var list: some View {
        VStack(spacing: SourceListMetrics.rowSpacing) {
            ForEach(rows) { row in
                SourceRow(row: row, isFocused: row.id == mixer.focusedID, mixer: mixer)
            }
        }
    }

    private var listAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.28)
    }
}

private struct SourceRow: View {
    let row: MixerRow
    let isFocused: Bool
    let mixer: AudioMixer

    @State private var hovering = false

    /// Travel is the square root of gain, so half-way sounds roughly half as loud and the
    /// quiet end gets the resolution where it is actually wanted.
    private var travel: CGFloat { CGFloat(sqrt(max(row.gain, 0))) }

    var body: some View {
        HStack(spacing: ControlGlass.gutter) {
            selector
            ControlSlider(
                travel: travel,
                isDimmed: row.isMuted,
                isEnabled: row.isAvailable,
                accessibilityName: row.name,
                onScrub: { mixer.setGain(Float($0 * $0), for: row.id) }
            )
            ControlCircleButton(
                symbol: muteSymbol(isMuted: row.isMuted),
                isOn: row.isMuted,
                variableValue: row.isMuted ? 1 : Double(travel),
                size: 28,
                glyphSize: 11,
                accessibilityName: row.isMuted ? "Unmute \(row.name)" : "Mute \(row.name)"
            ) {
                mixer.toggleMute(row.id)
            }
        }
        .frame(height: SourceListMetrics.rowHeight)
        .opacity(row.isAvailable ? 1 : 0.35)
    }

    /// The app's identity *and* the control that brings it to the front. Deliberately the
    /// icon and the name rather than the whole row: the slider fills most of a row and must
    /// stay a slider, so the selector is the one part of it that was never draggable.
    private var selector: some View {
        Button { mixer.focus(row.id) } label: {
            HStack(spacing: ControlGlass.gutter) {
                icon
                Text(row.name)
                    .font(.system(size: 11, weight: isFocused ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(row.isMuted ? 0.45 : (isFocused ? 1 : 0.85)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .frame(width: SourceListMetrics.name, alignment: .leading)
            }
            .padding(.horizontal, SourceListMetrics.selectorInset)
            .frame(height: SourceListMetrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: ControlGlass.sliderCorner, style: .continuous)
                    .fill(.white.opacity(isFocused ? 0.16 : (hovering ? 0.08 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(isFocused ? "\(row.name) — click to restore the order" : "Show \(row.name) first")
        .accessibilityLabel(isFocused ? "\(row.name), shown first" : "Show \(row.name) first")
    }

    private var icon: some View {
        Group {
            if let image = row.icon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.22))
            }
        }
        .frame(width: SourceListMetrics.icon, height: SourceListMetrics.icon)
        .opacity(row.isMuted ? 0.45 : 1)
        .animation(.easeOut(duration: 0.16), value: row.isMuted)
        .accessibilityHidden(true)
    }
}
