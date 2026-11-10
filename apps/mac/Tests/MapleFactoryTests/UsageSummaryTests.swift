import Foundation
import SwiftUI
import Testing
@testable import MapleFactory

/// The status bar and the collapsed rail's Usage tooltip read the same summary (MF-410).
@MainActor struct UsageSummaryTests {
    private func window(_ label: String, span: String, used: Double) -> UsageWindow {
        UsageWindow(label: label, span: span, used: used, resetsIn: "1h", resetsAt: "1:00 AM", elapsed: 0.5)
    }

    private func account(_ id: String, owner: String? = nil, session: Double? = nil, week: Double? = nil) -> UsageAccount {
        var windows: [UsageWindow] = []
        if let session { windows.append(window("Current session", span: "5h", used: session)) }
        if let week { windows.append(window("This week", span: "7d", used: week)) }
        return UsageAccount(id: id, product: .claudeCode, plan: "max",
                            owner: owner.map { Person(name: $0, color: .gray, isHuman: true, github: $0) },
                            accountName: id, machines: [], windows: windows, agents: [],
                            updated: "now", updatedFrom: "test", source: "test")
    }

    // MARK: Formatting

    @Test func fullTextNamesBothWindows() {
        #expect(UsageSummary.text(account("a", session: 0.34, week: 0.41), compact: false) == "34% session · 41% week")
    }

    @Test func compactTextDropsTheWords() {
        #expect(UsageSummary.text(account("a", session: 0.34, week: 0.41), compact: true) == "34% · 41%")
    }

    @Test func missingWeekWindowDropsTheWeekPart() {
        #expect(UsageSummary.text(account("a", session: 0.34), compact: false) == "34% session")
        #expect(UsageSummary.text(account("a", session: 0.34), compact: true) == "34%")
    }

    @Test func noSessionWindowGivesNoText() {
        #expect(UsageSummary.text(account("a", week: 0.41), compact: false) == nil)
        #expect(UsageSummary.text(account("a"), compact: true) == nil)
    }

    /// A model's own weekly limit ("This week · Fable") is not the week figure.
    @Test func modelWeeklyLimitIsNotTheWeek() {
        var a = account("a", session: 0.2)
        a.windows.append(window("This week · Fable", span: "7d", used: 0.9))
        #expect(UsageSummary.text(a, compact: false) == "20% session")
    }

    @Test func percentRounds() {
        #expect(UsageSummary.percent(0.345) == "35%")
        #expect(UsageSummary.percent(0.344) == "34%")
        #expect(UsageSummary.percent(0) == "0%")
        #expect(UsageSummary.percent(1) == "100%")
    }

    @Test func demoTextIsTheMock() {
        #expect(UsageSummary.demoText(compact: false) == "34% session · 41% week")
        #expect(UsageSummary.demoText(compact: true) == "34% · 41%")
    }

    // MARK: The busiest account

    @Test func busiestPrefersMineOverABusierTeammates() {
        let accounts = [account("mine-low", owner: "me", session: 0.1), account("theirs", owner: "chris", session: 0.9),
                        account("mine-high", owner: "me", session: 0.4)]
        #expect(UsageSummary.busiest(accounts, me: "me")?.id == "mine-high")
    }

    @Test func busiestFallsBackToAnyonesWhenIHaveNone() {
        let accounts = [account("a", owner: "chris", session: 0.3), account("b", owner: "sam", session: 0.7)]
        #expect(UsageSummary.busiest(accounts, me: "me")?.id == "b")
    }

    @Test func busiestIgnoresAccountsWithoutASessionWindow() {
        // Mine has only a weekly reading, so it can't be shown: the teammate's account is.
        let accounts = [account("mine-week-only", owner: "me", week: 0.99), account("theirs", owner: "chris", session: 0.2)]
        #expect(UsageSummary.busiest(accounts, me: "me")?.id == "theirs")
        #expect(UsageSummary.busiest([account("week-only", owner: "me", week: 0.5)], me: "me") == nil)
    }

    @Test func busiestOfNothingIsNil() {
        #expect(UsageSummary.busiest([], me: "me") == nil)
        #expect(UsageSummary.busiest([], me: nil) == nil)
    }

    // MARK: The server dot's tooltip

    @Test func connectionHelpWhenLive() {
        #expect(FactoryStatusBar.connectionHelp(status: .live, host: "factory.example.com")
                == "Connected to factory.example.com. Click for machines.")
    }

    @Test func connectionHelpWhenConnecting() {
        #expect(FactoryStatusBar.connectionHelp(status: .connecting, host: "factory.example.com")
                == "Connecting to factory.example.com…")
    }

    @Test func connectionHelpWhenReconnecting() {
        #expect(FactoryStatusBar.connectionHelp(status: .reconnecting(attempt: 3, reason: "The network connection was lost."), host: "factory.example.com")
                == "Reconnecting to factory.example.com: The network connection was lost. (attempt 3). Actions aren't sent while offline.")
    }

    @Test func connectionHelpWhenTooNew() {
        #expect(FactoryStatusBar.connectionHelp(status: .tooNew, host: "factory.example.com")
                == "This factory is newer than the app. Update Maple Factory to keep working.")
    }

    @Test func connectionHelpWithoutAHost() {
        #expect(FactoryStatusBar.connectionHelp(status: .live, host: nil) == "Connected to the factory. Click for machines.")
        #expect(FactoryStatusBar.connectionHelp(status: .connecting, host: "") == "Connecting to the factory…")
    }
}
