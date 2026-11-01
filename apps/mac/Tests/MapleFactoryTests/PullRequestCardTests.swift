import AppKit
import Foundation
import Testing
@testable import MapleFactory

/// The pull request card: GitHub's bundled Octicons load as template images, every PR state has its icon,
/// and the checks summary counts and words come out right.
@MainActor struct PullRequestCardTests {
    @Test func everyOcticonLoadsAsATemplateImage() throws {
        for mark in GitHubMark.allCases {
            let url = try #require(Bundle.module.url(forResource: mark.resource, withExtension: "svg"), "\(mark.resource).svg is bundled")
            let svg = try String(contentsOf: url, encoding: .utf8)
            #expect(svg.contains("MIT"), "\(mark.resource).svg names its licence")
            #expect(svg.contains(#"viewBox="0 0 16 16""#))
            let image = try #require(mark.bundled, "\(mark.resource).svg loads")
            #expect(image.isTemplate)
            #expect(image.size.width > 0 && image.size.height > 0)
        }
    }

    @Test func everyPullRequestStateHasAnIcon() {
        let states: [PullRequest.State] = [.draft, .open, .merged, .closed]
        let marks = states.map(GitHubMark.init)
        #expect(marks == [.draft, .open, .merged, .closed])
        #expect(Set(marks.map(\.resource)).count == states.count)
        for mark in marks { #expect(mark.bundled != nil, "\(mark) has a bundled icon") }
        #expect(states.map(PRStateChip.label) == ["Draft", "Open", "Merged", "Closed"])
    }

    private func check(_ name: String, _ status: CICheck.Status) -> CICheck {
        CICheck(name: name, status: status, duration: "1:00")
    }

    @Test func allPassed() {
        let summary = CheckSummary([check("lint", .passed), check("test", .passed), check("e2e", .passed)])
        #expect(summary.tone == .passed)
        #expect(summary.headline == "All checks passed")
        #expect(summary.detail == "3 of 3 passed")
        #expect(summary.segments.map(\.status) == [.passed])
    }

    @Test func failingWinsOverRunning() {
        let summary = CheckSummary([check("lint", .passed), check("test", .failed), check("e2e", .failed), check("build", .running), check("deploy", .queued)])
        #expect(summary.tone == .failed)
        #expect(summary.headline == "2 failing")
        #expect(summary.detail == "1 of 5 passed")
        #expect(summary.segments.map(\.status) == [.passed, .failed, .running, .queued])
        #expect(summary.segments.map(\.count) == [1, 2, 1, 1])
    }

    @Test func running() {
        let summary = CheckSummary([check("lint", .running), check("test", .running), check("e2e", .running), check("build", .passed)])
        #expect(summary.tone == .running)
        #expect(summary.headline == "3 running")
        #expect(summary.detail == "1 of 4 passed")
        #expect(CheckSummary([check("lint", .queued)]).headline == "1 queued")
    }

    @Test func empty() {
        let summary = CheckSummary([])
        #expect(summary.total == 0)
        #expect(summary.tone == .none)
        #expect(summary.headline == "No checks")
        #expect(summary.segments.isEmpty)
    }
}
