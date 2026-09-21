import AppKit
import SwiftUI

enum SoundMetrics {
    static let header: CGFloat = 15
    static let headerGap: CGFloat = 6
    static let deviceRow: CGFloat = 28
    static let deviceSpacing: CGFloat = 2
    static let deviceGap: CGFloat = 8

    /// The panel with its output list closed. This is the part of the card's height that
    /// only ever grows while the popover is open.
    static let base: CGFloat =
        ControlGlass.panelPadding * 2 + header + headerGap + ControlGlass.sliderHeight

    /// The output list, which the user opens and closes themselves — so unlike everything
    /// else on the card, this part is allowed to shrink again.
    static func picker(devices: Int, expanded: Bool) -> CGFloat {
        guard expanded, devices > 0 else { return 0 }
        let visible = CGFloat(min(devices, SourcePlan.maxVisibleDevices))
        return deviceGap + visible * deviceRow + (visible - 1) * deviceSpacing
    }
}

/// The system's own output: the volume every app is mixed into, and which device it comes
/// out of. Always present, which is what makes the card worth opening when nothing is
/// playing at all.
///
/// Unlike the per-app faders above it, nothing here costs a process tap or a permission —
/// it is the same CoreAudio the menu bar's sound item drives.
struct SoundPanel: View {
    @Environment(SystemAudioController.self) private var system

    var body: some View {
        ControlPanel {
            VStack(spacing: 0) {
                PanelHeader(
                    title: "Sound",
                    detail: system.device?.name,
                    isExpanded: system.isPickingOutput,
                    action: system.devices.count > 1 ? { system.toggleOutputPicker() } : nil
                )
                Spacer(minLength: 0).frame(height: SoundMetrics.headerGap)
                controls
                if system.isPickingOutput, !system.devices.isEmpty {
                    Spacer(minLength: 0).frame(height: SoundMetrics.deviceGap)
                    deviceList
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: ControlGlass.gutter) {
            ControlSlider(
                // The level, not zero, while muted: the fader stays where it was so the
                // level unmuting will restore is visible rather than guessed at — the same
                // rule the per-app faders follow.
                travel: CGFloat(system.volume),
                isDimmed: system.isMuted,
                isEnabled: system.canSetVolume,
                leadingSymbol: "speaker.fill",
                trailingSymbol: "speaker.wave.3.fill",
                accessibilityName: "Output volume",
                onScrub: { system.setVolume(Float($0)) }
            )
            ControlCircleButton(
                symbol: muteSymbol(isMuted: system.isMuted),
                isOn: system.isMuted,
                variableValue: system.isMuted ? 1 : Double(system.volume),
                accessibilityName: system.isMuted ? "Unmute output" : "Mute output"
            ) {
                system.toggleMute()
            }
            .disabled(!system.canSetVolume)
        }
        .frame(height: ControlGlass.sliderHeight)
    }

    /// Opens in place rather than in a menu. A menu would be a second window over a
    /// transient popover, which is exactly the arrangement that dismisses the popover out
    /// from under the click.
    ///
    /// Deliberately unanimated: the popover's own height is resized in one step by
    /// `StatusItemController`, so animating the panel here only guarantees a window in
    /// which the panel's background and the card's height disagree — which is exactly what
    /// a half-drawn output list looked like.
    @ViewBuilder
    private var deviceList: some View {
        let list = VStack(spacing: SoundMetrics.deviceSpacing) {
            ForEach(system.devices) { device in
                DeviceRow(device: device, isCurrent: device.id == system.device?.id) {
                    system.select(device)
                }
            }
        }
        if system.devices.count > SourcePlan.maxVisibleDevices {
            ScrollView(.vertical) { list }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(height: SoundMetrics.picker(devices: system.devices.count, expanded: true) - SoundMetrics.deviceGap)
        } else {
            list
        }
    }

}

private struct DeviceRow: View {
    let device: OutputDevice
    let isCurrent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.7))
                Text(device.name)
                    .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: SoundMetrics.deviceRow)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.14 : (isCurrent ? 0.08 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(isCurrent ? "\(device.name), current output" : device.name)
    }
}
