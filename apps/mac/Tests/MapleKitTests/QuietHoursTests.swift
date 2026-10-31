import Foundation
import Testing
@testable import MapleKit

/// Quiet hours (MF-224): the Swift port gives the same answers as the server's quiet-hours.ts on the
/// shared cases in protocol/quiet-hours-cases.json (server/test/quiet-hours.test.ts runs the same file).
struct QuietHoursTests {
    struct Fixture: Decodable {
        struct Case: Decodable { let name: String; let schedule: String; let at: String; let until: String? }
        let schedules: [String: Wire.QuietHours]
        let cases: [Case]
    }

    static let fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // apps/mac
            .deletingLastPathComponent().deletingLastPathComponent() // the repo
            .appendingPathComponent("protocol/quiet-hours-cases.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    private static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test(arguments: fixture.cases.map(\.name))
    func agreesWithTheServer(_ name: String) {
        let c = Self.fixture.cases.first { $0.name == name }!
        let schedule = Self.fixture.schedules[c.schedule]!
        let at = Self.date(c.at)
        #expect(schedule.isQuiet(at: at) == (c.until != nil), "\(name)")
        #expect(schedule.quietUntil(at) == c.until.map(Self.date), "\(name)")
    }

    @Test func coversEveryKindOfCase() {
        #expect(Self.fixture.cases.count >= 20)
    }

    @Test func noWindowsOrAnUnknownZoneIsNeverQuiet() {
        let now = Self.date("2026-10-28T03:00:00Z")
        #expect(!Wire.QuietHours(timeZone: "UTC", windows: []).isQuiet(at: now))
        let window = Wire.QuietWindow(days: [0, 1, 2, 3, 4, 5, 6], start: 0, end: 1439)
        #expect(!Wire.QuietHours(timeZone: "Mars/Olympus", windows: [window]).isQuiet(at: now))
        #expect(Wire.QuietHours(timeZone: "UTC", windows: [window]).isQuiet(at: now))
    }
}
