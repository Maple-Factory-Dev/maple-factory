import Foundation
import Testing
@testable import MapleFactory

/// A model's own weekly limit arrives as "7d:fable" with a name; the card names it, never the raw key (MF-287).
@MainActor struct LiveAdapterUsageWindowTests {
    private func window(_ label: String, minutes: UInt32? = nil, name: String? = nil) -> UsageWindow {
        LiveAdapter.window(Wire.UsageReading(label: label, usedPercent: 40, windowMinutes: minutes, resetsAt: nil, name: name))
    }

    @Test func modelWeeklyLimitIsNamed() {
        let w = window("7d:fable", minutes: 10080, name: "Fable")
        #expect(w.label == "This week · Fable")
        #expect(w.span == "7d")
    }

    @Test func scopedWeeklyWithoutMinutesStillWeekly() {
        let w = window("7d:fable", name: "Fable")
        #expect(w.label == "This week · Fable")
        #expect(w.span == "7d")
    }

    @Test func plainWindowsKeepTheirLabels() {
        #expect(window("7d", minutes: 10080).label == "This week")
        #expect(window("7d", minutes: 10080).span == "7d")
        #expect(window("5h", minutes: 300).label == "Current session")
        #expect(window("5h", minutes: 300).span == "5h")
        #expect(window("spend").label == "Spend")
        #expect(window("spend").span == "spend")
    }

    @Test func unknownScopedKeyNeverShowsRaw() {
        let w = window("1d:opus", minutes: 1440, name: "Opus")
        #expect(w.label == "1d · Opus")
        #expect(w.span == "1d")
    }
}
