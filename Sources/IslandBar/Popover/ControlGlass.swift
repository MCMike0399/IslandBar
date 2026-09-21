import AppKit
import SwiftUI

/// The card's shared visual language, lifted from Control Centre: grouped glass panels,
/// thick grabbable sliders with the glyphs *inside* the track, and round accessory buttons.
/// Every section is built from these three, so the panel reads as one control surface
/// rather than three stacked widgets.
enum ControlGlass {
    static let panelCorner: CGFloat = 16
    static let panelPadding: CGFloat = 10
    static let sliderHeight: CGFloat = 32
    static let sliderCorner: CGFloat = 10
    static let buttonSize: CGFloat = 30
    static let gutter: CGFloat = 8

    /// Fill of an unlit surface, and of the same surface under the pointer. Tuned against
    /// a pale wallpaper: the popover's material is translucent enough that a 10% white
    /// track disappeared into a light desktop, and an empty slider then read as a short
    /// one rather than a quiet one.
    static let surface = 0.16
    static let surfaceHover = 0.24
    static let border = 0.18
}

/// A grouped panel. One of these per section.
struct ControlPanel<Content: View>: View {
    var padding: CGFloat = ControlGlass.panelPadding
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ControlGlass.panelCorner, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Darkened rather than lightened, like Control Centre's Sound and Display
            // groups: it is what gives the white slider fills something to be white
            // against, whatever the desktop behind the popover happens to be.
            .background(shape.fill(.black.opacity(0.22)))
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }
}

/// The small bold heading Control Centre puts above a slider group. `detail` carries the
/// current choice on the right, and when `action` is given the whole row is the control
/// that changes it — which keeps the slider beside a mute button, like every other fader
/// on the card, instead of beside a second round button nobody can name.
struct PanelHeader: View {
    let title: String
    var detail: String?
    var isExpanded = false
    var action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .accessibilityLabel("Output device")
                .accessibilityValue(detail ?? "")
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(hovering || isExpanded ? 0.9 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if action != nil {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering || isExpanded ? 0.9 : 0.5))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .frame(height: 15)
        .contentShape(Rectangle())
    }
}

/// A thick glass slider. The whole body is the control, so there is no hairline track to
/// aim at and no knob to chase — the point being that it can be grabbed anywhere.
///
/// It takes *travel* (0...1, what the fill draws) rather than a volume, because the two
/// faders on this card map travel to level differently: the system slider is the scalar
/// macOS itself uses, while an app's fader is square-law so the quiet end gets the
/// resolution it actually needs.
struct ControlSlider: View {
    var travel: CGFloat
    var isDimmed = false
    var isEnabled = true
    /// Drawn inside the track at either end, the way Control Centre's Sound and Display
    /// sliders do. Each glyph is painted twice — light over the empty track, dark over the
    /// fill — so it stays legible wherever the fill happens to end.
    var leadingSymbol: String?
    var trailingSymbol: String?
    var height: CGFloat = ControlGlass.sliderHeight
    var accessibilityName: String
    var onScrub: (CGFloat) -> Void

    @State private var dragging = false
    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ControlGlass.sliderCorner, style: .continuous)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = fillWidth(in: width)
            ZStack(alignment: .leading) {
                shape.fill(.white.opacity(hovering || dragging ? ControlGlass.surfaceHover : ControlGlass.surface))
                // A rounded rect clipped to the track rather than a capsule, so the fill's
                // leading corners stay flush with the track's at every width.
                shape
                    .fill(.white.opacity(isDimmed ? 0.26 : 0.95))
                    .frame(width: fill)
                if leadingSymbol != nil || trailingSymbol != nil {
                    glyphs.foregroundStyle(.white.opacity(0.75))
                    glyphs
                        .foregroundStyle(.black.opacity(0.55))
                        .mask(alignment: .leading) { Color.black.frame(width: fill) }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(ControlGlass.border), lineWidth: 0.5))
            .contentShape(shape)
            .gesture(
                // Zero minimum distance so a click jumps to the cursor and keeps tracking,
                // which is what makes a knobless control obvious.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        dragging = true
                        onScrub(min(max(value.location.x / max(width, 1), 0), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: height)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Implicit animation lags the cursor during a drag; keep it for programmatic jumps.
        .animation(dragging ? nil : .smooth(duration: 0.18), value: travel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        // Travel, not level: the adjustable action steps travel, so reporting a squared
        // level would make the first arrow key appear to jump by a wildly different amount.
        .accessibilityValue(Double(travel).formatted(.percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step: CGFloat = 0.05
            switch direction {
            case .increment: onScrub(min(travel + step, 1))
            case .decrement: onScrub(max(travel - step, 0))
            default: break
            }
        }
    }

    private var glyphs: some View {
        HStack(spacing: 0) {
            symbol(leadingSymbol, size: 11)
            Spacer(minLength: 0)
            symbol(trailingSymbol, size: 13)
        }
        .padding(.horizontal, 9)
    }

    @ViewBuilder
    private func symbol(_ name: String?, size: CGFloat) -> some View {
        if let name {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .frame(width: 16)
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
    }

    /// Empty still reads as empty, but a sliver never looks like a rendering fault: below a
    /// corner's worth of travel the fill collapses entirely.
    private func fillWidth(in width: CGFloat) -> CGFloat {
        guard travel > 0.001 else { return 0 }
        return min(max(ControlGlass.sliderCorner * 2, travel * width), width)
    }
}

/// The circular button beside a slider, matching the round accessory buttons Control
/// Centre puts next to its own.
struct ControlCircleButton: View {
    let symbol: String
    var isOn = false
    var variableValue: Double?
    var size: CGFloat = ControlGlass.buttonSize
    var glyphSize: CGFloat = 12
    var accessibilityName: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white.opacity(isOn ? 0.95 : (hovering ? 0.18 : ControlGlass.surface)))
                    .overlay(Circle().strokeBorder(.white.opacity(ControlGlass.border), lineWidth: 0.5))
                Image(systemName: symbol, variableValue: variableValue)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.black.opacity(0.78)) : AnyShapeStyle(.white))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentTransition(.symbolEffect(.replace))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.16), value: isOn)
        .accessibilityLabel(accessibilityName)
    }
}

/// Mute glyph shared by every fader on the card: the waves fill with the slider beside it,
/// which ties the two controls together without a word between them.
func muteSymbol(isMuted: Bool) -> String {
    isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill"
}
