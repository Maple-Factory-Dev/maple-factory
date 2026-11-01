import AppKit
import SwiftUI
import Testing
@testable import MapleFactory

/// Bots wear a robot face colored by role; people keep their initials or GitHub picture.
@MainActor struct RobotAvatarTests {
    @Test func smallFacesDropTheAntennaAndSmile() {
        #expect(!RobotFace.showsDetail(size: 13))
        #expect(!RobotFace.showsDetail(size: 15.9))
        #expect(RobotFace.showsDetail(size: 16))
        #expect(RobotFace.showsDetail(size: 28))
    }

    @Test func animationStopsUnderReduceMotionAndAtTinySizes() {
        #expect(RobotFace.animates(size: 18, reduceMotion: false))
        #expect(!RobotFace.animates(size: 18, reduceMotion: true))
        #expect(!RobotFace.animates(size: 13, reduceMotion: false))
        #expect(!RobotFace.animates(size: 28, reduceMotion: false, requested: false))
    }

    @Test func blinksOncePerPeriodForABriefMoment() {
        let period = 4.0
        #expect(RobotFace.isBlinking(at: 8.05, period: period, offset: 0))
        #expect(!RobotFace.isBlinking(at: 8.2, period: period, offset: 0))
        #expect(!RobotFace.isBlinking(at: 10, period: period, offset: 0))
        // A different offset puts another bot's blink elsewhere.
        #expect(!RobotFace.isBlinking(at: 8.05, period: period, offset: 1.5))
        #expect(RobotFace.isBlinking(at: 10.55, period: period, offset: 1.5))
    }

    @Test func scheduleWakesToShutAndOpenTheEyes() {
        let schedule = BlinkSchedule(period: 4, offset: 0)
        let start = Date(timeIntervalSinceReferenceDate: 9)
        let dates = Array(schedule.entries(from: start, mode: .normal).prefix(4)).map(\.timeIntervalSinceReferenceDate)
        #expect(dates.count == 4)
        let expected = [8, 8 + RobotFace.blinkDuration, 12, 12 + RobotFace.blinkDuration]
        for (date, want) in zip(dates, expected) { #expect(abs(date - want) < 1e-9) }
    }

    @Test func peopleShowInitialsAndBotsShowTheRobot() {
        let person = Agent(name: "Ada Lovelace", color: .orange, isHuman: true)
        #expect(person.initials == "AL")
        #expect(AgentAvatar.face(for: person) == .initials)
        for role in ["planner", "builder", "reviewer", "other"] {
            #expect(AgentAvatar.face(for: LiveAdapter.role(role)) == .robot)
        }
        #expect(AgentAvatar.face(for: FactoryData.reviewer) == .robot)
    }

    @Test func eachRoleHasItsOwnColor() {
        let colors = ["planner", "builder", "reviewer", "other"].map { hex(LiveAdapter.role($0).color) }
        #expect(Set(colors).count == 4)
        #expect(LiveAdapter.role("reviewer").name == FactoryData.reviewer.name)
    }

    private func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}
