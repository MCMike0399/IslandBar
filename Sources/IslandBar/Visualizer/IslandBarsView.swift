import SwiftUI

struct IslandBarsView: View {
    var levels: BarLevels
    var palette: ArtworkPalette
    var barWidth: CGFloat
    var gap: CGFloat
    var minHeight: CGFloat
    var maxHeight: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(0..<BarLevels.count, id: \.self) { i in
                let value = CGFloat(levels.values[i])
                let height = max(minHeight, value * maxHeight)
                Capsule()
                    .fill(palette.colors[i].opacity(0.9))
                    .frame(width: barWidth, height: height)
                    .shadow(color: palette.colors[i].opacity(0.35), radius: 1.5)
            }
        }
        .frame(height: maxHeight, alignment: .center)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.7), value: levels)
    }
}
