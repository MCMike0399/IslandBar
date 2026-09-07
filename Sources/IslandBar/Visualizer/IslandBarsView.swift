import SwiftUI

struct IslandBarsView: View {
    var levels: BarLevels
    /// Draws a single thin line spanning the bar area instead of bars. Used whenever
    /// nothing is playing so the status item stays visible but visibly idle.
    var flat = false
    var palette: ArtworkPalette
    var barWidth: CGFloat
    var gap: CGFloat
    var minHeight: CGFloat
    var maxHeight: CGFloat

    private var totalWidth: CGFloat {
        CGFloat(BarLevels.count) * barWidth + CGFloat(BarLevels.count - 1) * gap
    }

    var body: some View {
        ZStack {
            if flat {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: palette.colors.map { $0.opacity(0.85) },
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: totalWidth, height: minHeight)
                    .transition(.opacity)
            } else {
                HStack(alignment: .center, spacing: gap) {
                    ForEach(0..<BarLevels.count, id: \.self) { i in
                        let value = CGFloat(levels.values[i])
                        let height = max(minHeight, value * maxHeight)
                        Capsule()
                            .fill(palette.colors[i])
                            .frame(width: barWidth, height: height)
                            .shadow(color: palette.colors[i].opacity(0.45), radius: barWidth * 0.6)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(width: totalWidth, height: maxHeight, alignment: .center)
        // Slightly slower, better damped spring than before so the 30 Hz level
        // stream reads as one fluid motion instead of discrete jumps.
        .animation(.interactiveSpring(response: 0.26, dampingFraction: 0.82, blendDuration: 0.08), value: levels)
        .animation(.easeInOut(duration: 0.35), value: flat)
        .animation(.easeInOut(duration: 0.6), value: palette)
    }
}
