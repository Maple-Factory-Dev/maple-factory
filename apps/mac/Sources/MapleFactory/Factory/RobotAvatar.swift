import SwiftUI

/// A bot's face: a rounded head in its role's color, an antenna, two eyes and a smile, drawn from
/// shapes so it stays sharp at any size. It blinks now and then, and its antenna bobs while the bot
/// is online; both stop under Reduce Motion and at sizes too small to see them.
struct RobotFace: View {
    let color: Color
    var size: CGFloat = 20
    var animated = true
    var online = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each face gets its own rhythm, so a list of bots doesn't blink in unison.
    @State private var period = Double.random(in: RobotFace.blinkPeriods)
    @State private var offset = Double.random(in: 0..<RobotFace.blinkPeriods.upperBound)
    @State private var bobbed = false

    /// Below this the antenna and smile turn to mush, so only the head and eyes are drawn.
    static let detailThreshold: CGFloat = 16
    static let blinkPeriods: ClosedRange<Double> = 3...6
    static let blinkDuration: Double = 0.12

    static func showsDetail(size: CGFloat) -> Bool { size >= detailThreshold }

    static func animates(size: CGFloat, reduceMotion: Bool, requested: Bool = true) -> Bool {
        requested && !reduceMotion && size >= detailThreshold
    }

    /// Whether the eyes are shut at `time`: one blink of `blinkDuration` at the start of every period.
    static func isBlinking(at time: TimeInterval, period: Double, offset: Double) -> Bool {
        let phase = (time + offset).truncatingRemainder(dividingBy: period)
        return (phase < 0 ? phase + period : phase) < blinkDuration
    }

    private var detail: Bool { Self.showsDetail(size: size) }
    private var moving: Bool { Self.animates(size: size, reduceMotion: reduceMotion, requested: animated) }

    var body: some View {
        let s = size
        let ink = Theme.editorBG
        let headWidth = s * (detail ? 0.6 : 0.66)
        let headHeight = s * (detail ? 0.46 : 0.52)
        let headY = s * (detail ? 0.56 : 0.5)
        let eyeY = headY - s * 0.04

        ZStack {
            if detail {
                // The antenna: a stalk and a ball, bobbing while the bot is online.
                Group {
                    Capsule()
                        .fill(color)
                        .frame(width: max(1, s * 0.06), height: s * 0.16)
                        .position(x: s / 2, y: headY - headHeight / 2 - s * 0.06)
                    Circle()
                        .fill(color)
                        .frame(width: s * 0.14, height: s * 0.14)
                        .position(x: s / 2, y: s * 0.17)
                }
                .offset(y: bobbed ? -s * 0.04 : s * 0.02)
            }
            RoundedRectangle(cornerRadius: s * 0.15, style: .continuous)
                .fill(color)
                .frame(width: headWidth, height: headHeight)
                .position(x: s / 2, y: headY)
            eyes(size: s, y: eyeY, ink: ink)
            if detail {
                Smile()
                    .stroke(ink, style: StrokeStyle(lineWidth: max(1, s * 0.05), lineCap: .round))
                    .frame(width: s * 0.18, height: s * 0.06)
                    .position(x: s / 2, y: headY + s * 0.11)
            }
        }
        .frame(width: s, height: s)
        .onAppear { startBobbing() }
        .onChange(of: moving && online) { startBobbing() }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func eyes(size s: CGFloat, y: CGFloat, ink: Color) -> some View {
        let width = s * (detail ? 0.1 : 0.12)
        let height = s * (detail ? 0.15 : 0.18)
        let spread = s * (detail ? 0.12 : 0.13)
        let pair = HStack(spacing: spread * 2 - width) {
            Capsule().fill(ink).frame(width: width, height: height)
            Capsule().fill(ink).frame(width: width, height: height)
        }
        .position(x: s / 2, y: y)

        if moving {
            TimelineView(BlinkSchedule(period: period, offset: offset)) { context in
                let shut = Self.isBlinking(at: context.date.timeIntervalSinceReferenceDate, period: period, offset: offset)
                pair
                    .scaleEffect(x: 1, y: shut ? 0.1 : 1, anchor: UnitPoint(x: 0.5, y: y / s))
                    .animation(.easeInOut(duration: Self.blinkDuration / 2), value: shut)
            }
        } else {
            pair
        }
    }

    private func startBobbing() {
        if moving && online {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bobbed = true }
        } else {
            withAnimation(.default) { bobbed = false }
        }
    }
}

/// The robot's grin: a shallow curve, open at the top.
private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY + rect.height))
        return path
    }
}

/// Wakes the timeline only to shut the eyes and to open them again, not every frame.
struct BlinkSchedule: TimelineSchedule {
    let period: Double
    let offset: Double

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let start = startDate.timeIntervalSinceReferenceDate
        // The start of the blink at or before `startDate`, then shut and open in turn.
        var blink = start - ((start + offset).truncatingRemainder(dividingBy: period))
        var opening = false
        return AnyIterator {
            defer {
                if opening { blink += period }
                opening.toggle()
            }
            return Date(timeIntervalSinceReferenceDate: opening ? blink + RobotFace.blinkDuration : blink)
        }
    }
}
