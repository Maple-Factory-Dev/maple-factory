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

    @Test func blinkCountTicksOverOncePerPeriod() {
        #expect(RobotFace.blinkCount(at: 7.9, period: 4, offset: 0) == 1)
        #expect(RobotFace.blinkCount(at: 8, period: 4, offset: 0) == 2)
        #expect(RobotFace.blinkCount(at: 11.9, period: 4, offset: 0) == 2)
        // Another bot's offset moves its blink elsewhere.
        #expect(RobotFace.blinkCount(at: 8, period: 4, offset: 1.5) == 2)
        #expect(RobotFace.blinkCount(at: 10.5, period: 4, offset: 1.5) == 3)
    }

    @Test func scheduleWakesOncePerBlinkWithNoCatchUp() {
        // Starts now, open-eyed, so bots don't all blink together when they appear.
        let start = Date(timeIntervalSinceReferenceDate: 9)
        let dates = Array(BlinkSchedule(period: 4, offset: 0).entries(from: start, mode: .normal).prefix(4))
            .map(\.timeIntervalSinceReferenceDate)
        #expect(dates == [9, 12, 16, 20])
        let shifted = Array(BlinkSchedule(period: 4, offset: 1.5).entries(from: start, mode: .normal).prefix(3))
            .map(\.timeIntervalSinceReferenceDate)
        #expect(shifted == [9, 10.5, 14.5])
    }

    @Test func backgroundWindowsKeepTheEyesOpen() {
        let start = Date(timeIntervalSinceReferenceDate: 9)
        let dates = Array(BlinkSchedule(period: 4, offset: 0).entries(from: start, mode: .lowFrequency))
        #expect(dates == [start])
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
