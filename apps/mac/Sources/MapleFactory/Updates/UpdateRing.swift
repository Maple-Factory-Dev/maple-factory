import SwiftUI

/// A small progress ring: fills clockwise from 12 o'clock by `fraction`, or spins a short arc
/// while the amount isn't known. Drawn by hand so it takes the theme's colours. The update toast,
/// the sidebar's update footer and the folded rail all draw this one.
struct UpdateRing: View {
    let fraction: Double?
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.stroke, lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
                    .onDisappear { spinning = false }
            }
        }
        .frame(width: size, height: size)
    }
}
