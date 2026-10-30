import AppKit
import SwiftUI

/// The auto-merge countdown's bar, emptying by `mergeAt`: one Core Animation animation the render server
/// plays, so the app's main thread sits idle while it drains instead of redrawing the window every frame.
struct CountdownDrain: NSViewRepresentable {
    let mergeAt: Date
    /// How long the whole countdown is; the bar starts full that long before `mergeAt`.
    let total: TimeInterval
    let color: Color

    func makeNSView(context: Context) -> DrainView { DrainView() }

    func updateNSView(_ view: DrainView, context: Context) {
        view.configure(mergeAt: mergeAt, total: total, color: NSColor(color))
    }

    final class DrainView: NSView {
        private let bar = CALayer()
        private var mergeAt = Date.distantPast
        private var total: TimeInterval = 1
        private var color = NSColor.clear

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            bar.anchorPoint = .zero
            layer?.addSublayer(bar)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(mergeAt: Date, total: TimeInterval, color: NSColor) {
            let changed = mergeAt != self.mergeAt || total != self.total || color != self.color
            self.mergeAt = mergeAt
            self.total = max(total, 0.001)
            self.color = color
            if changed { restart() }
        }

        override func layout() {
            super.layout()
            restart()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            restart()
        }

        /// The bar as full as the time left, animating to empty by `mergeAt`.
        private func restart() {
            let left = max(0, mergeAt.timeIntervalSinceNow)
            let width = bounds.width * min(1, left / total)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectiveAppearance.performAsCurrentDrawingAppearance { bar.backgroundColor = color.cgColor }
            bar.removeAllAnimations()
            bar.position = .zero
            bar.bounds = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
            CATransaction.commit()
            guard left > 0, width > 0 else { return }
            let drain = CABasicAnimation(keyPath: "bounds.size.width")
            drain.fromValue = width
            drain.toValue = 0
            drain.duration = left
            drain.timingFunction = CAMediaTimingFunction(name: .linear)
            bar.add(drain, forKey: "drain")
        }
    }
}

extension TimelineSchedule where Self == ExplicitTimelineSchedule<[Date]> {
    /// Now, and each moment a countdown to `date` shows one second less (`Int(left.rounded(.up))`): its
    /// number changes on time without updating in between.
    static func everySecond(until date: Date, from now: Date = .now) -> Self {
        let left = Int(max(0, date.timeIntervalSince(now)).rounded(.up))
        // A hair past each whole second, so the number read then is already the smaller one.
        let ticks = (0..<left).map { date.addingTimeInterval(-Double($0) + 0.001) }.filter { $0 > now }
        return .explicit([now] + ticks.sorted())
    }
}
