import SwiftUI

/// The menu bar's own light/dark decision, damped.
///
/// On macOS 26 the menu bar is glass: its lightness comes from what is drawn under it, and
/// the status item's inherited `colorScheme` is that decision handed back to us — which is
/// why the pill reads it rather than `NSApp.effectiveAppearance` (PITFALLS, "It follows the
/// menu bar, which follows the wallpaper"). Reading it straight into the pill's body closes
/// a loop: the pill redraws, the bar re-samples what is under it, the decision flips, the
/// pill redraws. Steady state hides it, but every presence change set it ringing — 510
/// flips in 1.4 s at the worst, each one starting a 0.35 s colour animation on the bars,
/// inside the menu bar's own window.
///
/// Two things break the loop, and both are needed. `AppearanceProbe` is the only view that
/// reads `colorScheme`, and it draws nothing, so a flip no longer redraws the pill and no
/// longer feeds the next decision. And a change is committed only once it has held still
/// for `settle`, so whatever ringing survives never reaches the screen: the burst keeps
/// cancelling its own pending commit until it dies out.
///
/// A real change — a new wallpaper, Light mode — lands `settle` late, which is not visible.
/// The very first reading is taken as it comes, so the pill never launches in the wrong
/// colours and then corrects itself in front of the user.
@MainActor
@Observable
final class MenuBarAppearance {
    private(set) var isLight = false
    private var committed = false
    private var pending: DispatchWorkItem?

    /// Comfortably longer than a burst's inter-flip gap (milliseconds) and than the pill's
    /// own presence spring, so one transition can never commit a colour mid-ring.
    static let settle: TimeInterval = 0.3

    func observe(_ light: Bool) {
        pending?.cancel()
        pending = nil
        guard committed else {
            committed = true
            isLight = light
            return
        }
        guard light != isLight else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            isLight = light
            pending = nil
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }
}

/// Carries the status item's inherited appearance to `MenuBarAppearance` and draws nothing.
///
/// The emptiness is the point: this view can be re-evaluated as often as the system flips
/// its decision without redrawing a pixel, so it neither costs a render nor changes what
/// the menu bar samples on its next pass.
struct AppearanceProbe: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(MenuBarAppearance.self) private var appearance

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: colorScheme, initial: true) { _, scheme in
                appearance.observe(scheme == .light)
            }
    }
}
